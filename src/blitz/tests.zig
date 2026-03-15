const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const types = @import("types.zig");
const router_mod = @import("router.zig");
const parser_mod = @import("parser.zig");

const Method = types.Method;
const StatusCode = types.StatusCode;
const Headers = types.Headers;
const Request = types.Request;
const Response = types.Response;
const Router = router_mod.Router;
const Group = router_mod.Group;

// ════════════════════════════════════════════════════════════════════
// Method tests
// ════════════════════════════════════════════════════════════════════

test "Method.fromString parses valid methods" {
    try testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try testing.expectEqual(Method.PUT, Method.fromString("PUT").?);
    try testing.expectEqual(Method.DELETE, Method.fromString("DELETE").?);
    try testing.expectEqual(Method.PATCH, Method.fromString("PATCH").?);
    try testing.expectEqual(Method.HEAD, Method.fromString("HEAD").?);
    try testing.expectEqual(Method.OPTIONS, Method.fromString("OPTIONS").?);
}

test "Method.fromString rejects invalid methods" {
    try testing.expect(Method.fromString("CONNECT") == null);
    try testing.expect(Method.fromString("") == null);
    try testing.expect(Method.fromString("X") == null);
    try testing.expect(Method.fromString("get") == null); // case sensitive
    try testing.expect(Method.fromString("GETS") == null);
}

// ════════════════════════════════════════════════════════════════════
// StatusCode tests
// ════════════════════════════════════════════════════════════════════

test "StatusCode.code returns numeric value" {
    try testing.expectEqual(@as(u16, 200), StatusCode.ok.code());
    try testing.expectEqual(@as(u16, 404), StatusCode.not_found.code());
    try testing.expectEqual(@as(u16, 500), StatusCode.internal_server_error.code());
}

test "StatusCode.phrase returns reason phrase" {
    try testing.expectEqualStrings("OK", StatusCode.ok.phrase());
    try testing.expectEqualStrings("Not Found", StatusCode.not_found.phrase());
    try testing.expectEqualStrings("Internal Server Error", StatusCode.internal_server_error.phrase());
}

// ════════════════════════════════════════════════════════════════════
// Headers tests
// ════════════════════════════════════════════════════════════════════

test "Headers.set and get" {
    var h = Headers{};
    h.set("Content-Type", "text/plain");
    try testing.expectEqualStrings("text/plain", h.get("Content-Type").?);
    try testing.expectEqualStrings("text/plain", h.get("content-type").?); // case insensitive
    try testing.expect(h.get("X-Missing") == null);
}

test "Headers.set replaces existing" {
    var h = Headers{};
    h.set("Content-Type", "text/plain");
    h.set("Content-Type", "application/json");
    try testing.expectEqualStrings("application/json", h.get("Content-Type").?);
    try testing.expectEqual(@as(usize, 1), h.len);
}

test "Headers.append allows duplicates" {
    var h = Headers{};
    h.append("Set-Cookie", "a=1");
    h.append("Set-Cookie", "b=2");
    try testing.expectEqual(@as(usize, 2), h.len);
    // get() returns first match
    try testing.expectEqualStrings("a=1", h.get("Set-Cookie").?);
}

// ════════════════════════════════════════════════════════════════════
// Request tests
// ════════════════════════════════════════════════════════════════════

test "Request.queryParam parses query string" {
    const req = Request{
        .method = .GET,
        .path = "/search",
        .query = "q=hello&page=2&lang=en",
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    try testing.expectEqualStrings("hello", req.queryParam("q").?);
    try testing.expectEqualStrings("2", req.queryParam("page").?);
    try testing.expectEqualStrings("en", req.queryParam("lang").?);
    try testing.expect(req.queryParam("missing") == null);
}

test "Request.queryParam with no query" {
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    try testing.expect(req.queryParam("q") == null);
}

test "Request.Params.get and set" {
    var p = Request.Params{};
    p.set("id", "42");
    p.set("name", "alice");
    try testing.expectEqualStrings("42", p.get("id").?);
    try testing.expectEqualStrings("alice", p.get("name").?);
    try testing.expect(p.get("missing") == null);
}

// ════════════════════════════════════════════════════════════════════
// Response tests
// ════════════════════════════════════════════════════════════════════

test "Response.text sets body and content type" {
    var res = Response{};
    _ = res.text("hello");
    try testing.expectEqualStrings("hello", res.body.?);
    try testing.expectEqualStrings("text/plain", res.headers.get("Content-Type").?);
}

test "Response.json sets body and content type" {
    var res = Response{};
    _ = res.json("{\"ok\":true}");
    try testing.expectEqualStrings("{\"ok\":true}", res.body.?);
    try testing.expectEqualStrings("application/json", res.headers.get("Content-Type").?);
}

test "Response.html sets body and content type" {
    var res = Response{};
    _ = res.html("<h1>hi</h1>");
    try testing.expectEqualStrings("<h1>hi</h1>", res.body.?);
    try testing.expectEqualStrings("text/html", res.headers.get("Content-Type").?);
}

test "Response.setStatus chains" {
    var res = Response{};
    _ = res.setStatus(.not_found).text("nope");
    try testing.expectEqual(StatusCode.not_found, res.status);
    try testing.expectEqualStrings("nope", res.body.?);
}

test "Response.rawResponse bypasses serialization" {
    var res = Response{};
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    _ = res.rawResponse(raw);
    try testing.expectEqualStrings(raw, res.raw.?);
}

test "Response.writeTo serializes correctly" {
    var res = Response{};
    _ = res.text("hello");

    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    res.writeTo(&out);

    const output = out.items;
    try testing.expect(mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, output, "Server: blitz") != null);
    try testing.expect(mem.indexOf(u8, output, "Content-Type: text/plain") != null);
    try testing.expect(mem.indexOf(u8, output, "Content-Length: 5") != null);
    try testing.expect(mem.endsWith(u8, output, "\r\n\r\nhello"));
}

test "Response.writeTo with raw response" {
    var res = Response{};
    const raw = "HTTP/1.1 204 No Content\r\n\r\n";
    _ = res.rawResponse(raw);

    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    res.writeTo(&out);

    try testing.expectEqualStrings(raw, out.items);
}

// ════════════════════════════════════════════════════════════════════
// Router tests
// ════════════════════════════════════════════════════════════════════

fn dummyHandler(_: *Request, res: *Response) void {
    _ = res.text("ok");
}

fn userHandler(req: *Request, res: *Response) void {
    const id = req.params.get("id") orelse "?";
    _ = res.text(id);
}

fn wildcardHandler(req: *Request, res: *Response) void {
    const fp = req.params.get("filepath") orelse "?";
    _ = res.text(fp);
}

test "Router matches static routes" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/", dummyHandler);
    router.get("/hello", dummyHandler);
    router.get("/hello/world", dummyHandler);

    var p = Request.Params{};
    try testing.expect(router.match(.GET, "/", &p) != null);
    try testing.expect(router.match(.GET, "/hello", &p) != null);
    try testing.expect(router.match(.GET, "/hello/world", &p) != null);
    try testing.expect(router.match(.GET, "/nope", &p) == null);
    try testing.expect(router.match(.POST, "/hello", &p) == null); // wrong method
}

test "Router matches param routes" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/users/:id", userHandler);

    var p = Request.Params{};
    const handler = router.match(.GET, "/users/42", &p);
    try testing.expect(handler != null);
    try testing.expectEqualStrings("42", p.get("id").?);
}

test "Router matches nested params" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/users/:uid/posts/:pid", dummyHandler);

    var p = Request.Params{};
    const handler = router.match(.GET, "/users/5/posts/10", &p);
    try testing.expect(handler != null);
    try testing.expectEqualStrings("5", p.get("uid").?);
    try testing.expectEqualStrings("10", p.get("pid").?);
}

test "Router matches wildcard routes" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/static/*filepath", wildcardHandler);

    var p = Request.Params{};
    const handler = router.match(.GET, "/static/css/style.css", &p);
    try testing.expect(handler != null);
    try testing.expectEqualStrings("css/style.css", p.get("filepath").?);
}

test "Router static takes priority over param" {
    var router = Router.init(std.heap.page_allocator);

    const staticHandler = struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("static");
        }
    }.f;
    const paramHandler = struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("param");
        }
    }.f;

    router.get("/users/me", staticHandler);
    router.get("/users/:id", paramHandler);

    // /users/me should match static, not param
    var p = Request.Params{};
    const handler = router.match(.GET, "/users/me", &p).?;
    var req = Request{
        .method = .GET,
        .path = "/users/me",
        .query = null,
        .headers = .{},
        .body = null,
        .params = p,
        .raw_header = "",
    };
    var res = Response{};
    handler(&req, &res);
    try testing.expectEqualStrings("static", res.body.?);
}

test "Router handle calls 404 for unknown routes" {
    var router = Router.init(std.heap.page_allocator);
    router.get("/", dummyHandler);

    var req = Request{
        .method = .GET,
        .path = "/missing",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.not_found, res.status);
}

test "Router custom 404 handler" {
    var router = Router.init(std.heap.page_allocator);
    router.notFound(struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.setStatus(.not_found).json("{\"error\":\"not found\"}");
        }
    }.f);

    var req = Request{
        .method = .GET,
        .path = "/missing",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.not_found, res.status);
    try testing.expectEqualStrings("{\"error\":\"not found\"}", res.body.?);
}

// ════════════════════════════════════════════════════════════════════
// Middleware tests
// ════════════════════════════════════════════════════════════════════

test "Middleware runs before handler" {
    var router = Router.init(std.heap.page_allocator);

    // Middleware that adds a header
    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Middleware", "ran");
            return true;
        }
    }.f);

    router.get("/", struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("ok");
        }
    }.f);

    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("ok", res.body.?);
    try testing.expectEqualStrings("ran", res.headers.get("X-Middleware").?);
}

test "Middleware can short-circuit" {
    var router = Router.init(std.heap.page_allocator);

    // Auth middleware that blocks
    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            _ = res.setStatus(.unauthorized).text("denied");
            return false;
        }
    }.f);

    router.get("/", struct {
        fn f(_: *Request, res: *Response) void {
            _ = res.text("should not reach");
        }
    }.f);

    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqual(StatusCode.unauthorized, res.status);
    try testing.expectEqualStrings("denied", res.body.?);
}

test "Multiple middleware run in order" {
    var router = Router.init(std.heap.page_allocator);

    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            res.headers.set("X-Order", "first");
            return true;
        }
    }.f);

    router.use(struct {
        fn f(_: *Request, res: *Response) bool {
            // Overwrite to prove second ran after first
            res.headers.set("X-Order", "second");
            return true;
        }
    }.f);

    router.get("/", dummyHandler);

    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};
    router.handle(&req, &res);
    try testing.expectEqualStrings("second", res.headers.get("X-Order").?);
}

// ════════════════════════════════════════════════════════════════════
// Route Group tests
// ════════════════════════════════════════════════════════════════════

test "Route group registers prefixed routes" {
    var router = Router.init(std.heap.page_allocator);
    const api = router.group("/api/v1");
    api.get("/users", dummyHandler);
    api.post("/users", dummyHandler);

    var p = Request.Params{};
    try testing.expect(router.match(.GET, "/api/v1/users", &p) != null);
    try testing.expect(router.match(.POST, "/api/v1/users", &p) != null);
    try testing.expect(router.match(.GET, "/users", &p) == null); // without prefix
}

test "Route group with params" {
    var router = Router.init(std.heap.page_allocator);
    const api = router.group("/api");
    api.get("/users/:id", userHandler);

    var p = Request.Params{};
    const handler = router.match(.GET, "/api/users/99", &p);
    try testing.expect(handler != null);
    try testing.expectEqualStrings("99", p.get("id").?);
}

test "Nested route groups" {
    var router = Router.init(std.heap.page_allocator);
    const api = router.group("/api");
    const v2 = api.group("/v2");
    v2.get("/health", dummyHandler);

    var p = Request.Params{};
    try testing.expect(router.match(.GET, "/api/v2/health", &p) != null);
}

// ════════════════════════════════════════════════════════════════════
// Parser tests
// ════════════════════════════════════════════════════════════════════

test "Parser parses simple GET request" {
    const data = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const result = parser_mod.parse(data).?;
    try testing.expectEqual(Method.GET, result.request.method);
    try testing.expectEqualStrings("/hello", result.request.path);
    try testing.expect(result.request.query == null);
    try testing.expect(result.request.body == null);
    try testing.expectEqual(data.len, result.total_len);
}

test "Parser parses GET with query string" {
    const data = "GET /search?q=zig&page=1 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const result = parser_mod.parse(data).?;
    try testing.expectEqualStrings("/search", result.request.path);
    try testing.expectEqualStrings("q=zig&page=1", result.request.query.?);
}

test "Parser parses POST with body" {
    const data = "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\n\r\nHello, World!";
    const result = parser_mod.parse(data).?;
    try testing.expectEqual(Method.POST, result.request.method);
    try testing.expectEqualStrings("/data", result.request.path);
    try testing.expectEqualStrings("Hello, World!", result.request.body.?);
    try testing.expectEqual(data.len, result.total_len);
}

test "Parser parses headers" {
    const data = "GET / HTTP/1.1\r\nHost: example.com\r\nAccept: text/html\r\nX-Custom: foo\r\n\r\n";
    const result = parser_mod.parse(data).?;
    try testing.expectEqualStrings("example.com", result.request.headers.get("Host").?);
    try testing.expectEqualStrings("text/html", result.request.headers.get("Accept").?);
    try testing.expectEqualStrings("foo", result.request.headers.get("X-Custom").?);
}

test "Parser returns null for incomplete request" {
    const data = "GET /hello HTTP/1.1\r\nHost: localhost\r\n"; // no \r\n\r\n
    try testing.expect(parser_mod.parse(data) == null);
}

test "Parser returns null for incomplete body" {
    const data = "POST /data HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort";
    try testing.expect(parser_mod.parse(data) == null);
}

test "Parser handles pipelined requests" {
    const req1 = "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const req2 = "GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const data = req1 ++ req2;

    const r1 = parser_mod.parse(data).?;
    try testing.expectEqualStrings("/a", r1.request.path);
    try testing.expectEqual(req1.len, r1.total_len);

    const r2 = parser_mod.parse(data[r1.total_len..]).?;
    try testing.expectEqualStrings("/b", r2.request.path);
}

// ════════════════════════════════════════════════════════════════════
// Utility tests
// ════════════════════════════════════════════════════════════════════

test "asciiEqlIgnoreCase" {
    try testing.expect(types.asciiEqlIgnoreCase("Content-Type", "content-type"));
    try testing.expect(types.asciiEqlIgnoreCase("HOST", "host"));
    try testing.expect(!types.asciiEqlIgnoreCase("abc", "abd"));
    try testing.expect(!types.asciiEqlIgnoreCase("ab", "abc"));
}

test "writeUsize" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", types.writeUsize(&buf, 0));
    try testing.expectEqualStrings("42", types.writeUsize(&buf, 42));
    try testing.expectEqualStrings("12345", types.writeUsize(&buf, 12345));
}

test "writeI64" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", types.writeI64(&buf, 0));
    try testing.expectEqualStrings("42", types.writeI64(&buf, 42));
    try testing.expectEqualStrings("-7", types.writeI64(&buf, -7));
}
