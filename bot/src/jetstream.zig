const std = @import("std");
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const Allocator = mem.Allocator;
const websocket = @import("websocket");

pub const Post = struct {
    uri: []const u8,
    text: []const u8,
    did: []const u8,
    rkey: []const u8,
};

pub const JetstreamClient = struct {
    allocator: Allocator,
    host: []const u8,
    callback: *const fn (Post) void,

    pub fn init(allocator: Allocator, host: []const u8, callback: *const fn (Post) void) JetstreamClient {
        return .{
            .allocator = allocator,
            .host = host,
            .callback = callback,
        };
    }

    pub fn run(self: *JetstreamClient) void {
        // exponential backoff: 1s -> 2s -> 4s -> ... -> 60s cap
        var backoff: u64 = 1;
        const max_backoff: u64 = 60;

        while (true) {
            self.connect() catch |err| {
                std.debug.print("jetstream error: {}, reconnecting in {}s...\n", .{ err, backoff });
            };
            posix.nanosleep(backoff, 0);
            backoff = @min(backoff * 2, max_backoff);
        }
    }

    fn connect(self: *JetstreamClient) !void {
        const path = "/subscribe?wantedCollections=app.bsky.feed.post";

        std.debug.print("connecting to wss://{s}{s}\n", .{ self.host, path });

        var client = websocket.Client.init(self.allocator, .{
            .host = self.host,
            .port = 443,
            .tls = true,
            .max_size = 1024 * 1024, // 1MB - some jetstream messages are large
        }) catch |err| {
            std.debug.print("websocket client init failed: {}\n", .{err});
            return err;
        };
        defer client.deinit();

        var host_header_buf: [256]u8 = undefined;
        const host_header = std.fmt.bufPrint(&host_header_buf, "Host: {s}\r\n", .{self.host}) catch self.host;

        client.handshake(path, .{ .headers = host_header }) catch |err| {
            std.debug.print("websocket handshake failed: {}\n", .{err});
            return err;
        };

        std.debug.print("jetstream connected!\n", .{});

        var handler = Handler{ .allocator = self.allocator, .callback = self.callback };
        client.readLoop(&handler) catch |err| {
            std.debug.print("websocket read loop error: {}\n", .{err});
            return err;
        };
    }
};

const Handler = struct {
    allocator: Allocator,
    callback: *const fn (Post) void,
    msg_count: usize = 0,

    pub fn serverMessage(self: *Handler, data: []const u8) !void {
        self.msg_count += 1;
        if (self.msg_count % 1000 == 1) {
            std.debug.print("jetstream: processed {} messages\n", .{self.msg_count});
        }
        self.processMessage(data) catch |err| {
            if (err != error.NotAPost) {
                std.debug.print("message processing error: {}\n", .{err});
            }
        };
    }

    pub fn close(_: *Handler) void {
        std.debug.print("jetstream connection closed\n", .{});
    }

    fn processMessage(self: *Handler, payload: []const u8) !void {
        // jetstream format:
        // { "did": "...", "kind": "commit", "commit": { "collection": "app.bsky.feed.post", "rkey": "...", "record": { "text": "...", ... } } }
        const parsed = json.parseFromSlice(json.Value, self.allocator, payload, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const root = parsed.value.object;

        // check kind
        const kind = root.get("kind") orelse return error.NotAPost;
        if (kind != .string or !mem.eql(u8, kind.string, "commit")) return error.NotAPost;

        // get did
        const did_val = root.get("did") orelse return error.NotAPost;
        if (did_val != .string) return error.NotAPost;

        // get commit
        const commit = root.get("commit") orelse return error.NotAPost;
        if (commit != .object) return error.NotAPost;

        // check collection
        const collection = commit.object.get("collection") orelse return error.NotAPost;
        if (collection != .string or !mem.eql(u8, collection.string, "app.bsky.feed.post")) return error.NotAPost;

        // check operation (create only)
        const operation = commit.object.get("operation") orelse return error.NotAPost;
        if (operation != .string or !mem.eql(u8, operation.string, "create")) return error.NotAPost;

        // get rkey
        const rkey_val = commit.object.get("rkey") orelse return error.NotAPost;
        if (rkey_val != .string) return error.NotAPost;

        // get record
        const record = commit.object.get("record") orelse return error.NotAPost;
        if (record != .object) return error.NotAPost;

        // get text
        const text_val = record.object.get("text") orelse return error.NotAPost;
        if (text_val != .string) return error.NotAPost;

        // construct uri
        var uri_buf: [256]u8 = undefined;
        const uri = std.fmt.bufPrint(&uri_buf, "at://{s}/app.bsky.feed.post/{s}", .{ did_val.string, rkey_val.string }) catch return error.UriTooLong;

        self.callback(.{
            .uri = uri,
            .text = text_val.string,
            .did = did_val.string,
            .rkey = rkey_val.string,
        });
    }
};
