const std = @import("std");
const posix = std.posix;

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
            .bsky_handle = posix.getenv("BSKY_HANDLE") orelse "find-bufo.com",
            .bsky_app_password = posix.getenv("BSKY_APP_PASSWORD") orelse "",
            .preferred_jetstream = posix.getenv("PREFERRED_JETSTREAM"),
            .min_phrase_words = parseU32(posix.getenv("MIN_PHRASE_WORDS"), 4),
            .posting_enabled = parseBool(posix.getenv("POSTING_ENABLED")),
            .cooldown_minutes = parseU32(posix.getenv("COOLDOWN_MINUTES"), 120),
            .exclude_patterns = posix.getenv("EXCLUDE_PATTERNS") orelse "what-have-you-done,what-have-i-done,sad,crying,cant-take,knife,what-are-you-doing-with-that",
            .stats_port = parseU16(posix.getenv("STATS_PORT"), 8080),
            .backend_url = posix.getenv("BACKEND_URL") orelse "https://find-bufo.com",
        };
    }
};

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
