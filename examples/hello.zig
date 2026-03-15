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
    _ = res.json("{\"status\":\"ok\"}");
}

fn listUsers(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.json("[{\"id\":1,\"name\":\"alice\"},{\"id\":2,\"name\":\"bob\"}]");
}

fn getUser(req: *blitz.Request, res: *blitz.Response) void {
    const id = req.params.get("id") orelse "?";
    // In a real app you'd look up the user
    _ = res.json(id);
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

    // Custom 404
    router.notFound(struct {
        fn f(_: *blitz.Request, res: *blitz.Response) void {
            _ = res.setStatus(.not_found).json("{\"error\":\"not found\"}");
        }
    }.f);

    var server = blitz.Server.init(&router, .{ .port = 8080 });
    try server.listen();
}
