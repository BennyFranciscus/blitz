const std = @import("std");
const blitz = @import("../src/blitz.zig");

// ── Handlers ────────────────────────────────────────────────────────

fn index(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.text("Welcome to blitz ⚡");
}

fn hello(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.json("{\"message\":\"Hello, World!\"}");
}

fn greet(req: *blitz.Request, res: *blitz.Response) void {
    const name = req.params.get("name") orelse "stranger";
    _ = res.text(name);
}

fn health(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.json("{\"status\":\"ok\"}");
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main() !void {
    var router = blitz.Router.init(std.heap.c_allocator);

    router.get("/", index);
    router.get("/hello", hello);
    router.get("/hello/:name", greet);
    router.get("/health", health);

    var server = blitz.Server.init(&router, .{ .port = 3000 });
    try server.listen();
}
