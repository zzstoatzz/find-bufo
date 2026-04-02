const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const Thread = std.Thread;
const Io = std.Io;
const net = Io.net;
const http = std.http;
const template = @import("stats_template.zig");

const STATS_PATH = "/data/stats.json";
const STATS_TMP_PATH = "/data/stats.json.tmp";

// module state — initialized via init(), not from a global
var io: Io = undefined;

pub fn init(app_io: Io) void {
    io = app_io;
}

fn timestamp() i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

pub const TrackedPost = struct {
    our_rkey: []const u8,
    original_uri: []const u8,
    original_did: []const u8,
    timestamp: i64,
};

pub const Stats = struct {
    allocator: Allocator,
    start_time: i64,
    prior_uptime: u64 = 0, // cumulative uptime from previous runs
    posts_checked: std.atomic.Value(u64) = .init(0),
    matches_found: std.atomic.Value(u64) = .init(0),
    posts_created: std.atomic.Value(u64) = .init(0),
    cooldowns_hit: std.atomic.Value(u64) = .init(0),
    blocks_respected: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    bufos_loaded: u64 = 0,
    jetstream_host_buf: [256]u8 = undefined,
    jetstream_host_len: std.atomic.Value(usize) = .init(0),

    last_snapshot_hour: i64 = -1, // hour-of-day of last snapshot (-1 = none yet)

    // track per-bufo match counts: name -> {count, url}
    bufo_matches: std.StringHashMap(BufoMatchData),
    bufo_mutex: Io.Mutex = Io.Mutex.init,
    // track last post time per bufo (persisted to survive restarts)
    last_posted: std.StringHashMap(i64),
    // track our quote-posts for cleanup on delete/block
    tracked_posts: std.ArrayList(TrackedPost),

    const BufoMatchData = struct {
        count: u64,
        url: []const u8,
    };

    pub fn initStats(allocator: Allocator) Stats {
        var self = Stats{
            .allocator = allocator,
            .start_time = timestamp(),
            .bufo_matches = std.StringHashMap(BufoMatchData).init(allocator),
            .last_posted = std.StringHashMap(i64).init(allocator),
            .tracked_posts = .empty,
        };
        self.load();
        return self;
    }

    pub fn deinit(self: *Stats) void {
        self.save();
        var iter = self.bufo_matches.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.url);
        }
        self.bufo_matches.deinit();
        var lp_iter = self.last_posted.iterator();
        while (lp_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.last_posted.deinit();
        for (self.tracked_posts.items) |tp| {
            self.allocator.free(tp.our_rkey);
            self.allocator.free(tp.original_uri);
            self.allocator.free(tp.original_did);
        }
        self.tracked_posts.deinit(self.allocator);
    }

    fn load(self: *Stats) void {
        const file = Io.Dir.openFileAbsolute(io, STATS_PATH, .{}) catch return;
        defer file.close(io);

        var buf: [256 * 1024]u8 = undefined;
        const len = file.readPositionalAll(io, &buf, 0) catch return;
        if (len == 0) return;

        const parsed = json.parseFromSlice(json.Value, self.allocator, buf[0..len], .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value.object;

        if (root.get("posts_checked")) |v| if (v == .integer) {
            self.posts_checked.store(@intCast(@max(0, v.integer)), .monotonic);
        };
        if (root.get("matches_found")) |v| if (v == .integer) {
            self.matches_found.store(@intCast(@max(0, v.integer)), .monotonic);
        };
        if (root.get("posts_created")) |v| if (v == .integer) {
            self.posts_created.store(@intCast(@max(0, v.integer)), .monotonic);
        };
        if (root.get("cooldowns_hit")) |v| if (v == .integer) {
            self.cooldowns_hit.store(@intCast(@max(0, v.integer)), .monotonic);
        };
        if (root.get("blocks_respected")) |v| if (v == .integer) {
            self.blocks_respected.store(@intCast(@max(0, v.integer)), .monotonic);
        };
        if (root.get("errors")) |v| if (v == .integer) {
            self.errors.store(@intCast(@max(0, v.integer)), .monotonic);
        };
        if (root.get("cumulative_uptime")) |v| if (v == .integer) {
            self.prior_uptime = @intCast(@max(0, v.integer));
        };
        // load bufo_matches (or legacy bufo_posts)
        const matches_key = if (root.get("bufo_matches") != null) "bufo_matches" else "bufo_posts";
        if (root.get(matches_key)) |bp| {
            if (bp == .object) {
                var iter = bp.object.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* == .object) {
                        // format: {"count": N, "url": "..."}
                        const obj = entry.value_ptr.object;
                        const count_val = obj.get("count") orelse continue;
                        const url_val = obj.get("url") orelse continue;
                        if (count_val != .integer or url_val != .string) continue;

                        const key = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                        const url = self.allocator.dupe(u8, url_val.string) catch {
                            self.allocator.free(key);
                            continue;
                        };
                        self.bufo_matches.put(key, .{
                            .count = @intCast(@max(0, count_val.integer)),
                            .url = url,
                        }) catch {
                            self.allocator.free(key);
                            self.allocator.free(url);
                        };
                    } else if (entry.value_ptr.* == .integer) {
                        // legacy format: just integer count - construct URL from name
                        const key = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                        var url_buf: [256]u8 = undefined;
                        const constructed_url = std.fmt.bufPrint(&url_buf, "https://all-the.bufo.zone/{s}", .{entry.key_ptr.*}) catch continue;
                        const url = self.allocator.dupe(u8, constructed_url) catch {
                            self.allocator.free(key);
                            continue;
                        };
                        self.bufo_matches.put(key, .{
                            .count = @intCast(@max(0, entry.value_ptr.integer)),
                            .url = url,
                        }) catch {
                            self.allocator.free(key);
                            self.allocator.free(url);
                        };
                    }
                }
            }
        }

        // load last_posted timestamps
        if (root.get("last_posted")) |lp| {
            if (lp == .object) {
                var lp_iter = lp.object.iterator();
                while (lp_iter.next()) |entry| {
                    if (entry.value_ptr.* == .integer) {
                        const key = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                        self.last_posted.put(key, entry.value_ptr.integer) catch {
                            self.allocator.free(key);
                        };
                    }
                }
            }
        }

        // load tracked posts
        if (root.get("tracked_posts")) |tp| {
            if (tp == .array) {
                for (tp.array.items) |item| {
                    if (item != .object) continue;
                    const rkey_val = item.object.get("our_rkey") orelse continue;
                    const uri_val = item.object.get("original_uri") orelse continue;
                    const did_val = item.object.get("original_did") orelse continue;
                    const ts_val = item.object.get("timestamp") orelse continue;
                    if (rkey_val != .string or uri_val != .string or did_val != .string or ts_val != .integer) continue;

                    const rkey = self.allocator.dupe(u8, rkey_val.string) catch continue;
                    const uri = self.allocator.dupe(u8, uri_val.string) catch {
                        self.allocator.free(rkey);
                        continue;
                    };
                    const did = self.allocator.dupe(u8, did_val.string) catch {
                        self.allocator.free(rkey);
                        self.allocator.free(uri);
                        continue;
                    };
                    self.tracked_posts.append(self.allocator, .{
                        .our_rkey = rkey,
                        .original_uri = uri,
                        .original_did = did,
                        .timestamp = ts_val.integer,
                    }) catch {
                        self.allocator.free(rkey);
                        self.allocator.free(uri);
                        self.allocator.free(did);
                    };
                }
            }
        }

        std.debug.print("loaded stats from {s} ({} tracked posts)\n", .{ STATS_PATH, self.tracked_posts.items.len });
    }

    pub fn save(self: *Stats) void {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);
        self.saveUnlocked();
    }

    pub fn totalUptime(self: *Stats) i64 {
        const now = timestamp();
        const session: i64 = now - self.start_time;
        return @as(i64, @intCast(self.prior_uptime)) + session;
    }

    pub fn incPostsChecked(self: *Stats) void {
        _ = self.posts_checked.fetchAdd(1, .monotonic);
    }

    pub fn incMatchesFound(self: *Stats) void {
        _ = self.matches_found.fetchAdd(1, .monotonic);
    }

    pub fn incBufoMatch(self: *Stats, bufo_name: []const u8, bufo_url: []const u8) void {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);

        if (self.bufo_matches.getPtr(bufo_name)) |data| {
            data.count += 1;
        } else {
            const key = self.allocator.dupe(u8, bufo_name) catch return;
            const url = self.allocator.dupe(u8, bufo_url) catch {
                self.allocator.free(key);
                return;
            };
            self.bufo_matches.put(key, .{ .count = 1, .url = url }) catch {
                self.allocator.free(key);
                self.allocator.free(url);
            };
        }
        self.saveUnlocked();
    }

    pub fn incPostsCreated(self: *Stats) void {
        _ = self.posts_created.fetchAdd(1, .monotonic);
    }

    fn saveUnlocked(self: *Stats) void {
        // called when mutex is already held
        const file = Io.Dir.createFileAbsolute(io, STATS_TMP_PATH, .{}) catch return;

        const now = timestamp();
        const session_uptime: u64 = @intCast(@max(0, now - self.start_time));
        const total_uptime = self.prior_uptime + session_uptime;

        var buf: [256 * 1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);

        w.print("{{", .{}) catch return;
        w.print("\"posts_checked\":{},", .{self.posts_checked.load(.monotonic)}) catch return;
        w.print("\"matches_found\":{},", .{self.matches_found.load(.monotonic)}) catch return;
        w.print("\"posts_created\":{},", .{self.posts_created.load(.monotonic)}) catch return;
        w.print("\"cooldowns_hit\":{},", .{self.cooldowns_hit.load(.monotonic)}) catch return;
        w.print("\"blocks_respected\":{},", .{self.blocks_respected.load(.monotonic)}) catch return;
        w.print("\"errors\":{},", .{self.errors.load(.monotonic)}) catch return;
        w.print("\"cumulative_uptime\":{},", .{total_uptime}) catch return;
        w.print("\"bufo_matches\":{{", .{}) catch return;

        var first = true;
        var iter = self.bufo_matches.iterator();
        while (iter.next()) |entry| {
            if (!first) w.print(",", .{}) catch return;
            first = false;
            w.print("\"{s}\":{{\"count\":{},\"url\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.count, entry.value_ptr.url }) catch return;
        }

        w.print("}},", .{}) catch return;

        // write last_posted timestamps
        w.print("\"last_posted\":{{", .{}) catch return;
        var lp_first = true;
        var lp_iter = self.last_posted.iterator();
        while (lp_iter.next()) |entry| {
            if (!lp_first) w.print(",", .{}) catch return;
            lp_first = false;
            w.print("\"{s}\":{}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch return;
        }
        w.print("}},", .{}) catch return;

        // write tracked posts
        w.print("\"tracked_posts\":[", .{}) catch return;
        for (self.tracked_posts.items, 0..) |tp, i| {
            if (i > 0) w.print(",", .{}) catch return;
            w.print("{{\"our_rkey\":\"{s}\",\"original_uri\":\"{s}\",\"original_did\":\"{s}\",\"timestamp\":{}}}", .{ tp.our_rkey, tp.original_uri, tp.original_did, tp.timestamp }) catch return;
        }
        w.print("]}}", .{}) catch return;

        const written = buf[0..w.end];
        file.writeStreamingAll(io, written) catch return;
        file.close(io);
        Io.Dir.renameAbsolute(STATS_TMP_PATH, STATS_PATH, io) catch return;

        // hourly snapshot: copy to /data/stats.snapshot.HH (24 rolling files)
        const hour = @mod(@divTrunc(now, 3600), 24);
        if (hour != self.last_snapshot_hour) {
            self.last_snapshot_hour = hour;
            var snap_path: [48]u8 = undefined;
            const snap = std.fmt.bufPrint(&snap_path, "/data/stats.snapshot.{d:0>2}", .{@as(u64, @intCast(hour))}) catch return;
            const snap_file = Io.Dir.createFileAbsolute(io, snap, .{}) catch return;
            snap_file.writeStreamingAll(io, written) catch {};
            snap_file.close(io);
        }
    }

    /// Quadratic cooldown scaling: bufos that dominate the feed get exponentially longer cooldowns.
    /// At 5% of matches: ~1.5x base. At 20%: ~9x base. At 33%: ~23x base.
    const COOLDOWN_SCALE_FACTOR: f64 = 200.0;

    pub fn getCooldownSeconds(self: *Stats, bufo_name: []const u8, base_secs: u64) u64 {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);

        const bufo_count: u64 = if (self.bufo_matches.get(bufo_name)) |data| data.count else 0;

        var total_count: u64 = 0;
        var iter = self.bufo_matches.iterator();
        while (iter.next()) |entry| {
            total_count += entry.value_ptr.count;
        }
        if (total_count == 0) return base_secs;

        const ratio = @as(f64, @floatFromInt(bufo_count)) / @as(f64, @floatFromInt(total_count));
        // rare bufos (< 1% of matches) post immediately — no cooldown
        if (ratio < 0.01) return 0;
        // quadratic: dominant bufos get penalized much harder
        const multiplier = 1.0 + COOLDOWN_SCALE_FACTOR * ratio * ratio;
        return @intFromFloat(@as(f64, @floatFromInt(base_secs)) * multiplier);
    }

    pub fn getLastPosted(self: *Stats, bufo_name: []const u8) ?i64 {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);
        return self.last_posted.get(bufo_name);
    }

    pub fn setLastPosted(self: *Stats, bufo_name: []const u8, ts: i64) void {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);
        if (self.last_posted.getPtr(bufo_name)) |ptr| {
            ptr.* = ts;
        } else {
            const key = self.allocator.dupe(u8, bufo_name) catch return;
            self.last_posted.put(key, ts) catch {
                self.allocator.free(key);
            };
        }
        self.saveUnlocked();
    }

    pub fn addTrackedPost(self: *Stats, our_rkey: []const u8, original_uri: []const u8, original_did: []const u8, ts: i64) void {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);

        const rkey = self.allocator.dupe(u8, our_rkey) catch return;
        const uri = self.allocator.dupe(u8, original_uri) catch {
            self.allocator.free(rkey);
            return;
        };
        const did = self.allocator.dupe(u8, original_did) catch {
            self.allocator.free(rkey);
            self.allocator.free(uri);
            return;
        };
        self.tracked_posts.append(self.allocator, .{
            .our_rkey = rkey,
            .original_uri = uri,
            .original_did = did,
            .timestamp = ts,
        }) catch {
            self.allocator.free(rkey);
            self.allocator.free(uri);
            self.allocator.free(did);
            return;
        };
        self.saveUnlocked();
    }

    /// atomically find+remove a tracked post by original URI, returning the caller-owned rkey
    pub fn removeByOriginalUri(self: *Stats, uri: []const u8) ?[]const u8 {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);

        for (self.tracked_posts.items, 0..) |tp, i| {
            if (mem.eql(u8, tp.original_uri, uri)) {
                const removed = self.tracked_posts.orderedRemove(i);
                self.allocator.free(removed.original_uri);
                self.allocator.free(removed.original_did);
                self.saveUnlocked();
                return removed.our_rkey; // caller owns this
            }
        }
        return null;
    }

    /// find+remove a tracked post by our rkey, returning true if found
    pub fn removeByOurRkey(self: *Stats, rkey: []const u8) bool {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);

        for (self.tracked_posts.items, 0..) |tp, i| {
            if (mem.eql(u8, tp.our_rkey, rkey)) {
                const removed = self.tracked_posts.orderedRemove(i);
                self.allocator.free(removed.our_rkey);
                self.allocator.free(removed.original_uri);
                self.allocator.free(removed.original_did);
                self.saveUnlocked();
                return true;
            }
        }
        return false;
    }

    /// check if a given rkey is already tracked
    pub fn isTracked(self: *Stats, rkey: []const u8) bool {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);

        for (self.tracked_posts.items) |tp| {
            if (mem.eql(u8, tp.our_rkey, rkey)) return true;
        }
        return false;
    }

    /// collect rkeys of tracked posts matching a given original DID, then remove them
    pub fn removeByOriginalDid(self: *Stats, did: []const u8, buf: [][]const u8) [][]const u8 {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);

        var count: usize = 0;
        var i: usize = 0;
        while (i < self.tracked_posts.items.len and count < buf.len) {
            if (mem.eql(u8, self.tracked_posts.items[i].original_did, did)) {
                const tp = self.tracked_posts.orderedRemove(i);
                buf[count] = tp.our_rkey;
                self.allocator.free(tp.original_uri);
                self.allocator.free(tp.original_did);
                count += 1;
            } else {
                i += 1;
            }
        }
        if (count > 0) self.saveUnlocked();
        return buf[0..count];
    }

    pub fn pruneOldPosts(self: *Stats, max_age_secs: i64) void {
        self.bufo_mutex.lockUncancelable(io);
        defer self.bufo_mutex.unlock(io);

        const now = timestamp();
        var i: usize = 0;
        var pruned: usize = 0;
        while (i < self.tracked_posts.items.len) {
            if (now - self.tracked_posts.items[i].timestamp > max_age_secs) {
                const tp = self.tracked_posts.orderedRemove(i);
                self.allocator.free(tp.our_rkey);
                self.allocator.free(tp.original_uri);
                self.allocator.free(tp.original_did);
                pruned += 1;
            } else {
                i += 1;
            }
        }
        if (pruned > 0) {
            std.debug.print("pruned {} old tracked posts\n", .{pruned});
            self.saveUnlocked();
        }
    }

    pub fn incCooldownsHit(self: *Stats) void {
        _ = self.cooldowns_hit.fetchAdd(1, .monotonic);
    }

    pub fn incBlocksRespected(self: *Stats) void {
        _ = self.blocks_respected.fetchAdd(1, .monotonic);
    }

    pub fn incErrors(self: *Stats) void {
        _ = self.errors.fetchAdd(1, .monotonic);
    }

    pub fn setBufosLoaded(self: *Stats, count: u64) void {
        self.bufos_loaded = count;
    }

    pub fn setJetstreamHost(self: *Stats, host: []const u8) void {
        const len = @min(host.len, self.jetstream_host_buf.len);
        @memcpy(self.jetstream_host_buf[0..len], host[0..len]);
        self.jetstream_host_len.store(len, .release);
    }

    pub fn getJetstreamHost(self: *Stats) []const u8 {
        const len = self.jetstream_host_len.load(.acquire);
        if (len == 0) return "(connecting...)";
        return self.jetstream_host_buf[0..len];
    }

    fn formatUptime(seconds: i64, buf: []u8) []const u8 {
        const s: u64 = @intCast(@max(0, seconds));
        const days = s / 86400;
        const hours = (s % 86400) / 3600;
        const mins = (s % 3600) / 60;
        const secs = s % 60;

        if (days > 0) {
            return std.fmt.bufPrint(buf, "{}d {}h {}m", .{ days, hours, mins }) catch "?";
        } else if (hours > 0) {
            return std.fmt.bufPrint(buf, "{}h {}m {}s", .{ hours, mins, secs }) catch "?";
        } else if (mins > 0) {
            return std.fmt.bufPrint(buf, "{}m {}s", .{ mins, secs }) catch "?";
        } else {
            return std.fmt.bufPrint(buf, "{}s", .{secs}) catch "?";
        }
    }

    pub fn renderHtml(self: *Stats, allocator: Allocator) ![]const u8 {
        const uptime = self.totalUptime();

        var uptime_buf: [64]u8 = undefined;
        const uptime_str = formatUptime(uptime, &uptime_buf);

        const BufoEntry = struct {
            name: []const u8,
            count: u64,
            url: []const u8,

            fn compare(_: void, a: @This(), b: @This()) bool {
                return a.count > b.count;
            }
        };

        // collect top bufos
        var top_bufos: std.ArrayList(BufoEntry) = .empty;
        defer top_bufos.deinit(allocator);

        {
            self.bufo_mutex.lockUncancelable(io);
            defer self.bufo_mutex.unlock(io);

            var iter = self.bufo_matches.iterator();
            while (iter.next()) |entry| {
                try top_bufos.append(allocator, .{ .name = entry.key_ptr.*, .count = entry.value_ptr.count, .url = entry.value_ptr.url });
            }
        }

        // sort by count descending
        mem.sort(BufoEntry, top_bufos.items, {}, BufoEntry.compare);

        // build top bufos grid html
        var top_html: std.ArrayList(u8) = .empty;
        defer top_html.deinit(allocator);

        // find max count for scaling
        var max_count: u64 = 1;
        for (top_bufos.items) |entry| {
            if (entry.count > max_count) max_count = entry.count;
        }

        for (top_bufos.items) |entry| {
            // scale size: min 60px, max 160px based on count ratio
            const ratio = @as(f64, @floatFromInt(entry.count)) / @as(f64, @floatFromInt(max_count));
            const size: u32 = @intFromFloat(60.0 + ratio * 100.0);

            // strip extension for display name
            var display_name = entry.name;
            if (mem.endsWith(u8, entry.name, ".gif")) {
                display_name = entry.name[0 .. entry.name.len - 4];
            } else if (mem.endsWith(u8, entry.name, ".png")) {
                display_name = entry.name[0 .. entry.name.len - 4];
            } else if (mem.endsWith(u8, entry.name, ".jpg")) {
                display_name = entry.name[0 .. entry.name.len - 4];
            }

            try top_html.print(allocator,
                \\<div class="bufo-card" style="width:{}px;height:{}px;" title="{s} ({} matches)" data-name="{s}" onclick="showPosts(this)">
                \\<img src="{s}" alt="{s}" loading="lazy">
                \\<span class="bufo-count">{}</span>
                \\</div>
            , .{ size, size, display_name, entry.count, display_name, entry.url, display_name, entry.count });
        }

        const top_section = if (top_bufos.items.len > 0) top_html.items else "<p class=\"no-bufos\">no posts yet</p>";

        const html = try std.fmt.allocPrint(allocator, template.html, .{
            uptime,
            uptime_str,
            self.getJetstreamHost(),
            self.posts_checked.load(.monotonic),
            self.posts_checked.load(.monotonic),
            self.matches_found.load(.monotonic),
            self.matches_found.load(.monotonic),
            self.posts_created.load(.monotonic),
            self.posts_created.load(.monotonic),
            self.cooldowns_hit.load(.monotonic),
            self.cooldowns_hit.load(.monotonic),
            self.blocks_respected.load(.monotonic),
            self.blocks_respected.load(.monotonic),
            self.errors.load(.monotonic),
            self.errors.load(.monotonic),
            self.bufos_loaded,
            self.bufos_loaded,
            top_section,
        });

        return html;
    }
};

pub const StatsServer = struct {
    allocator: Allocator,
    stats: *Stats,
    port: u16,

    pub fn initServer(allocator: Allocator, s: *Stats, port: u16) StatsServer {
        return .{
            .allocator = allocator,
            .stats = s,
            .port = port,
        };
    }

    pub fn run(self: *StatsServer) void {
        // spawn periodic save ticker (every 60s)
        const ticker = Thread.spawn(.{}, saveTicker, .{self.stats}) catch |err| {
            std.debug.print("failed to start save ticker: {}\n", .{err});
            return;
        };
        ticker.detach();

        self.serve() catch |err| {
            std.debug.print("stats server error: {}\n", .{err});
        };
    }

    fn saveTicker(s: *Stats) void {
        while (true) {
            io.sleep(.{ .nanoseconds = 60 * std.time.ns_per_s }, .awake) catch {};
            s.save();
        }
    }

    fn serve(self: *StatsServer) !void {
        var address = try net.IpAddress.parse("::", self.port);
        var server = try net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        defer server.deinit(io);

        std.debug.print("stats server listening on http://[::]:{}  \n", .{self.port});

        while (true) {
            const stream = server.accept(io) catch |err| {
                std.debug.print("accept error: {}\n", .{err});
                continue;
            };

            const t = Thread.spawn(.{}, handleConnection, .{ self, stream }) catch |err| {
                std.debug.print("spawn error: {}\n", .{err});
                stream.close(io);
                continue;
            };
            t.detach();
        }
    }

    fn handleConnection(self: *StatsServer, stream: net.Stream) void {
        defer stream.close(io);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;

        var reader = net.Stream.Reader.init(stream, io, &read_buffer);
        var writer = net.Stream.Writer.init(stream, io, &write_buffer);

        var server = http.Server.init(&reader.interface, &writer.interface);

        var request = server.receiveHead() catch return;

        const html = self.stats.renderHtml(self.allocator) catch |err| {
            std.debug.print("render error: {}\n", .{err});
            return;
        };
        defer self.allocator.free(html);

        request.respond(html, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        }) catch return;
    }
};
