const std = @import("std");
const mem = std.mem;
const json = std.json;
const http = std.http;
const Allocator = mem.Allocator;
const Io = std.Io;

// module state — initialized via init(), not from a global
var io: Io = undefined;

pub fn init(app_io: Io) void {
    io = app_io;
}

fn timestamp() i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

pub const BskyClient = struct {
    allocator: Allocator,
    handle: []const u8,
    app_password: []const u8,
    access_jwt: ?[]const u8 = null,
    did: ?[]const u8 = null,
    pds_host: ?[]const u8 = null,

    pub fn initClient(allocator: Allocator, handle: []const u8, app_password: []const u8) BskyClient {
        return .{
            .allocator = allocator,
            .handle = handle,
            .app_password = app_password,
        };
    }

    pub fn deinit(self: *BskyClient) void {
        if (self.access_jwt) |jwt| self.allocator.free(jwt);
        if (self.did) |did| self.allocator.free(did);
        if (self.pds_host) |host| self.allocator.free(host);
    }

    fn httpClient(self: *BskyClient) http.Client {
        return .{ .allocator = self.allocator, .io = io };
    }

    pub fn login(self: *BskyClient) !void {
        std.debug.print("logging in as {s}...\n", .{self.handle});

        var client = self.httpClient();
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.allocator);
        try body_buf.print(self.allocator, "{{\"identifier\":\"{s}\",\"password\":\"{s}\"}}", .{ self.handle, self.app_password });

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = "https://bsky.social/xrpc/com.atproto.server.createSession" },
            .method = .POST,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .payload = body_buf.items,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("login request failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            std.debug.print("login failed with status: {}\n", .{result.status});
            return error.LoginFailed;
        }

        const response = aw.toArrayList();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const root = parsed.value.object;

        const jwt_val = root.get("accessJwt") orelse return error.NoJwt;
        if (jwt_val != .string) return error.NoJwt;

        const did_val = root.get("did") orelse return error.NoDid;
        if (did_val != .string) return error.NoDid;

        self.access_jwt = try self.allocator.dupe(u8, jwt_val.string);
        self.did = try self.allocator.dupe(u8, did_val.string);

        // fetch PDS host from PLC directory
        try self.fetchPdsHost();

        std.debug.print("logged in as {s} (did: {s}, pds: {s})\n", .{ self.handle, self.did.?, self.pds_host.? });
    }

    fn fetchPdsHost(self: *BskyClient) !void {
        var client = self.httpClient();
        defer client.deinit();

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://plc.directory/{s}", .{self.did.?}) catch return error.UrlTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("fetch PDS host failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            std.debug.print("fetch PDS host failed with status: {}\n", .{result.status});
            return error.PlcLookupFailed;
        }

        const response = aw.toArrayList();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        // find the atproto_pds service endpoint
        const service = parsed.value.object.get("service") orelse return error.NoService;
        if (service != .array) return error.NoService;

        for (service.array.items) |svc| {
            if (svc != .object) continue;
            const id_val = svc.object.get("id") orelse continue;
            if (id_val != .string) continue;
            if (!mem.eql(u8, id_val.string, "#atproto_pds")) continue;

            const endpoint_val = svc.object.get("serviceEndpoint") orelse continue;
            if (endpoint_val != .string) continue;

            // extract host from URL like "https://phellinus.us-west.host.bsky.network"
            const endpoint = endpoint_val.string;
            const prefix = "https://";
            if (mem.startsWith(u8, endpoint, prefix)) {
                self.pds_host = try self.allocator.dupe(u8, endpoint[prefix.len..]);
                return;
            }
        }

        return error.NoPdsService;
    }

    pub fn uploadBlob(self: *BskyClient, data: []const u8, content_type: []const u8) ![]const u8 {
        if (self.access_jwt == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.access_jwt.?}) catch return error.AuthTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = "https://bsky.social/xrpc/com.atproto.repo.uploadBlob" },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = content_type },
                .authorization = .{ .override = auth_header },
            },
            .payload = data,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("upload blob failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            const err_response = aw.toArrayList();
            std.debug.print("upload blob failed with status: {} - {s}\n", .{ result.status, err_response.items });
            // check for expired token
            if (mem.indexOf(u8, err_response.items, "ExpiredToken") != null) {
                return error.ExpiredToken;
            }
            return error.UploadFailed;
        }

        const response = aw.toArrayList();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const root = parsed.value.object;
        const blob = root.get("blob") orelse return error.NoBlobRef;
        if (blob != .object) return error.NoBlobRef;

        return json.Stringify.valueAlloc(self.allocator, blob, .{}) catch return error.SerializeError;
    }

    pub fn isBlockedBy(self: *BskyClient, target_did: []const u8) !bool {
        var client = self.httpClient();
        defer client.deinit();

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://public.api.bsky.app/xrpc/app.bsky.graph.getRelationships?actor={s}&others={s}", .{ self.did.?, target_did }) catch return error.UrlTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("block check failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            std.debug.print("block check failed with status: {}\n", .{result.status});
            return error.BlockCheckFailed;
        }

        const response = aw.toArrayList();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const relationships = parsed.value.object.get("relationships") orelse return false;
        if (relationships != .array) return false;
        if (relationships.array.items.len == 0) return false;

        const rel = relationships.array.items[0];
        if (rel != .object) return false;

        const blocked_by = rel.object.get("blockedBy") orelse return false;
        if (blocked_by == .string) {
            // presence of blockedBy with an AT-URI means we are blocked
            return true;
        }

        return false;
    }

    pub fn createQuotePost(self: *BskyClient, quote_uri: []const u8, quote_cid: []const u8, blob_json: []const u8, alt_text: []const u8) ![]const u8 {
        if (self.access_jwt == null or self.did == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        var ts_buf: [30]u8 = undefined;
        try body_buf.print(self.allocator,
            \\{{"repo":"{s}","collection":"app.bsky.feed.post","record":{{"$type":"app.bsky.feed.post","text":"","createdAt":"{s}","embed":{{"$type":"app.bsky.embed.recordWithMedia","record":{{"$type":"app.bsky.embed.record","record":{{"uri":"{s}","cid":"{s}"}}}},"media":{{"$type":"app.bsky.embed.images","images":[{{"image":{s},"alt":"{s}"}}]}}}}}}}}
        , .{ self.did.?, getIsoTimestamp(&ts_buf), quote_uri, quote_cid, blob_json, alt_text });

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.access_jwt.?}) catch return error.AuthTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = "https://bsky.social/xrpc/com.atproto.repo.createRecord" },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .payload = body_buf.items,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("create post failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            const response = aw.toArrayList();
            std.debug.print("create post failed with status: {} - {s}\n", .{ result.status, response.items });
            return error.PostFailed;
        }

        std.debug.print("posted successfully!\n", .{});
        return self.parseRkeyFromResponse(aw.toArrayList().items);
    }

    pub fn getPostCid(self: *BskyClient, uri: []const u8) ![]const u8 {
        if (self.access_jwt == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var parts = mem.splitScalar(u8, uri[5..], '/');
        const did = parts.next() orelse return error.InvalidUri;
        _ = parts.next();
        const rkey = parts.next() orelse return error.InvalidUri;

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://bsky.social/xrpc/com.atproto.repo.getRecord?repo={s}&collection=app.bsky.feed.post&rkey={s}", .{ did, rkey }) catch return error.UrlTooLong;

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.access_jwt.?}) catch return error.AuthTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .authorization = .{ .override = auth_header } },
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("get record failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            return error.GetRecordFailed;
        }

        const response = aw.toArrayList();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const cid_val = parsed.value.object.get("cid") orelse return error.NoCid;
        if (cid_val != .string) return error.NoCid;

        return try self.allocator.dupe(u8, cid_val.string);
    }

    pub fn fetchImage(self: *BskyClient, url: []const u8) ![]const u8 {
        var client = self.httpClient();
        defer client.deinit();

        var aw: Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("fetch image failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            aw.deinit();
            return error.FetchFailed;
        }

        return try aw.toOwnedSlice();
    }

    pub fn getServiceAuth(self: *BskyClient) ![]const u8 {
        if (self.access_jwt == null or self.did == null or self.pds_host == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://bsky.social/xrpc/com.atproto.server.getServiceAuth?aud=did:web:{s}&lxm=com.atproto.repo.uploadBlob", .{self.pds_host.?}) catch return error.UrlTooLong;

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.access_jwt.?}) catch return error.AuthTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .authorization = .{ .override = auth_header } },
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("get service auth failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            const err_response = aw.toArrayList();
            std.debug.print("get service auth failed with status: {} - {s}\n", .{ result.status, err_response.items });
            // check for expired token
            if (mem.indexOf(u8, err_response.items, "ExpiredToken") != null) {
                return error.ExpiredToken;
            }
            return error.ServiceAuthFailed;
        }

        const response = aw.toArrayList();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const token_val = parsed.value.object.get("token") orelse return error.NoToken;
        if (token_val != .string) return error.NoToken;

        return try self.allocator.dupe(u8, token_val.string);
    }

    pub fn uploadVideo(self: *BskyClient, data: []const u8, filename: []const u8) ![]const u8 {
        if (self.did == null) return error.NotLoggedIn;

        // get service auth token
        const service_token = try self.getServiceAuth();
        defer self.allocator.free(service_token);

        var client = self.httpClient();
        defer client.deinit();

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://video.bsky.app/xrpc/app.bsky.video.uploadVideo?did={s}&name={s}", .{ self.did.?, filename }) catch return error.UrlTooLong;

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{service_token}) catch return error.AuthTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "image/gif" },
                .authorization = .{ .override = auth_header },
            },
            .payload = data,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("upload video failed: {}\n", .{err});
            return err;
        };

        const response = aw.toArrayList();

        // handle both .ok and .conflict (already_exists) as success
        if (result.status != .ok and result.status != .conflict) {
            std.debug.print("upload video failed with status: {}\n", .{result.status});
            return error.VideoUploadFailed;
        }

        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        // for conflict responses, jobId is at root level; for ok responses, it's in jobStatus
        var job_id_val: ?json.Value = null;
        if (parsed.value.object.get("jobStatus")) |job_status| {
            if (job_status == .object) {
                job_id_val = job_status.object.get("jobId");
            }
        }
        // fallback to root level jobId (conflict case)
        if (job_id_val == null) {
            job_id_val = parsed.value.object.get("jobId");
        }

        const job_id = job_id_val orelse {
            std.debug.print("no jobId in response\n", .{});
            return error.NoJobId;
        };
        if (job_id != .string) return error.NoJobId;

        return try self.allocator.dupe(u8, job_id.string);
    }

    pub fn waitForVideo(self: *BskyClient, job_id: []const u8) ![]const u8 {
        const service_token = try self.getServiceAuth();
        defer self.allocator.free(service_token);

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://video.bsky.app/xrpc/app.bsky.video.getJobStatus?jobId={s}", .{job_id}) catch return error.UrlTooLong;

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{service_token}) catch return error.AuthTooLong;

        var attempts: u32 = 0;
        while (attempts < 60) : (attempts += 1) {
            var client = self.httpClient();
            defer client.deinit();

            var aw: Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();

            const result = client.fetch(.{
                .location = .{ .url = url },
                .method = .GET,
                .headers = .{ .authorization = .{ .override = auth_header } },
                .response_writer = &aw.writer,
            }) catch |err| {
                std.debug.print("get job status failed: {}\n", .{err});
                return err;
            };

            if (result.status != .ok) {
                std.debug.print("get job status failed with status: {}\n", .{result.status});
                return error.JobStatusFailed;
            }

            const response = aw.toArrayList();
            const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
            defer parsed.deinit();

            const job_status = parsed.value.object.get("jobStatus") orelse return error.NoJobStatus;
            if (job_status != .object) return error.NoJobStatus;

            const state_val = job_status.object.get("state") orelse continue;
            if (state_val != .string) continue;

            if (mem.eql(u8, state_val.string, "JOB_STATE_COMPLETED")) {
                const blob = job_status.object.get("blob") orelse return error.NoBlobRef;
                if (blob != .object) return error.NoBlobRef;
                return json.Stringify.valueAlloc(self.allocator, blob, .{}) catch return error.SerializeError;
            } else if (mem.eql(u8, state_val.string, "JOB_STATE_FAILED")) {
                std.debug.print("video processing failed\n", .{});
                return error.VideoProcessingFailed;
            }

            io.sleep(.{ .nanoseconds = 1 * std.time.ns_per_s }, .awake) catch {};
        }

        return error.VideoTimeout;
    }

    pub fn createVideoQuotePost(self: *BskyClient, quote_uri: []const u8, quote_cid: []const u8, blob_json: []const u8, alt_text: []const u8) ![]const u8 {
        if (self.access_jwt == null or self.did == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        var ts_buf: [30]u8 = undefined;
        try body_buf.print(self.allocator,
            \\{{"repo":"{s}","collection":"app.bsky.feed.post","record":{{"$type":"app.bsky.feed.post","text":"","createdAt":"{s}","embed":{{"$type":"app.bsky.embed.recordWithMedia","record":{{"$type":"app.bsky.embed.record","record":{{"uri":"{s}","cid":"{s}"}}}},"media":{{"$type":"app.bsky.embed.video","video":{s},"alt":"{s}"}}}}}}}}
        , .{ self.did.?, getIsoTimestamp(&ts_buf), quote_uri, quote_cid, blob_json, alt_text });

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.access_jwt.?}) catch return error.AuthTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = "https://bsky.social/xrpc/com.atproto.repo.createRecord" },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .payload = body_buf.items,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("create video post failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            const response = aw.toArrayList();
            std.debug.print("create video post failed with status: {} - {s}\n", .{ result.status, response.items });
            return error.PostFailed;
        }

        std.debug.print("posted video successfully!\n", .{});
        return self.parseRkeyFromResponse(aw.toArrayList().items);
    }

    pub fn deleteRecord(self: *BskyClient, rkey: []const u8) !void {
        if (self.access_jwt == null or self.did == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        try body_buf.print(self.allocator,
            \\{{"repo":"{s}","collection":"app.bsky.feed.post","rkey":"{s}"}}
        , .{ self.did.?, rkey });

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.access_jwt.?}) catch return error.AuthTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = "https://bsky.social/xrpc/com.atproto.repo.deleteRecord" },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .payload = body_buf.items,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("delete record failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            const response = aw.toArrayList();
            std.debug.print("delete record failed with status: {} - {s}\n", .{ result.status, response.items });
            return error.DeleteFailed;
        }

        std.debug.print("deleted record {s}\n", .{rkey});
    }

    pub const FeedPost = struct {
        rkey: []const u8,
        original_uri: []const u8,
        original_did: []const u8,
        is_stale: bool, // viewNotFound or viewDetached
    };

    /// fetch our own feed and return quote-posts with their embed status.
    /// caller must free each entry's duped strings and the returned slice.
    pub fn getAuthorFeed(self: *BskyClient, buf: []FeedPost) ![]FeedPost {
        if (self.did == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?actor={s}&limit=100&filter=posts_no_replies", .{self.did.?}) catch return error.UrlTooLong;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("getAuthorFeed failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            std.debug.print("getAuthorFeed failed with status: {}\n", .{result.status});
            return error.FeedFetchFailed;
        }

        const response = aw.toArrayList();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const feed = parsed.value.object.get("feed") orelse return buf[0..0];
        if (feed != .array) return buf[0..0];

        var count: usize = 0;
        for (feed.array.items) |item| {
            if (count >= buf.len) break;
            if (item != .object) continue;

            const post_obj = item.object.get("post") orelse continue;
            if (post_obj != .object) continue;

            // get our post's URI to extract rkey
            const post_uri_val = post_obj.object.get("uri") orelse continue;
            if (post_uri_val != .string) continue;

            // check if it has an embed with a record (quote-post)
            const embed = post_obj.object.get("embed") orelse continue;
            if (embed != .object) continue;

            // look for record in embed (recordWithMedia or record embed)
            const record_obj = if (embed.object.get("record")) |r| r else continue;
            if (record_obj != .object) continue;

            // the embedded record view — check its $type
            // for recordWithMedia, the record contains a "record" with the actual view
            const inner_record = if (record_obj.object.get("record")) |r| r else record_obj;
            if (inner_record != .object) continue;

            const type_val = inner_record.object.get("$type") orelse continue;
            if (type_val != .string) continue;

            const is_stale = mem.eql(u8, type_val.string, "app.bsky.embed.record#viewNotFound") or
                mem.eql(u8, type_val.string, "app.bsky.embed.record#viewDetached") or
                mem.eql(u8, type_val.string, "app.bsky.embed.record#viewBlocked");

            // extract the original post's URI from the inner record
            const orig_uri_val = inner_record.object.get("uri") orelse continue;
            if (orig_uri_val != .string) continue;

            // parse our rkey from our post URI
            var our_parts = mem.splitScalar(u8, post_uri_val.string[5..], '/');
            _ = our_parts.next(); // did
            _ = our_parts.next(); // collection
            const our_rkey = our_parts.next() orelse continue;

            // parse original DID from original URI
            var orig_parts = mem.splitScalar(u8, orig_uri_val.string[5..], '/');
            const orig_did = orig_parts.next() orelse continue;

            buf[count] = .{
                .rkey = self.allocator.dupe(u8, our_rkey) catch continue,
                .original_uri = self.allocator.dupe(u8, orig_uri_val.string) catch {
                    self.allocator.free(buf[count].rkey);
                    continue;
                },
                .original_did = self.allocator.dupe(u8, orig_did) catch {
                    self.allocator.free(buf[count].rkey);
                    self.allocator.free(buf[count].original_uri);
                    continue;
                },
                .is_stale = is_stale,
            };
            count += 1;
        }

        return buf[0..count];
    }

    fn parseRkeyFromResponse(self: *BskyClient, response: []const u8) ![]const u8 {
        const parsed = json.parseFromSlice(json.Value, self.allocator, response, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const uri_val = parsed.value.object.get("uri") orelse return error.NoUri;
        if (uri_val != .string) return error.NoUri;

        // parse rkey from at://did/collection/rkey
        var parts = mem.splitScalar(u8, uri_val.string[5..], '/');
        _ = parts.next(); // did
        _ = parts.next(); // collection
        const rkey = parts.next() orelse return error.InvalidUri;

        return try self.allocator.dupe(u8, rkey);
    }
};

fn getIsoTimestamp(buf: *[30]u8) []const u8 {
    const ts = timestamp();
    const epoch_secs: u64 = @intCast(ts);
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();

    const len = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch return "2025-01-01T00:00:00.000Z";
    return buf[0..len.len];
}
