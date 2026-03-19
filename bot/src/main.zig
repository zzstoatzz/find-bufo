const std = @import("std");
const mem = std.mem;
const json = std.json;
const http = std.http;
const Thread = std.Thread;
const Allocator = mem.Allocator;
const zat = @import("zat");
const config = @import("config.zig");
const matcher = @import("matcher.zig");
const jetstream = @import("jetstream.zig");
const bsky = @import("bsky.zig");
const stats = @import("stats.zig");

var global_state: ?*BotState = null;

const BotState = struct {
    allocator: Allocator,
    config: config.Config,
    matcher: matcher.Matcher,
    bsky_client: bsky.BskyClient,
    mutex: Thread.Mutex = .{},
    stats: stats.Stats,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("starting bufo bot...\n", .{});

    const cfg = config.Config.fromEnv();

    // load bufos from API
    var m = matcher.Matcher.init(allocator, cfg.min_phrase_words);
    try loadBufos(allocator, &m, cfg.exclude_patterns);
    std.debug.print("loaded {} bufos with >= {} word phrases\n", .{ m.count(), cfg.min_phrase_words });

    if (m.count() == 0) {
        std.debug.print("no bufos loaded, exiting\n", .{});
        return;
    }

    // init bluesky client
    var bsky_client = bsky.BskyClient.init(allocator, cfg.bsky_handle, cfg.bsky_app_password);
    defer bsky_client.deinit();

    if (cfg.posting_enabled) {
        try bsky_client.login();
    } else {
        std.debug.print("posting disabled, running in dry-run mode\n", .{});
    }

    // init stats
    var bot_stats = stats.Stats.init(allocator);
    defer bot_stats.deinit();
    bot_stats.setBufosLoaded(@intCast(m.count()));

    // prune tracked posts older than 30 days
    bot_stats.pruneOldPosts(30 * 86400);

    // init state
    var state = BotState{
        .allocator = allocator,
        .config = cfg,
        .matcher = m,
        .bsky_client = bsky_client,
        .stats = bot_stats,
    };

    global_state = &state;

    // startup scan: bootstrap tracking and clean stale posts
    if (cfg.posting_enabled) {
        startupScan(&state);
    }

    // start stats server on background thread
    var stats_server = stats.StatsServer.init(allocator, &state.stats, cfg.stats_port);
    const stats_thread = Thread.spawn(.{}, stats.StatsServer.run, .{&stats_server}) catch |err| {
        std.debug.print("failed to start stats server: {}\n", .{err});
        return err;
    };
    defer stats_thread.join();

    // start jetstream consumer (use zat defaults with optional preferred relay)
    var handler = jetstream.PostHandler{
        .callback = onPost,
        .on_connect = onConnect,
        .on_delete = onDelete,
        .on_block = onBlock,
        .on_detach = onDetach,
    };

    // prepend preferred relay to default host list if set
    var hosts_buf: [1 + zat.jetstream.default_hosts.len][]const u8 = undefined;
    var hosts_len: usize = 0;
    if (cfg.preferred_jetstream) |host| {
        hosts_buf[0] = host;
        hosts_len = 1;
    }
    for (zat.jetstream.default_hosts) |h| {
        hosts_buf[hosts_len] = h;
        hosts_len += 1;
    }

    var client = zat.JetstreamClient.init(allocator, .{
        .hosts = hosts_buf[0..hosts_len],
        .wanted_collections = &.{ "app.bsky.feed.post", "app.bsky.graph.block", "app.bsky.feed.postgate" },
    });
    defer client.deinit();
    client.subscribe(&handler);
}

fn onConnect(host: []const u8) void {
    const state = global_state orelse return;
    std.debug.print("connected to jetstream: {s}\n", .{host});
    state.stats.setJetstreamHost(host);
}

fn onPost(post: jetstream.Post) void {
    const state = global_state orelse return;

    state.stats.incPostsChecked();

    // check for match
    const match = state.matcher.findMatch(post.text) orelse return;

    state.stats.incMatchesFound();
    state.stats.incBufoMatch(match.name, match.url);
    std.debug.print("match: {s}\n", .{match.name});

    if (!state.config.posting_enabled) {
        std.debug.print("posting disabled, skipping\n", .{});
        return;
    }

    state.mutex.lock();
    defer state.mutex.unlock();

    // check cooldown (scaled by match frequency, persisted across restarts)
    const now = std.time.timestamp();
    const base_secs: u64 = @as(u64, state.config.cooldown_minutes) * 60;
    const cooldown_secs: i64 = @intCast(state.stats.getCooldownSeconds(match.name, base_secs));

    if (state.stats.getLastPosted(match.name)) |last_posted| {
        if (now - last_posted < cooldown_secs) {
            state.stats.incCooldownsHit();
            const cooldown_mins = @divTrunc(@as(u64, @intCast(cooldown_secs)), 60);
            std.debug.print("cooldown: {s} ({} min), skipping\n", .{ match.name, cooldown_mins });
            return;
        }
    }

    // check if poster blocks us
    const is_blocked = state.bsky_client.isBlockedBy(post.did) catch |err| blk: {
        std.debug.print("block check failed: {}, proceeding with post\n", .{err});
        break :blk false;
    };
    if (is_blocked) {
        state.stats.incBlocksRespected();
        std.debug.print("blocked by {s}, skipping\n", .{post.did});
        return;
    }

    // try to post, with one retry on token expiration
    tryPost(state, post, match, now) catch |err| {
        if (err == error.ExpiredToken) {
            std.debug.print("token expired, re-logging in...\n", .{});
            state.bsky_client.login() catch |login_err| {
                std.debug.print("failed to re-login: {}\n", .{login_err});
                state.stats.incErrors();
                return;
            };
            std.debug.print("re-login successful, retrying post...\n", .{});
            tryPost(state, post, match, now) catch |retry_err| {
                std.debug.print("retry failed: {}\n", .{retry_err});
                state.stats.incErrors();
            };
        } else {
            state.stats.incErrors();
        }
    };
}

fn tryPost(state: *BotState, post: jetstream.Post, match: matcher.Match, now: i64) !void {
    // fetch bufo image (route non-GIF images through resize proxy)
    const is_gif = mem.endsWith(u8, match.url, ".gif");

    var url_buf: [1024]u8 = undefined;
    const fetch_url = if (is_gif)
        match.url
    else
        std.fmt.bufPrint(&url_buf, "{s}/api/image?url={s}&max_bytes=900000", .{ state.config.backend_url, match.url }) catch match.url;

    const img_data = try state.bsky_client.fetchImage(fetch_url);
    defer state.allocator.free(img_data);

    // build alt text (name without extension, dashes to spaces)
    var alt_buf: [128]u8 = undefined;
    var alt_len: usize = 0;
    for (match.name) |c| {
        if (c == '-') {
            alt_buf[alt_len] = ' ';
        } else if (c == '.') {
            break; // stop at extension
        } else {
            alt_buf[alt_len] = c;
        }
        alt_len += 1;
        if (alt_len >= alt_buf.len - 1) break;
    }
    const alt_text = alt_buf[0..alt_len];

    // get post CID for quote
    const cid = try state.bsky_client.getPostCid(post.uri);
    defer state.allocator.free(cid);

    const our_rkey = if (is_gif) blk: {
        // upload as video for animated GIFs
        std.debug.print("uploading {d} bytes as video\n", .{img_data.len});
        const job_id = try state.bsky_client.uploadVideo(img_data, match.name);
        defer state.allocator.free(job_id);

        std.debug.print("waiting for video processing (job: {s})...\n", .{job_id});
        const blob_json = try state.bsky_client.waitForVideo(job_id);
        defer state.allocator.free(blob_json);

        break :blk try state.bsky_client.createVideoQuotePost(post.uri, cid, blob_json, alt_text);
    } else blk: {
        // upload as image
        const content_type = if (mem.endsWith(u8, match.url, ".png"))
            "image/png"
        else
            "image/jpeg";

        std.debug.print("uploading {d} bytes as {s}\n", .{ img_data.len, content_type });
        const blob_json = try state.bsky_client.uploadBlob(img_data, content_type);
        defer state.allocator.free(blob_json);

        break :blk try state.bsky_client.createQuotePost(post.uri, cid, blob_json, alt_text);
    };
    defer state.allocator.free(our_rkey);

    std.debug.print("posted bufo quote: {s} (rkey: {s})\n", .{ match.name, our_rkey });
    state.stats.incPostsCreated();

    // track our post for cleanup on delete/block
    state.stats.addTrackedPost(our_rkey, post.uri, post.did, now);

    // update cooldown cache (persisted to disk)
    state.stats.setLastPosted(match.name, now);
}

fn onDelete(did: []const u8, rkey: []const u8) void {
    const state = global_state orelse return;

    // construct the original URI and check if we quote-posted it
    var uri_buf: [256]u8 = undefined;
    const uri = std.fmt.bufPrint(&uri_buf, "at://{s}/app.bsky.feed.post/{s}", .{ did, rkey }) catch return;

    const our_rkey = state.stats.removeByOriginalUri(uri) orelse return;
    defer state.allocator.free(our_rkey);

    std.debug.print("original post deleted ({s}), deleting our quote-post {s}\n", .{ uri, our_rkey });

    state.mutex.lock();
    defer state.mutex.unlock();

    state.bsky_client.deleteRecord(our_rkey) catch |err| {
        std.debug.print("failed to delete our post: {}\n", .{err});
        state.stats.incErrors();
    };
}

fn onBlock(blocker_did: []const u8, subject_did: []const u8) void {
    const state = global_state orelse return;

    // only care if someone is blocking us
    const our_did = state.bsky_client.did orelse return;
    if (!mem.eql(u8, subject_did, our_did)) return;

    std.debug.print("blocked by {s}, cleaning up our quote-posts of their content\n", .{blocker_did});

    state.mutex.lock();
    defer state.mutex.unlock();

    // collect and remove tracked posts from this DID
    var rkey_buf: [64][]const u8 = undefined;
    const rkeys = state.stats.removeByOriginalDid(blocker_did, &rkey_buf);

    for (rkeys) |rkey| {
        state.bsky_client.deleteRecord(rkey) catch |err| {
            std.debug.print("failed to delete post {s}: {}\n", .{ rkey, err });
            state.stats.incErrors();
        };
        state.allocator.free(rkey);
    }

    if (rkeys.len > 0) {
        std.debug.print("deleted {} quote-posts after block from {s}\n", .{ rkeys.len, blocker_did });
    }
}

fn onDetach(_: []const u8, record: json.Value) void {
    const state = global_state orelse return;

    // postgate record has detachedEmbeddingUris: array of AT-URIs that should no longer embed
    const uris = record.object.get("detachedEmbeddingUris") orelse return;
    if (uris != .array) return;

    const our_did = state.bsky_client.did orelse return;

    state.mutex.lock();
    defer state.mutex.unlock();

    for (uris.array.items) |uri_val| {
        if (uri_val != .string) continue;

        // check if this detached URI is one of our tracked posts
        // the URI in detachedEmbeddingUris points to the embedding post (ours)
        // parse rkey from at://did/app.bsky.feed.post/rkey
        if (!mem.startsWith(u8, uri_val.string, "at://")) continue;
        var parts = mem.splitScalar(u8, uri_val.string[5..], '/');
        const uri_did = parts.next() orelse continue;

        // only care about URIs pointing at our posts
        if (!mem.eql(u8, uri_did, our_did)) continue;

        _ = parts.next(); // collection
        const rkey = parts.next() orelse continue;

        if (state.stats.removeByOurRkey(rkey)) {
            std.debug.print("post detached, deleting our quote-post {s}\n", .{rkey});
            state.bsky_client.deleteRecord(rkey) catch |err| {
                std.debug.print("failed to delete detached post {s}: {}\n", .{ rkey, err });
                state.stats.incErrors();
            };
        }
    }
}

fn startupScan(state: *BotState) void {
    std.debug.print("running startup scan...\n", .{});

    var feed_buf: [100]bsky.BskyClient.FeedPost = undefined;
    const posts = state.bsky_client.getAuthorFeed(&feed_buf) catch |err| {
        std.debug.print("startup scan failed: {}\n", .{err});
        return;
    };

    var bootstrapped: usize = 0;
    var cleaned: usize = 0;
    const now = std.time.timestamp();

    for (posts) |post| {
        defer {
            state.allocator.free(post.original_uri);
            state.allocator.free(post.original_did);
        }

        if (post.is_stale) {
            // delete stale post regardless of whether it was tracked
            std.debug.print("startup: cleaning stale post {s}\n", .{post.rkey});
            state.bsky_client.deleteRecord(post.rkey) catch |err| {
                std.debug.print("startup: failed to delete {s}: {}\n", .{ post.rkey, err });
                state.stats.incErrors();
            };
            // remove from tracking if present
            _ = state.stats.removeByOurRkey(post.rkey);
            state.allocator.free(post.rkey);
            cleaned += 1;
        } else {
            // bootstrap tracking for posts we don't know about yet
            if (!state.stats.isTracked(post.rkey)) {
                state.stats.addTrackedPost(post.rkey, post.original_uri, post.original_did, now);
                bootstrapped += 1;
            }
            state.allocator.free(post.rkey);
        }
    }

    std.debug.print("startup scan complete: {} bootstrapped, {} cleaned\n", .{ bootstrapped, cleaned });
}

fn loadBufos(allocator: Allocator, m: *matcher.Matcher, exclude_patterns: []const u8) !void {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://find-bufo.com/api/search?query=bufo&top_k=2000&alpha=0&exclude={s}", .{exclude_patterns}) catch return error.UrlTooLong;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
    }) catch |err| {
        std.debug.print("failed to fetch bufos: {}\n", .{err});
        return err;
    };

    if (result.status != .ok) {
        std.debug.print("failed to fetch bufos, status: {}\n", .{result.status});
        return error.FetchFailed;
    }

    const response_list = aw.toArrayList();
    const response = response_list.items;

    const parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch return error.ParseError;
    defer parsed.deinit();

    const results = parsed.value.object.get("results") orelse return;
    if (results != .array) return;

    var loaded: usize = 0;
    for (results.array.items) |item| {
        if (item != .object) continue;

        const name_val = item.object.get("name") orelse continue;
        if (name_val != .string) continue;

        const url_val = item.object.get("url") orelse continue;
        if (url_val != .string) continue;

        m.addBufo(name_val.string, url_val.string) catch continue;
        loaded += 1;
    }

    std.debug.print("loaded {} bufos from API\n", .{loaded});
}
