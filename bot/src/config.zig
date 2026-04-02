const std = @import("std");

pub const Config = struct {
    bsky_handle: []const u8,
    bsky_app_password: []const u8,
    preferred_jetstream: ?[]const u8,
    min_phrase_words: u32,
    posting_enabled: bool,
    cooldown_minutes: u32,
    exclude_patterns: []const u8,
    stats_port: u16,
    backend_url: []const u8,

    pub fn fromEnv() Config {
        return .{
            .bsky_handle = getenv("BSKY_HANDLE") orelse "find-bufo.com",
            .bsky_app_password = getenv("BSKY_APP_PASSWORD") orelse "",
            .preferred_jetstream = getenv("PREFERRED_JETSTREAM"),
            .min_phrase_words = parseU32(getenv("MIN_PHRASE_WORDS"), 4),
            .posting_enabled = parseBool(getenv("POSTING_ENABLED")),
            .cooldown_minutes = parseU32(getenv("COOLDOWN_MINUTES"), 120),
            .exclude_patterns = getenv("EXCLUDE_PATTERNS") orelse "what-have-you-done,what-have-i-done,sad,crying,cant-take,knife,what-are-you-doing-with-that",
            .stats_port = parseU16(getenv("STATS_PORT"), 8080),
            .backend_url = getenv("BACKEND_URL") orelse "https://find-bufo.com",
        };
    }
};

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn parseU16(str: ?[]const u8, default: u16) u16 {
    if (str) |s| {
        return std.fmt.parseInt(u16, s, 10) catch default;
    }
    return default;
}

fn parseU32(str: ?[]const u8, default: u32) u32 {
    if (str) |s| {
        return std.fmt.parseInt(u32, s, 10) catch default;
    }
    return default;
}

fn parseBool(str: ?[]const u8) bool {
    if (str) |s| {
        return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1");
    }
    return false;
}
