const std = @import("std");
const blitz = @import("blitz");

// ── Middleware ───────────────────────────────────────────────────────

/// Logging middleware — adds Server-Timing header
fn timing(_: *blitz.Request, res: *blitz.Response) bool {
    res.headers.set("Server-Timing", "middleware;desc=\"timing\"");
    return true;
}

/// CORS middleware — adds permissive CORS headers
fn cors(_: *blitz.Request, res: *blitz.Response) bool {
    res.headers.set("Access-Control-Allow-Origin", "*");
    res.headers.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    return true;
}

// ── Handlers ────────────────────────────────────────────────────────

/// Auth middleware — only runs on routes that need it
fn auth(req: *blitz.Request, res: *blitz.Response) bool {
    if (req.headers.get("Authorization") == null) {
        blitz.unauthorized(res, "Token required");
        return false;
    }
    return true;
}

fn hello(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.text("Hello, World!");
}

fn greet(req: *blitz.Request, res: *blitz.Response) void {
    const name = req.params.get("name") orelse "stranger";
    _ = res.text(name);
}

fn search(req: *blitz.Request, res: *blitz.Response) void {
    // Structured query string parsing with typed access
    const q = req.queryParsed();
    const term = q.get("q") orelse "nothing";
    const page = q.getInt("page", i64) orelse 1;
    const debug = q.getBool("debug") orelse false;

    var buf: [512]u8 = undefined;
    const body = blitz.Json.stringify(&buf, .{
        .query = term,
        .page = page,
        .debug = debug,
    }) orelse "{\"error\":\"serialize failed\"}";
    _ = res.json(body);
}

fn health(_: *blitz.Request, res: *blitz.Response) void {
    // Using the JSON builder for zero-alloc JSON
    var buf: [256]u8 = undefined;
    const body = blitz.Json.stringify(&buf, .{
        .status = "ok",
        .version = "1.0.0",
    }) orelse "{\"status\":\"ok\"}";
    _ = res.json(body);
}

fn listUsers(_: *blitz.Request, res: *blitz.Response) void {
    // Manual JSON array building
    var buf: [1024]u8 = undefined;
    var arr = blitz.JsonArray.init(&buf);
    // In a real app, iterate over DB results
    var u1_buf: [128]u8 = undefined;
    arr.pushRaw(blitz.Json.stringify(&u1_buf, .{
        .id = @as(i64, 1),
        .name = "Alice",
        .active = true,
    }) orelse "{}");
    var u2_buf: [128]u8 = undefined;
    arr.pushRaw(blitz.Json.stringify(&u2_buf, .{
        .id = @as(i64, 2),
        .name = "Bob",
        .active = false,
    }) orelse "{}");
    const body = arr.finish() orelse "[]";
    _ = res.json(body);
}

fn getUser(req: *blitz.Request, res: *blitz.Response) void {
    const id = req.params.get("id") orelse {
        blitz.badRequest(res, "Missing user ID");
        return;
    };
    // In a real app: look up user, return 404 if not found
    var buf: [256]u8 = undefined;
    var obj = blitz.JsonObject.init(&buf);
    obj.field("id", id);
    obj.field("name", "Alice");
    obj.field("active", true);
    const body = obj.finish() orelse "{}";
    _ = res.json(body);
}

fn createUser(req: *blitz.Request, res: *blitz.Response) void {
    if (req.body == null or req.body.?.len == 0) {
        blitz.badRequest(res, "Request body is required");
        return;
    }
    _ = res.setStatus(.created).json("{\"id\":3,\"created\":true}");
}

fn login(_: *blitz.Request, res: *blitz.Response) void {
    // Set a session cookie with security options
    var cookie_buf: [256]u8 = undefined;
    _ = res.setCookie(&cookie_buf, "session", "tok_abc123", .{
        .max_age = 86400, // 24 hours
        .path = "/",
        .http_only = true,
        .same_site = .lax,
    });
    _ = res.json("{\"logged_in\":true}");
}

fn logout(_: *blitz.Request, res: *blitz.Response) void {
    // Delete the session cookie
    var cookie_buf: [256]u8 = undefined;
    _ = res.deleteCookie(&cookie_buf, "session", .{ .path = "/" });
    _ = res.json("{\"logged_out\":true}");
}

fn profile(req: *blitz.Request, res: *blitz.Response) void {
    // Read a cookie from the request
    const session = req.cookie("session") orelse {
        _ = res.redirectTemp("/login");
        return;
    };
    var buf: [256]u8 = undefined;
    const body = blitz.Json.stringify(&buf, .{
        .session = session,
        .message = "Welcome back!",
    }) orelse "{}";
    _ = res.json(body);
}

fn oldPage(_: *blitz.Request, res: *blitz.Response) void {
    // Permanent redirect — page has moved
    _ = res.redirectPerm("/new-page");
}

pub fn main() !void {
    var router = blitz.Router.init(std.heap.c_allocator);

    // Global middleware
    router.use(timing);
    router.use(cors);

    // Top-level routes
    router.get("/", hello);
    router.get("/hello/:name", greet);
    router.get("/search", search);

    // API route group with per-group auth middleware
    const api = router.group("/api/v1");
    api.use(auth); // Only runs for /api/v1/* routes
    api.get("/health", health);
    api.get("/users", listUsers);
    api.get("/users/:id", getUser);
    api.post("/users", createUser);

    // Static file serving — serves files from ./public at /static/*
    // Includes automatic MIME type detection, path traversal protection,
    // directory index (index.html), and optional cache control headers.
    router.staticDir("/static", "./public", .{
        .cache_control = "public, max-age=3600",
    });

    // Cookie & redirect routes
    api.post("/login", login);
    api.post("/logout", logout);
    api.get("/profile", profile);
    router.get("/old-page", oldPage);

    // JSON 404 handler
    router.notFound(blitz.jsonNotFoundHandler);

    var server = blitz.Server.init(&router, .{ .port = 8080 });
    try server.listen();
}
