# zig atproto sdk wishlist

a pie-in-the-sky wishlist for what a zig AT protocol sdk could provide, based on building [bufo-bot](../bot) - a firehose bot that quote-posts matching images.

---

## 1. typed lexicon schemas

the single biggest pain point: everything is `json.Value` with manual field extraction.

### what we have now

```zig
const parsed = json.parseFromSlice(json.Value, allocator, response.items, .{});
const root = parsed.value.object;
const jwt_val = root.get("accessJwt") orelse return error.NoJwt;
if (jwt_val != .string) return error.NoJwt;
self.access_jwt = try self.allocator.dupe(u8, jwt_val.string);
```

this pattern repeats hundreds of times. it's verbose, error-prone, and provides zero compile-time safety.

### what we want

```zig
const atproto = @import("atproto");

// codegen from lexicon json schemas
const session = try atproto.server.createSession(allocator, .{
    .identifier = handle,
    .password = app_password,
});
// session.accessJwt is already []const u8
// session.did is already []const u8
// session.handle is already []const u8
```

ideally:
- generate zig structs from lexicon json files at build time (build.zig integration)
- full type safety - if a field is optional in the lexicon, it's `?T` in zig
- proper union types for lexicon unions (e.g., embed types)
- automatic serialization/deserialization

### lexicon unions are especially painful

```zig
// current: manual $type dispatch
const embed_type = record.object.get("$type") orelse return error.NoType;
if (mem.eql(u8, embed_type.string, "app.bsky.embed.images")) {
    // handle images...
} else if (mem.eql(u8, embed_type.string, "app.bsky.embed.video")) {
    // handle video...
} else if (mem.eql(u8, embed_type.string, "app.bsky.embed.record")) {
    // handle quote...
} else if (mem.eql(u8, embed_type.string, "app.bsky.embed.recordWithMedia")) {
    // handle quote with media...
}

// wanted: tagged union
switch (record.embed) {
    .images => |imgs| { ... },
    .video => |vid| { ... },
    .record => |quote| { ... },
    .recordWithMedia => |rwm| { ... },
}
```

---

## 2. session management

authentication is surprisingly complex and we had to handle it all manually.

### what we had to build

- login with identifier + app password
- store access JWT and refresh JWT
- detect `ExpiredToken` errors in response bodies
- re-login on expiration (we just re-login, didn't implement refresh)
- resolve DID to PDS host via plc.directory lookup
- get service auth tokens for video upload

### what we want

```zig
const atproto = @import("atproto");

var agent = try atproto.Agent.init(allocator, .{
    .service = "https://bsky.social",
});

// login with automatic token refresh
try agent.login(handle, app_password);

// agent automatically:
// - refreshes tokens before expiration
// - retries on ExpiredToken errors
// - resolves DID -> PDS host
// - handles service auth for video.bsky.app

// just use it, auth is handled
const blob = try agent.uploadBlob(data, "image/png");
```

### service auth is particularly gnarly

for video uploads, you need:
1. get a service auth token scoped to `did:web:video.bsky.app` with lexicon `com.atproto.repo.uploadBlob`
2. use that token (not your session token) for the upload
3. the endpoint is different (`video.bsky.app` not `bsky.social`)

we had to figure this out from reading other implementations. an sdk should abstract this entirely.

---

## 3. blob and media handling

uploading media requires too much manual work.

### current pain

```zig
// upload blob, get back raw json string
const blob_json = try client.uploadBlob(data, content_type);
// later, interpolate that json string into another json blob
try body_buf.print(allocator,
    \\{{"image":{s},"alt":"{s}"}}
, .{ blob_json, alt_text });
```

we're passing around json strings and interpolating them. this is fragile.

### what we want

```zig
// upload returns a typed BlobRef
const blob = try agent.uploadBlob(data, .{ .mime_type = "image/png" });

// use it directly in a struct
const post = atproto.feed.Post{
    .text = "",
    .embed = .{ .images = .{
        .images = &[_]atproto.embed.Image{
            .{ .image = blob, .alt = "a bufo" },
        },
    }},
};
try agent.createRecord("app.bsky.feed.post", post);
```

### video upload is even worse

```zig
// current: manual job polling
const job_id = try client.uploadVideo(data, filename);
var attempts: u32 = 0;
while (attempts < 60) : (attempts += 1) {
    // poll job status
    // check for JOB_STATE_COMPLETED or JOB_STATE_FAILED
    // sleep 1 second between polls
}

// wanted: one call that handles the async nature
const video_blob = try agent.uploadVideo(data, .{
    .filename = "bufo.gif",
    .mime_type = "image/gif",
    // sdk handles polling internally
});
```

---

## 4. AT-URI utilities

we parse AT-URIs by hand with string splitting.

```zig
// current
var parts = mem.splitScalar(u8, uri[5..], '/'); // skip "at://"
const did = parts.next() orelse return error.InvalidUri;
_ = parts.next(); // skip collection
const rkey = parts.next() orelse return error.InvalidUri;

// wanted
const parsed = atproto.AtUri.parse(uri);
// parsed.repo (the DID)
// parsed.collection
// parsed.rkey
```

also want:
- `AtUri.format()` to construct URIs
- validation (is this a valid DID? valid rkey?)
- CID parsing/validation

---

## 5. jetstream / firehose client

we used a separate websocket library and manually parsed jetstream messages.

### current

```zig
const websocket = @import("websocket"); // third party

// manual connection with exponential backoff
// manual message parsing
// manual event dispatch
```

### what we want

```zig
const atproto = @import("atproto");

var jetstream = atproto.Jetstream.init(allocator, .{
    .endpoint = "jetstream2.us-east.bsky.network",
    .collections = &[_][]const u8{"app.bsky.feed.post"},
});

// typed events!
while (try jetstream.next()) |event| {
    switch (event) {
        .commit => |commit| {
            switch (commit.operation) {
                .create => |record| {
                    // record is already typed based on collection
                    if (commit.collection == .feed_post) {
                        const post: atproto.feed.Post = record;
                        std.debug.print("new post: {s}\n", .{post.text});
                    }
                },
                .delete => { ... },
            }
        },
        .identity => |identity| { ... },
        .account => |account| { ... },
    }
}
```

bonus points:
- automatic reconnection with configurable backoff
- cursor support for resuming from a position
- filtering (dids, collections) built-in
- automatic decompression if using zstd streams

---

## 6. record operations

CRUD for records is manual json construction.

### current

```zig
var body_buf: std.ArrayList(u8) = .{};
try body_buf.print(allocator,
    \\{{"repo":"{s}","collection":"app.bsky.feed.post","record":{{...}}}}
, .{ did, ... });

const result = client.fetch(.{
    .location = .{ .url = "https://bsky.social/xrpc/com.atproto.repo.createRecord" },
    .method = .POST,
    .headers = .{ .content_type = .{ .override = "application/json" }, ... },
    .payload = body_buf.items,
    ...
});
```

### what we want

```zig
// create
const result = try agent.createRecord("app.bsky.feed.post", .{
    .text = "hello world",
    .createdAt = atproto.Datetime.now(),
});
// result.uri, result.cid are typed

// read
const record = try agent.getRecord(atproto.feed.Post, uri);

// delete
try agent.deleteRecord(uri);

// list
var iter = agent.listRecords("app.bsky.feed.post", .{ .limit = 50 });
while (try iter.next()) |record| { ... }
```

---

## 7. rich text / facets

we avoided facets entirely because they're complex. an sdk should make them easy.

### what we want

```zig
const rt = atproto.RichText.init(allocator);
try rt.append("check out ");
try rt.appendLink("this repo", "https://github.com/...");
try rt.append(" by ");
try rt.appendMention("@someone.bsky.social");
try rt.append(" ");
try rt.appendTag("zig");

const post = atproto.feed.Post{
    .text = rt.text(),
    .facets = rt.facets(),
};
```

the sdk should:
- handle unicode byte offsets correctly (this is notoriously tricky)
- auto-detect links/mentions/tags in plain text
- validate handles resolve to real DIDs

---

## 8. rate limiting and retries

we have no rate limiting. when we hit limits, we just fail.

### what we want

```zig
var agent = atproto.Agent.init(allocator, .{
    .rate_limit = .{
        .strategy = .wait, // or .error
        .max_retries = 3,
    },
});

// agent automatically:
// - respects rate limit headers
// - waits and retries on 429
// - exponential backoff on transient errors
```

---

## 9. pagination helpers

listing records or searching requires manual cursor handling.

```zig
// current: manual
var cursor: ?[]const u8 = null;
while (true) {
    const response = try fetch(cursor);
    for (response.records) |record| { ... }
    cursor = response.cursor orelse break;
}

// wanted: iterator
var iter = agent.listRecords("app.bsky.feed.post", .{});
while (try iter.next()) |record| {
    // handles pagination transparently
}

// or collect all
const all_records = try iter.collect(); // fetches all pages
```

---

## 10. did resolution

we manually hit plc.directory to resolve DIDs.

```zig
// current
var url_buf: [256]u8 = undefined;
const url = std.fmt.bufPrint(&url_buf, "https://plc.directory/{s}", .{did});
// fetch, parse, find service endpoint...

// wanted
const doc = try atproto.resolveDid(did);
// doc.pds - the PDS endpoint
// doc.handle - verified handle
// doc.signingKey, doc.rotationKeys, etc.
```

should support:
- did:plc via plc.directory
- did:web via .well-known
- caching with TTL

---

## 11. build.zig integration

### lexicon codegen

```zig
// build.zig
const atproto = @import("atproto");

pub fn build(b: *std.Build) void {
    // generate zig types from lexicon schemas
    const lexicons = atproto.addLexiconCodegen(b, .{
        .lexicon_dirs = &.{"lexicons/"},
        // or fetch from network
        .fetch_lexicons = &.{
            "app.bsky.feed.*",
            "app.bsky.actor.*",
            "com.atproto.repo.*",
        },
    });

    exe.root_module.addImport("lexicons", lexicons);
}
```

### bundled CA certs

TLS in zig requires CA certs. would be nice if the sdk bundled mozilla's CA bundle or made it easy to configure.

---

## 12. testing utilities

### mocks

```zig
const atproto = @import("atproto");

test "bot responds to matching posts" {
    var mock = atproto.testing.MockAgent.init(allocator);
    defer mock.deinit();

    // set up expected calls
    mock.expectCreateRecord("app.bsky.feed.post", .{
        .text = "",
        // ...
    });

    // run test code
    try handlePost(&mock, test_post);

    // verify
    try mock.verify();
}
```

### jetstream replay

```zig
// replay recorded jetstream events for testing
var replay = atproto.testing.JetstreamReplay.init("testdata/events.jsonl");
while (try replay.next()) |event| {
    try handleEvent(event);
}
```

---

## 13. logging / observability

### structured logging

```zig
var agent = atproto.Agent.init(allocator, .{
    .logger = myLogger, // compatible with std.log or custom
});

// logs requests, responses, retries, rate limits
```

### metrics

```zig
var agent = atproto.Agent.init(allocator, .{
    .metrics = .{
        .requests_total = &my_counter,
        .request_duration = &my_histogram,
        .rate_limit_waits = &my_counter,
    },
});
```

---

## 14. error handling

### typed errors with context

```zig
// current: generic errors
error.PostFailed

// wanted: rich errors
atproto.Error.RateLimit => |e| {
    std.debug.print("rate limited, reset at {}\n", .{e.reset_at});
},
atproto.Error.InvalidRecord => |e| {
    std.debug.print("validation failed: {s}\n", .{e.message});
},
atproto.Error.ExpiredToken => {
    // sdk should handle this automatically, but if not...
},
```

---

## 15. moderation / labels

we didn't need this for bufo-bot, but a complete sdk should support:

```zig
// applying labels
try agent.createLabels(.{
    .src = agent.did,
    .uri = post_uri,
    .val = "spam",
});

// reading labels on content
const labels = try agent.getLabels(uri);
for (labels) |label| {
    if (mem.eql(u8, label.val, "nsfw")) {
        // handle...
    }
}
```

---

## 16. feed generators and custom feeds

```zig
// serving a feed generator
var server = atproto.FeedGenerator.init(allocator, .{
    .did = my_feed_did,
    .hostname = "feed.example.com",
});

server.addFeed("trending-bufos", struct {
    fn getFeed(ctx: *Context, params: GetFeedParams) !GetFeedResponse {
        // return skeleton
    }
}.getFeed);

try server.listen(8080);
```

---

## summary

the core theme: **let us write application logic, not protocol plumbing**.

right now building an atproto app in zig means:
- manual json construction/parsing everywhere
- hand-rolling authentication flows
- string interpolation for record creation
- manual http request management
- third-party websocket libraries for firehose
- no compile-time safety for lexicon types

a good sdk would give us:
- typed lexicon schemas (codegen)
- managed sessions with automatic refresh
- high-level record CRUD
- built-in jetstream client with typed events
- utilities for rich text, AT-URIs, DIDs
- rate limiting and retry logic
- testing helpers

the dream is writing a bot like bufo-bot in ~100 lines instead of ~1000.
