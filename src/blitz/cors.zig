const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const Request = types.Request;
const Response = types.Response;
const Method = types.Method;
const MiddlewareFn = types.MiddlewareFn;
const asciiEqlIgnoreCase = types.asciiEqlIgnoreCase;

/// CORS configuration for the middleware.
pub const CorsConfig = struct {
    /// Allowed origins. Use `&.{"*"}` for any origin.
    /// When set to a specific list, the middleware checks the request's
    /// Origin header against each entry (case-insensitive).
    origins: []const []const u8 = &.{"*"},

    /// Allowed HTTP methods (returned in Access-Control-Allow-Methods).
    methods: []const u8 = "GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS",

    /// Allowed request headers (returned in Access-Control-Allow-Headers).
    headers: []const u8 = "Content-Type, Authorization, X-Request-ID",

    /// Exposed response headers (returned in Access-Control-Expose-Headers).
    /// Empty means no extra headers are exposed.
    expose_headers: []const u8 = "",

    /// Whether to include Access-Control-Allow-Credentials: true.
    allow_credentials: bool = false,

    /// Max age in seconds for preflight cache (Access-Control-Max-Age).
    /// 0 means the header is not sent.
    max_age: u32 = 86400,

    /// Pre-formatted Max-Age value (computed at init).
    max_age_str: []const u8 = "86400",
};

/// Builds a CORS middleware function from the given config.
///
/// Usage:
/// ```zig
/// const cors_mw = blitz.Cors.middleware(.{
///     .origins = &.{ "https://example.com", "https://app.example.com" },
///     .allow_credentials = true,
///     .max_age = 3600,
/// });
/// router.use(cors_mw);
/// ```
///
/// For simple permissive CORS (allow everything):
/// ```zig
/// router.use(blitz.Cors.permissive());
/// ```
pub fn middleware(comptime config: CorsConfig) MiddlewareFn {
    return struct {
        fn handler(req: *Request, res: *Response) bool {
            const origin = req.headers.get("Origin");

            // No Origin header = not a CORS request, pass through
            if (origin == null) return true;

            const origin_val = origin.?;

            // Check if origin is allowed
            const allowed = comptime config.origins.len == 1 and
                mem.eql(u8, config.origins[0], "*");

            if (allowed) {
                if (comptime config.allow_credentials) {
                    // With credentials, can't use * — must echo the origin
                    res.headers.set("Access-Control-Allow-Origin", origin_val);
                } else {
                    res.headers.set("Access-Control-Allow-Origin", "*");
                }
            } else {
                // Check against the allow-list
                var found = false;
                inline for (config.origins) |allowed_origin| {
                    if (!found and asciiEqlIgnoreCase(origin_val, allowed_origin)) {
                        found = true;
                    }
                }
                if (!found) {
                    // Origin not allowed — still process the request but
                    // don't send CORS headers (browser will block the response)
                    return true;
                }
                res.headers.set("Access-Control-Allow-Origin", origin_val);
            }

            // Vary header — important for caching when origin is echoed
            if (comptime !(config.origins.len == 1 and
                mem.eql(u8, config.origins[0], "*")) or config.allow_credentials)
            {
                res.headers.set("Vary", "Origin");
            }

            if (comptime config.allow_credentials) {
                res.headers.set("Access-Control-Allow-Credentials", "true");
            }

            if (comptime config.expose_headers.len > 0) {
                res.headers.set("Access-Control-Expose-Headers", config.expose_headers);
            }

            // Preflight request (OPTIONS with Access-Control-Request-Method)
            if (req.method == .OPTIONS) {
                if (req.headers.get("Access-Control-Request-Method") != null) {
                    res.headers.set("Access-Control-Allow-Methods", config.methods);
                    res.headers.set("Access-Control-Allow-Headers", config.headers);

                    if (comptime config.max_age > 0) {
                        res.headers.set("Access-Control-Max-Age", config.max_age_str);
                    }

                    // Respond to preflight immediately — no need to hit the handler
                    _ = res.setStatus(.no_content).text("");
                    return false;
                }
            }

            return true;
        }
    }.handler;
}

/// Returns a permissive CORS middleware that allows all origins,
/// all standard methods, and common headers.
///
/// Equivalent to `middleware(.{})`.
pub fn permissive() MiddlewareFn {
    return middleware(.{});
}

// ── Tests ───────────────────────────────────────────────────────────

fn makeReq(method: Method, origin: ?[]const u8, acr_method: ?[]const u8) Request {
    var req = Request{
        .method = method,
        .path = "/test",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    if (origin) |o| req.headers.set("Origin", o);
    if (acr_method) |m| req.headers.set("Access-Control-Request-Method", m);
    return req;
}

test "CORS: no origin header — passes through" {
    const mw = permissive();
    var req = makeReq(.GET, null, null);
    var res = Response{};
    const result = mw(&req, &res);
    try std.testing.expect(result == true);
    try std.testing.expect(res.headers.get("Access-Control-Allow-Origin") == null);
}

test "CORS: permissive — sets wildcard origin" {
    const mw = permissive();
    var req = makeReq(.GET, "https://example.com", null);
    var res = Response{};
    const result = mw(&req, &res);
    try std.testing.expect(result == true);
    try std.testing.expectEqualStrings("*", res.headers.get("Access-Control-Allow-Origin").?);
}

test "CORS: specific origins — allowed" {
    const mw = middleware(.{
        .origins = &.{ "https://app.example.com", "https://admin.example.com" },
    });
    var req = makeReq(.GET, "https://app.example.com", null);
    var res = Response{};
    const result = mw(&req, &res);
    try std.testing.expect(result == true);
    try std.testing.expectEqualStrings("https://app.example.com", res.headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("Origin", res.headers.get("Vary").?);
}

test "CORS: specific origins — not allowed" {
    const mw = middleware(.{
        .origins = &.{"https://allowed.com"},
    });
    var req = makeReq(.GET, "https://evil.com", null);
    var res = Response{};
    const result = mw(&req, &res);
    try std.testing.expect(result == true);
    try std.testing.expect(res.headers.get("Access-Control-Allow-Origin") == null);
}

test "CORS: preflight — returns 204 with correct headers" {
    const mw = middleware(.{
        .max_age = 3600,
        .max_age_str = "3600",
    });
    var req = makeReq(.OPTIONS, "https://example.com", "POST");
    var res = Response{};
    const result = mw(&req, &res);
    try std.testing.expect(result == false); // short-circuit
    try std.testing.expectEqualStrings("*", res.headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expect(res.headers.get("Access-Control-Allow-Methods") != null);
    try std.testing.expect(res.headers.get("Access-Control-Allow-Headers") != null);
    try std.testing.expectEqualStrings("3600", res.headers.get("Access-Control-Max-Age").?);
}

test "CORS: credentials — echoes origin instead of wildcard" {
    const mw = middleware(.{
        .allow_credentials = true,
    });
    var req = makeReq(.GET, "https://myapp.com", null);
    var res = Response{};
    _ = mw(&req, &res);
    try std.testing.expectEqualStrings("https://myapp.com", res.headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("true", res.headers.get("Access-Control-Allow-Credentials").?);
    try std.testing.expectEqualStrings("Origin", res.headers.get("Vary").?);
}

test "CORS: expose headers" {
    const mw = middleware(.{
        .expose_headers = "X-Request-ID, X-Total-Count",
    });
    var req = makeReq(.GET, "https://example.com", null);
    var res = Response{};
    _ = mw(&req, &res);
    try std.testing.expectEqualStrings("X-Request-ID, X-Total-Count", res.headers.get("Access-Control-Expose-Headers").?);
}
