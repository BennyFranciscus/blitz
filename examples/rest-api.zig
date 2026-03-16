const std = @import("std");
const blitz = @import("blitz");

// ── Application State ───────────────────────────────────────────────
// Application state is injected via req.context(AppState) in handlers.
// Set once via Server config, shared across all threads (read-only or thread-safe).

const AppState = struct {
    name: []const u8,
    version: []const u8,
    rate_limiter: *blitz.RateLimiter,
};

var rate_limiter: blitz.RateLimiter = undefined;

// ── Middleware ──────────────────────────────────────────────────────

/// Security headers — good defaults for APIs
fn securityHeaders(_: *blitz.Request, res: *blitz.Response) bool {
    res.headers.set("X-Content-Type-Options", "nosniff");
    res.headers.set("X-Frame-Options", "DENY");
    return true;
}

/// Auth middleware — checks Bearer token
fn requireAuth(req: *blitz.Request, res: *blitz.Response) bool {
    const auth_header = req.headers.get("Authorization") orelse {
        blitz.unauthorized(res, "Bearer token required");
        return false;
    };

    const prefix = "Bearer ";
    if (auth_header.len < prefix.len or
        !std.mem.eql(u8, auth_header[0..prefix.len], prefix))
    {
        blitz.unauthorized(res, "Invalid authorization format");
        return false;
    }

    // In a real app: validate JWT, look up session, etc.
    const token = auth_header[prefix.len..];
    if (token.len == 0) {
        blitz.unauthorized(res, "Empty token");
        return false;
    }

    return true;
}

// ── Public Handlers ────────────────────────────────────────────────

fn healthCheck(req: *blitz.Request, res: *blitz.Response) void {
    const app = req.context(AppState);
    var buf: [128]u8 = undefined;
    const body = blitz.Json.stringify(&buf, .{
        .status = "healthy",
        .version = app.version,
    }) orelse "{\"status\":\"healthy\"}";
    _ = res.json(body);
}

fn listPosts(_: *blitz.Request, res: *blitz.Response) void {
    // In a real app: query database with pagination
    var buf: [2048]u8 = undefined;
    var arr = blitz.JsonArray.init(&buf);

    var p1: [256]u8 = undefined;
    arr.pushRaw(blitz.Json.stringify(&p1, .{
        .id = @as(i64, 1),
        .title = "Getting Started with Blitz",
        .author = "Alice",
        .published = true,
    }) orelse "{}");

    var p2: [256]u8 = undefined;
    arr.pushRaw(blitz.Json.stringify(&p2, .{
        .id = @as(i64, 2),
        .title = "Building Fast APIs in Zig",
        .author = "Bob",
        .published = false,
    }) orelse "{}");

    const body = arr.finish() orelse "[]";
    _ = res.json(body);
}

fn getPost(req: *blitz.Request, res: *blitz.Response) void {
    const id_str = req.params.get("id") orelse {
        blitz.badRequest(res, "Missing post ID");
        return;
    };

    // Parse and validate the ID
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        blitz.badRequest(res, "Invalid post ID");
        return;
    };

    // In a real app: query database
    if (id > 2 or id < 1) {
        blitz.notFound(res, "Post not found");
        return;
    }

    var buf: [512]u8 = undefined;
    var obj = blitz.JsonObject.init(&buf);
    obj.field("id", id);
    obj.field("title", "Getting Started with Blitz");
    obj.field("author", "Alice");
    obj.field("content", "Blitz is a blazing-fast HTTP framework for Zig...");
    obj.field("published", true);
    const body = obj.finish() orelse "{}";
    _ = res.json(body);
}

fn searchPosts(req: *blitz.Request, res: *blitz.Response) void {
    const q = req.queryParsed();
    const term = q.get("q") orelse {
        blitz.badRequest(res, "Missing search query (?q=...)");
        return;
    };
    const page = q.getInt("page", i64) orelse 1;
    const per_page = q.getInt("per_page", i64) orelse 20;

    var buf: [512]u8 = undefined;
    const body = blitz.Json.stringify(&buf, .{
        .query = term,
        .page = page,
        .per_page = per_page,
        .total = @as(i64, 42),
        .results = @as(i64, 0), // would be populated from DB
    }) orelse "{}";
    _ = res.json(body);
}

// ── Protected Handlers (require auth) ──────────────────────────────

// Request body types for JSON parsing
const CreatePostBody = struct {
    title: []const u8,
    content: []const u8 = "",
    published: bool = false,
};

const UpdatePostBody = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
    published: ?bool = null,
};

fn createPost(req: *blitz.Request, res: *blitz.Response) void {
    // Rate limit write operations more aggressively
    const ip = blitz.clientIp(req);
    if (rate_limiter.check(ip) == null) {
        blitz.sendError(res, .too_many_requests, "Rate limit exceeded");
        return;
    }

    // Parse JSON body into typed struct
    const post = req.jsonParse(CreatePostBody) orelse {
        blitz.badRequest(res, "Invalid JSON body — requires 'title' field");
        return;
    };

    // In a real app: validate and insert into DB
    var buf: [512]u8 = undefined;
    const body = blitz.Json.stringify(&buf, .{
        .id = @as(i64, 3),
        .title = post.title,
        .published = post.published,
        .created = true,
    }) orelse "{\"id\":3,\"created\":true}";
    _ = res.setStatus(.created).json(body);
}

fn updatePost(req: *blitz.Request, res: *blitz.Response) void {
    const id_str = req.params.get("id") orelse {
        blitz.badRequest(res, "Missing post ID");
        return;
    };
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        blitz.badRequest(res, "Invalid post ID");
        return;
    };

    // Parse JSON body with optional fields (partial update)
    const update = req.jsonParse(UpdatePostBody) orelse {
        blitz.badRequest(res, "Invalid JSON body");
        return;
    };

    // In a real app: apply non-null fields to DB record
    var buf: [512]u8 = undefined;
    const body = blitz.Json.stringify(&buf, .{
        .id = id,
        .title_updated = update.title != null,
        .content_updated = update.content != null,
        .published_updated = update.published != null,
        .updated = true,
    }) orelse "{\"updated\":true}";
    _ = res.json(body);
}

fn deletePost(req: *blitz.Request, res: *blitz.Response) void {
    const id_str = req.params.get("id") orelse {
        blitz.badRequest(res, "Missing post ID");
        return;
    };
    _ = std.fmt.parseInt(i64, id_str, 10) catch {
        blitz.badRequest(res, "Invalid post ID");
        return;
    };

    // In a real app: soft-delete or remove from DB
    _ = res.setStatus(.no_content).text("");
}

// ── Auth Handlers ──────────────────────────────────────────────────

fn login(req: *blitz.Request, res: *blitz.Response) void {
    if (req.body == null) {
        blitz.badRequest(res, "Credentials required");
        return;
    }

    // In a real app: validate credentials, generate JWT
    var cookie_buf: [256]u8 = undefined;
    _ = res.setCookie(&cookie_buf, "session", "tok_example", .{
        .max_age = 86400,
        .path = "/",
        .http_only = true,
        .secure = true,
        .same_site = .strict,
    });

    _ = res.json("{\"token\":\"example-jwt-token\",\"expires_in\":86400}");
}

fn logout(_: *blitz.Request, res: *blitz.Response) void {
    var cookie_buf: [256]u8 = undefined;
    _ = res.deleteCookie(&cookie_buf, "session", .{ .path = "/" });
    _ = res.json("{\"logged_out\":true}");
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    // Initialize rate limiter (100 requests per 60 seconds per IP)
    rate_limiter = try blitz.RateLimiter.init(alloc, .{
        .max_requests = 100,
        .window_secs = 60,
    });

    var router = blitz.Router.init(alloc);

    // Global middleware (runs on every request)
    router.use(blitz.Cors.middleware(.{
        .origins = &.{ "https://myapp.com", "http://localhost:3000" },
        .allow_credentials = true,
        .max_age = 3600,
        .max_age_str = "3600",
    }));
    router.use(securityHeaders);

    // Public routes
    router.get("/health", healthCheck);
    router.get("/posts", listPosts);
    router.get("/posts/:id", getPost);
    router.get("/search", searchPosts);

    // Auth routes
    router.post("/login", login);
    router.post("/logout", logout);

    // Protected API routes
    const api = router.group("/api/v1");
    api.use(requireAuth);
    api.post("/posts", createPost);
    api.put("/posts/:id", updatePost);
    api.delete("/posts/:id", deletePost);

    // Serve frontend static files
    router.staticDir("/", "./public", .{
        .cache_control = "public, max-age=3600",
    });

    // JSON 404 handler
    router.notFound(blitz.jsonNotFoundHandler);

    var app_state = AppState{
        .name = "blitz-rest-api",
        .version = "1.0.0",
        .rate_limiter = &rate_limiter,
    };

    var server = blitz.Server.init(&router, .{
        .port = 8080,
        .compression = true,
        .context = @ptrCast(&app_state),
        .logging = .{
            .enabled = true,
            .format = .text,
            .min_level = .info,
            .slow_threshold_ms = 1000,
        },
    });

    std.debug.print(
        \\
        \\  ⚡ Blitz REST API running on http://localhost:8080
        \\
        \\  Public endpoints:
        \\    GET  /health       — Health check
        \\    GET  /posts        — List posts
        \\    GET  /posts/:id    — Get post by ID
        \\    GET  /search?q=... — Search posts
        \\    POST /login        — Login
        \\    POST /logout       — Logout
        \\
        \\  Protected endpoints (require Bearer token):
        \\    POST   /api/v1/posts      — Create post
        \\    PUT    /api/v1/posts/:id  — Update post
        \\    DELETE /api/v1/posts/:id  — Delete post
        \\
        \\
    , .{});

    try server.listen();
}
