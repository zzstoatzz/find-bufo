const std = @import("std");
const mem = std.mem;
const json = std.json;
const http = std.http;
const Allocator = mem.Allocator;
const Io = std.Io;

pub const BskyClient = struct {
    allocator: Allocator,
    handle: []const u8,
    app_password: []const u8,
    access_jwt: ?[]const u8 = null,
    did: ?[]const u8 = null,
    pds_host: ?[]const u8 = null,

    pub fn init(allocator: Allocator, handle: []const u8, app_password: []const u8) BskyClient {
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
        return .{ .allocator = self.allocator };
    }

    pub fn login(self: *BskyClient) !void {
        std.debug.print("logging in as {s}...\n", .{self.handle});

        var client = self.httpClient();
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .{};
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

    pub fn createQuotePost(self: *BskyClient, quote_uri: []const u8, quote_cid: []const u8, blob_json: []const u8, alt_text: []const u8) !void {
        if (self.access_jwt == null or self.did == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .{};
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
                .content_type = .{ .override = "video/mp4" },
                .authorization = .{ .override = auth_header },
            },
            .payload = data,
            .response_writer = &aw.writer,
        }) catch |err| {
            std.debug.print("upload video failed: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            const err_response = aw.toArrayList();
            std.debug.print("upload video failed with status: {} - {s}\n", .{ result.status, err_response.items });
            return error.VideoUploadFailed;
        }

        const response = aw.toArrayList();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response.items, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const job_status = parsed.value.object.get("jobStatus") orelse return error.NoJobStatus;
        if (job_status != .object) return error.NoJobStatus;

        const job_id_val = job_status.object.get("jobId") orelse return error.NoJobId;
        if (job_id_val != .string) return error.NoJobId;

        return try self.allocator.dupe(u8, job_id_val.string);
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

            std.Thread.sleep(1 * std.time.ns_per_s);
        }

        return error.VideoTimeout;
    }

    pub fn createVideoQuotePost(self: *BskyClient, quote_uri: []const u8, quote_cid: []const u8, blob_json: []const u8, alt_text: []const u8) !void {
        if (self.access_jwt == null or self.did == null) return error.NotLoggedIn;

        var client = self.httpClient();
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .{};
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
    }
};

fn getIsoTimestamp(buf: *[30]u8) []const u8 {
    const ts = std.time.timestamp();
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
