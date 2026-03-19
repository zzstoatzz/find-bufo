const std = @import("std");
const mem = std.mem;
const json = std.json;
const zat = @import("zat");

const nsfw_labels: []const []const u8 = &.{
    "porn",
    "sexual",
    "nudity",
    "nsfl",
    "gore",
};

// hashtags/keywords to filter in post text (lowercase)
const nsfw_keywords: []const []const u8 = &.{
    "#nsfw",
    "#porn",
    "#xxx",
    "#18+",
    "#adult",
    "#onlyfans",
    "#sex",
    "#nude",
    "#nudes",
    "#naked",
    "#fetish",
    "#kink",
};

pub const Post = struct {
    uri: []const u8,
    text: []const u8,
    did: []const u8,
    rkey: []const u8,
};

pub const PostHandler = struct {
    callback: *const fn (Post) void,
    on_connect: ?*const fn ([]const u8) void = null,
    on_delete: ?*const fn ([]const u8, []const u8) void = null,
    on_block: ?*const fn ([]const u8, []const u8) void = null,
    on_detach: ?*const fn ([]const u8, json.Value) void = null,

    pub fn onEvent(self: *PostHandler, event: zat.JetstreamEvent) void {
        switch (event) {
            .commit => |c| self.handleCommit(c),
            else => {},
        }
    }

    pub fn onError(_: *PostHandler, err: anyerror) void {
        std.debug.print("jetstream error: {s}\n", .{@errorName(err)});
    }

    pub fn onConnect(self: *PostHandler, host: []const u8) void {
        if (self.on_connect) |cb| cb(host);
    }

    fn handleCommit(self: *PostHandler, c: zat.jetstream.CommitEvent) void {
        if (mem.eql(u8, c.collection, "app.bsky.graph.block")) {
            if (c.operation == .create) {
                const record = c.record orelse return;
                const subject = zat.json.getString(record, "subject") orelse return;
                if (self.on_block) |cb| cb(c.did, subject);
            }
            return;
        }

        if (mem.eql(u8, c.collection, "app.bsky.feed.postgate")) {
            if (c.operation == .create or c.operation == .update) {
                const record = c.record orelse return;
                if (self.on_detach) |cb| cb(c.did, record);
            }
            return;
        }

        // app.bsky.feed.post
        if (c.operation == .delete) {
            if (self.on_delete) |cb| cb(c.did, c.rkey);
            return;
        }

        if (c.operation != .create) return;

        const record = c.record orelse return;

        if (hasNsfwLabels(record)) return;

        const text = zat.json.getString(record, "text") orelse return;

        if (hasNsfwKeywords(text)) return;

        var uri_buf: [256]u8 = undefined;
        const uri = std.fmt.bufPrint(&uri_buf, "at://{s}/app.bsky.feed.post/{s}", .{ c.did, c.rkey }) catch return;

        self.callback(.{
            .uri = uri,
            .text = text,
            .did = c.did,
            .rkey = c.rkey,
        });
    }
};

fn hasNsfwLabels(record: json.Value) bool {
    const values = zat.json.getArray(record, "labels.values") orelse return false;

    for (values) |item| {
        const val = zat.json.getString(item, "val") orelse continue;
        for (nsfw_labels) |label| {
            if (mem.eql(u8, val, label)) return true;
        }
    }
    return false;
}

fn hasNsfwKeywords(text: []const u8) bool {
    var lower_buf: [4096]u8 = undefined;
    const len = @min(text.len, lower_buf.len);
    for (text[0..len], 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..len];

    for (nsfw_keywords) |keyword| {
        if (mem.indexOf(u8, lower, keyword) != null) return true;
    }
    return false;
}
