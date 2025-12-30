const std = @import("std");
const mem = std.mem;
const json = std.json;
const http = std.http;
const Thread = std.Thread;
const Allocator = mem.Allocator;
const config = @import("config.zig");
const matcher = @import("matcher.zig");
const jetstream = @import("jetstream.zig");
const bsky = @import("bsky.zig");

var global_state: ?*BotState = null;

const BotState = struct {
    allocator: Allocator,
    config: config.Config,
    matcher: matcher.Matcher,
    bsky_client: bsky.BskyClient,
    recent_bufos: std.StringHashMap(i64), // name -> timestamp
    mutex: Thread.Mutex = .{},
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

    // init state
    var state = BotState{
        .allocator = allocator,
        .config = cfg,
        .matcher = m,
        .bsky_client = bsky_client,
        .recent_bufos = std.StringHashMap(i64).init(allocator),
    };
    defer state.recent_bufos.deinit();

    global_state = &state;

    // start jetstream consumer
    var js = jetstream.JetstreamClient.init(allocator, cfg.jetstream_endpoint, onPost);
    js.run();
}

fn onPost(post: jetstream.Post) void {
    const state = global_state orelse return;

    // check for match
    const match = state.matcher.findMatch(post.text) orelse return;

    std.debug.print("match: {s}\n", .{match.name});

    if (!state.config.posting_enabled) {
        std.debug.print("posting disabled, skipping\n", .{});
        return;
    }

    state.mutex.lock();
    defer state.mutex.unlock();

    // check cooldown
    const now = std.time.timestamp();
    const cooldown_secs = @as(i64, @intCast(state.config.cooldown_minutes)) * 60;

    if (state.recent_bufos.get(match.name)) |last_posted| {
        if (now - last_posted < cooldown_secs) {
            std.debug.print("cooldown: {s} posted recently, skipping\n", .{match.name});
            return;
        }
    }

    // fetch bufo image
    const img_data = state.bsky_client.fetchImage(match.url) catch |err| {
        std.debug.print("failed to fetch bufo image: {}\n", .{err});
        return;
    };
    defer state.allocator.free(img_data);

    // determine content type from URL
    const content_type = if (mem.endsWith(u8, match.url, ".gif"))
        "image/gif"
    else if (mem.endsWith(u8, match.url, ".png"))
        "image/png"
    else
        "image/jpeg";

    // upload blob
    const blob_json = state.bsky_client.uploadBlob(img_data, content_type) catch |err| {
        std.debug.print("failed to upload blob: {}\n", .{err});
        return;
    };
    defer state.allocator.free(blob_json);

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
    const cid = state.bsky_client.getPostCid(post.uri) catch |err| {
        std.debug.print("failed to get post CID: {}\n", .{err});
        return;
    };
    defer state.allocator.free(cid);

    state.bsky_client.createQuotePost(post.uri, cid, blob_json, alt_text) catch |err| {
        std.debug.print("failed to create quote post: {}\n", .{err});
        return;
    };
    std.debug.print("posted bufo quote: {s}\n", .{match.name});

    // update cooldown cache
    state.recent_bufos.put(match.name, now) catch {};
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
