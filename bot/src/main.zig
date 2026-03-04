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
    bot_stats.jetstream_endpoint = cfg.jetstream_endpoint;

    // init state
    var state = BotState{
        .allocator = allocator,
        .config = cfg,
        .matcher = m,
        .bsky_client = bsky_client,
        .stats = bot_stats,
    };

    global_state = &state;

    // start stats server on background thread
    var stats_server = stats.StatsServer.init(allocator, &state.stats, cfg.stats_port);
    const stats_thread = Thread.spawn(.{}, stats.StatsServer.run, .{&stats_server}) catch |err| {
        std.debug.print("failed to start stats server: {}\n", .{err});
        return err;
    };
    defer stats_thread.join();

    // start jetstream consumer
    var handler = jetstream.PostHandler{ .callback = onPost };
    var client = zat.JetstreamClient.init(allocator, .{
        .hosts = &.{cfg.jetstream_endpoint},
        .wanted_collections = &.{"app.bsky.feed.post"},
    });
    defer client.deinit();
    client.subscribe(&handler);
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
    // fetch bufo image
    const img_data = try state.bsky_client.fetchImage(match.url);
    defer state.allocator.free(img_data);

    const is_gif = mem.endsWith(u8, match.url, ".gif");

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

    if (is_gif) {
        // upload as video for animated GIFs
        std.debug.print("uploading {d} bytes as video\n", .{img_data.len});
        const job_id = try state.bsky_client.uploadVideo(img_data, match.name);
        defer state.allocator.free(job_id);

        std.debug.print("waiting for video processing (job: {s})...\n", .{job_id});
        const blob_json = try state.bsky_client.waitForVideo(job_id);
        defer state.allocator.free(blob_json);

        try state.bsky_client.createVideoQuotePost(post.uri, cid, blob_json, alt_text);
    } else {
        // upload as image
        const content_type = if (mem.endsWith(u8, match.url, ".png"))
            "image/png"
        else
            "image/jpeg";

        std.debug.print("uploading {d} bytes as {s}\n", .{ img_data.len, content_type });
        const blob_json = try state.bsky_client.uploadBlob(img_data, content_type);
        defer state.allocator.free(blob_json);

        try state.bsky_client.createQuotePost(post.uri, cid, blob_json, alt_text);
    }
    std.debug.print("posted bufo quote: {s}\n", .{match.name});
    state.stats.incPostsCreated();

    // update cooldown cache (persisted to disk)
    state.stats.setLastPosted(match.name, now);
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
