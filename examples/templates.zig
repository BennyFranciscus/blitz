const std = @import("std");
const blitz = @import("blitz");

// Comptime templates — parsed once, zero overhead at runtime
const layout = blitz.Template.compile(
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <title>{{ title }} — My App</title>
    \\  <style>
    \\    body { font-family: system-ui; max-width: 800px; margin: 2em auto; padding: 0 1em; }
    \\    nav { border-bottom: 1px solid #ddd; padding-bottom: 1em; margin-bottom: 2em; }
    \\    nav a { margin-right: 1em; text-decoration: none; color: #0066cc; }
    \\    .user-info { background: #f0f0f0; padding: 0.5em 1em; border-radius: 4px; }
    \\    footer { margin-top: 3em; color: #666; font-size: 0.9em; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <nav>
    \\    <a href="/">Home</a>
    \\    <a href="/about">About</a>
    \\    <a href="/dashboard">Dashboard</a>
    \\  </nav>
    \\  {{{ content }}}
    \\  <footer>
    \\    <p>Powered by Blitz ⚡</p>
    \\  </footer>
    \\</body>
    \\</html>
);

const home_page = blitz.Template.compile(
    \\<h1>Welcome to {{ app_name }}!</h1>
    \\<p>A blazing-fast web framework for Zig.</p>
    \\{{# if logged_in }}<div class="user-info">Hello, {{ username }}!</div>{{/ if }}
    \\{{# unless logged_in }}<p><a href="/login">Log in</a> to see your dashboard.</p>{{/ unless }}
);

const about_page = blitz.Template.compile(
    \\<h1>About {{ app_name }}</h1>
    \\<p>{{ description }}</p>
    \\<h2>Features</h2>
    \\<ul>
    \\{{# each features }}<li>{{ . }}</li>
    \\{{/ each }}</ul>
);

fn handleHome(_: *blitz.Request, res: *blitz.Response) void {
    // Render the home content
    var content_buf: [4096]u8 = undefined;
    const content = home_page.render(&content_buf, .{
        .app_name = "Blitz",
        .logged_in = true,
        .username = "Alice",
    }) orelse {
        _ = res.setStatus(.internal_server_error).text("Template render failed");
        return;
    };

    // Wrap in layout
    var buf: [16384]u8 = undefined;
    const html = layout.render(&buf, .{
        .title = "Home",
        .content = content,
    }) orelse {
        _ = res.setStatus(.internal_server_error).text("Layout render failed");
        return;
    };

    _ = res.html(html);
}

fn handleAbout(_: *blitz.Request, res: *blitz.Response) void {
    const features = [_][]const u8{
        "Zero-allocation template rendering",
        "Comptime-powered — templates parsed at compile time",
        "HTML auto-escaping for XSS prevention",
        "Conditionals, loops, raw output, comments",
    };

    var content_buf: [4096]u8 = undefined;
    const content = about_page.render(&content_buf, .{
        .app_name = "Blitz",
        .description = "Built for developers who care about performance without sacrificing ergonomics.",
        .features = @as([]const []const u8, &features),
    }) orelse {
        _ = res.setStatus(.internal_server_error).text("Template error");
        return;
    };

    var buf: [16384]u8 = undefined;
    const html = layout.render(&buf, .{
        .title = "About",
        .content = content,
    }) orelse {
        _ = res.setStatus(.internal_server_error).text("Layout error");
        return;
    };

    _ = res.html(html);
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var router = blitz.Router.init(alloc);

    router.get("/", handleHome);
    router.get("/about", handleAbout);

    std.debug.print("Template example running on http://localhost:8080\n", .{});
    var server = blitz.Server.init(&router, .{ .port = 8080 });
    try server.listen();
}
