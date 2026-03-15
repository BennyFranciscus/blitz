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

fn hello(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.text("Hello, World!");
}

fn greet(req: *blitz.Request, res: *blitz.Response) void {
    const name = req.params.get("name") orelse "stranger";
    _ = res.text(name);
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

pub fn main() !void {
    var router = blitz.Router.init(std.heap.c_allocator);

    // Global middleware
    router.use(timing);
    router.use(cors);

    // Top-level routes
    router.get("/", hello);
    router.get("/hello/:name", greet);

    // API route group
    const api = router.group("/api/v1");
    api.get("/health", health);
    api.get("/users", listUsers);
    api.get("/users/:id", getUser);
    api.post("/users", createUser);

    // JSON 404 handler
    router.notFound(blitz.jsonNotFoundHandler);

    var server = blitz.Server.init(&router, .{ .port = 8080 });
    try server.listen();
}
