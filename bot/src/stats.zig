const std = @import("std");
const mem = std.mem;
const json = std.json;
const fs = std.fs;
const Allocator = mem.Allocator;
const Thread = std.Thread;
const template = @import("stats_template.zig");

const STATS_PATH = "/data/stats.json";

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

    // track per-bufo match counts: name -> {count, url}
    bufo_matches: std.StringHashMap(BufoMatchData),
    bufo_mutex: Thread.Mutex = .{},

    const BufoMatchData = struct {
        count: u64,
        url: []const u8,
    };

    pub fn init(allocator: Allocator) Stats {
        var self = Stats{
            .allocator = allocator,
            .start_time = std.time.timestamp(),
            .bufo_matches = std.StringHashMap(BufoMatchData).init(allocator),
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
    }

    fn load(self: *Stats) void {
        const file = fs.openFileAbsolute(STATS_PATH, .{}) catch return;
        defer file.close();

        var buf: [64 * 1024]u8 = undefined;
        const len = file.readAll(&buf) catch return;
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

        std.debug.print("loaded stats from {s}\n", .{STATS_PATH});
    }

    pub fn save(self: *Stats) void {
        self.bufo_mutex.lock();
        defer self.bufo_mutex.unlock();
        self.saveUnlocked();
    }

    pub fn totalUptime(self: *Stats) i64 {
        const now = std.time.timestamp();
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
        self.bufo_mutex.lock();
        defer self.bufo_mutex.unlock();

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
        const file = fs.createFileAbsolute(STATS_PATH, .{}) catch return;
        defer file.close();

        const now = std.time.timestamp();
        const session_uptime: u64 = @intCast(@max(0, now - self.start_time));
        const total_uptime = self.prior_uptime + session_uptime;

        var buf: [64 * 1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        writer.writeAll("{") catch return;
        std.fmt.format(writer, "\"posts_checked\":{},", .{self.posts_checked.load(.monotonic)}) catch return;
        std.fmt.format(writer, "\"matches_found\":{},", .{self.matches_found.load(.monotonic)}) catch return;
        std.fmt.format(writer, "\"posts_created\":{},", .{self.posts_created.load(.monotonic)}) catch return;
        std.fmt.format(writer, "\"cooldowns_hit\":{},", .{self.cooldowns_hit.load(.monotonic)}) catch return;
        std.fmt.format(writer, "\"blocks_respected\":{},", .{self.blocks_respected.load(.monotonic)}) catch return;
        std.fmt.format(writer, "\"errors\":{},", .{self.errors.load(.monotonic)}) catch return;
        std.fmt.format(writer, "\"cumulative_uptime\":{},", .{total_uptime}) catch return;
        writer.writeAll("\"bufo_matches\":{") catch return;

        var first = true;
        var iter = self.bufo_matches.iterator();
        while (iter.next()) |entry| {
            if (!first) writer.writeAll(",") catch return;
            first = false;
            std.fmt.format(writer, "\"{s}\":{{\"count\":{},\"url\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.count, entry.value_ptr.url }) catch return;
        }

        writer.writeAll("}}") catch return;
        file.writeAll(fbs.getWritten()) catch return;
    }

    const COOLDOWN_SCALE_FACTOR: f64 = 8.0;

    pub fn getCooldownSeconds(self: *Stats, bufo_name: []const u8, base_secs: u64) u64 {
        self.bufo_mutex.lock();
        defer self.bufo_mutex.unlock();

        const bufo_count: u64 = if (self.bufo_matches.get(bufo_name)) |data| data.count else 0;

        var total_count: u64 = 0;
        var iter = self.bufo_matches.iterator();
        while (iter.next()) |entry| {
            total_count += entry.value_ptr.count;
        }
        if (total_count == 0) return base_secs;

        const ratio = @as(f64, @floatFromInt(bufo_count)) / @as(f64, @floatFromInt(total_count));
        const multiplier = 1.0 + COOLDOWN_SCALE_FACTOR * ratio;
        return @intFromFloat(@as(f64, @floatFromInt(base_secs)) * multiplier);
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
        var top_bufos: std.ArrayList(BufoEntry) = .{};
        defer top_bufos.deinit(allocator);

        {
            self.bufo_mutex.lock();
            defer self.bufo_mutex.unlock();

            var iter = self.bufo_matches.iterator();
            while (iter.next()) |entry| {
                try top_bufos.append(allocator, .{ .name = entry.key_ptr.*, .count = entry.value_ptr.count, .url = entry.value_ptr.url });
            }
        }

        // sort by count descending
        mem.sort(BufoEntry, top_bufos.items, {}, BufoEntry.compare);

        // build top bufos grid html
        var top_html: std.ArrayList(u8) = .{};
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

            try std.fmt.format(top_html.writer(allocator),
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

    pub fn init(allocator: Allocator, stats: *Stats, port: u16) StatsServer {
        return .{
            .allocator = allocator,
            .stats = stats,
            .port = port,
        };
    }

    pub fn run(self: *StatsServer) void {
        // spawn periodic save ticker (every 60s)
        _ = Thread.spawn(.{}, saveTicker, .{self.stats}) catch {};

        self.serve() catch |err| {
            std.debug.print("stats server error: {}\n", .{err});
        };
    }

    fn saveTicker(s: *Stats) void {
        while (true) {
            std.Thread.sleep(60 * std.time.ns_per_s);
            s.save();
        }
    }

    fn serve(self: *StatsServer) !void {
        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);

        var server = try addr.listen(.{ .reuse_address = true });
        defer server.deinit();

        std.debug.print("stats server listening on http://0.0.0.0:{}\n", .{self.port});

        while (true) {
            const conn = server.accept() catch |err| {
                std.debug.print("accept error: {}\n", .{err});
                continue;
            };

            self.handleConnection(conn) catch |err| {
                std.debug.print("connection error: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *StatsServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        // read request (we don't really care about it, just serve stats)
        var buf: [1024]u8 = undefined;
        _ = conn.stream.read(&buf) catch {};

        const html = self.stats.renderHtml(self.allocator) catch |err| {
            std.debug.print("render error: {}\n", .{err});
            return;
        };
        defer self.allocator.free(html);

        // write raw HTTP response
        var response_buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{html.len}) catch return;

        _ = conn.stream.write(header) catch return;
        _ = conn.stream.write(html) catch return;
    }
};
