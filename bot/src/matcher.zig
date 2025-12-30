const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Bufo = struct {
    name: []const u8,
    url: []const u8,
    phrase: []const []const u8,
};

pub const Match = struct {
    name: []const u8,
    url: []const u8,
};

pub const Matcher = struct {
    bufos: std.ArrayList(Bufo) = .{},
    allocator: Allocator,
    min_words: u32,

    pub fn init(allocator: Allocator, min_words: u32) Matcher {
        return .{
            .allocator = allocator,
            .min_words = min_words,
        };
    }

    pub fn deinit(self: *Matcher) void {
        for (self.bufos.items) |bufo| {
            self.allocator.free(bufo.name);
            self.allocator.free(bufo.url);
            for (bufo.phrase) |word| {
                self.allocator.free(word);
            }
            self.allocator.free(bufo.phrase);
        }
        self.bufos.deinit(self.allocator);
    }

    pub fn addBufo(self: *Matcher, name: []const u8, url: []const u8) !void {
        const phrase = try extractPhrase(self.allocator, name);

        if (phrase.len < self.min_words) {
            for (phrase) |word| self.allocator.free(word);
            self.allocator.free(phrase);
            return;
        }

        try self.bufos.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .url = try self.allocator.dupe(u8, url),
            .phrase = phrase,
        });
    }

    pub fn findMatch(self: *Matcher, text: []const u8) ?Match {
        var words: std.ArrayList([]const u8) = .{};
        defer words.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and !isAlpha(text[i])) : (i += 1) {}
            if (i >= text.len) break;

            const start = i;
            while (i < text.len and isAlpha(text[i])) : (i += 1) {}

            const word = text[start..i];
            if (word.len > 0) {
                words.append(self.allocator, word) catch continue;
            }
        }

        for (self.bufos.items) |bufo| {
            if (containsPhrase(words.items, bufo.phrase)) {
                return .{
                    .name = bufo.name,
                    .url = bufo.url,
                };
            }
        }
        return null;
    }

    pub fn count(self: *Matcher) usize {
        return self.bufos.items.len;
    }
};

fn extractPhrase(allocator: Allocator, name: []const u8) ![]const []const u8 {
    var start: usize = 0;
    if (mem.startsWith(u8, name, "bufo-")) {
        start = 5;
    }
    var end = name.len;
    if (mem.endsWith(u8, name, ".gif")) {
        end -= 4;
    } else if (mem.endsWith(u8, name, ".png")) {
        end -= 4;
    } else if (mem.endsWith(u8, name, ".jpg")) {
        end -= 4;
    } else if (mem.endsWith(u8, name, ".jpeg")) {
        end -= 5;
    }

    const slug = name[start..end];

    var words: std.ArrayList([]const u8) = .{};
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }

    var iter = mem.splitScalar(u8, slug, '-');
    while (iter.next()) |word| {
        if (word.len > 0) {
            const lower = try allocator.alloc(u8, word.len);
            for (word, 0..) |c, j| {
                lower[j] = std.ascii.toLower(c);
            }
            try words.append(allocator, lower);
        }
    }

    return try words.toOwnedSlice(allocator);
}

fn containsPhrase(post_words: []const []const u8, phrase: []const []const u8) bool {
    if (phrase.len == 0 or post_words.len < phrase.len) return false;

    outer: for (0..post_words.len - phrase.len + 1) |i| {
        for (phrase, 0..) |phrase_word, j| {
            if (!eqlIgnoreCase(post_words[i + j], phrase_word)) {
                continue :outer;
            }
        }
        return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
