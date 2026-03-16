const std = @import("std");
const types = @import("types.zig");
const Request = types.Request;
const Response = types.Response;

// ── Timeout Middleware ──────────────────────────────────────────────
// Creates a comptime-configured timeout middleware that sets a request deadline.
// After the handler chain completes, the server checks if the deadline was exceeded
// and overwrites the response with 504 Gateway Timeout.
//
// Usage:
//   const timeout = blitz.Timeout.middleware(.{ .timeout_ms = 5000 });
//   router.use(timeout);
//
// Or per-route:
//   router.useAt("/slow", blitz.Timeout.middleware(.{ .timeout_ms = 30000 }));

pub const TimeoutConfig = struct {
    /// Maximum handler execution time in milliseconds
    timeout_ms: u32 = 5000,
    /// Custom timeout response body (null = default JSON error)
    message: ?[]const u8 = null,
};

/// Create a timeout middleware with comptime configuration.
/// Sets a deadline on the request that the server checks after handler execution.
pub fn middleware(comptime config: TimeoutConfig) types.MiddlewareFn {
    const S = struct {
        fn check(req: *Request, _: *Response) bool {
            // Set deadline timestamp on request
            const now_ns = now();
            req.deadline_ns = now_ns + @as(i64, config.timeout_ms) * 1_000_000;
            return true; // Continue to handler
        }
    };
    return S.check;
}

/// Check if a request has exceeded its deadline.
/// Called by the server after handler execution.
/// Returns true if timed out, and overwrites response with 504.
pub fn checkDeadline(req: *const Request, res: *Response, config: TimeoutConfig) bool {
    const deadline = req.deadline_ns;
    if (deadline == 0) return false; // No deadline set

    const elapsed_ns = now() - (deadline - @as(i64, config.timeout_ms) * 1_000_000);
    if (elapsed_ns < @as(i64, config.timeout_ms) * 1_000_000) return false;

    // Timed out — overwrite response
    const msg = config.message orelse
        "{\"error\":{\"status\":504,\"message\":\"Request timeout\"}}";
    _ = res.setStatus(.gateway_timeout).json(msg);
    return true;
}

/// Monotonic clock in nanoseconds.
pub fn now() i64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return ts.sec * 1_000_000_000 + ts.nsec;
}

// ── Tests ───────────────────────────────────────────────────────────

test "timeout middleware sets deadline" {
    const mw = middleware(.{ .timeout_ms = 5000 });
    var req = Request{
        .method = .GET,
        .path = "/test",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};

    const result = mw(&req, &res);
    try std.testing.expect(result); // Should continue
    try std.testing.expect(req.deadline_ns > 0); // Deadline set
}

test "checkDeadline returns false when no deadline" {
    const req = Request{
        .method = .GET,
        .path = "/test",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};

    const timed_out = checkDeadline(&req, &res, .{ .timeout_ms = 5000 });
    try std.testing.expect(!timed_out);
}

test "checkDeadline returns false within deadline" {
    var req = Request{
        .method = .GET,
        .path = "/test",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};

    // Set deadline 5 seconds from now
    const mw = middleware(.{ .timeout_ms = 5000 });
    _ = mw(&req, &res);

    // Check immediately — should not be timed out
    const timed_out = checkDeadline(&req, &res, .{ .timeout_ms = 5000 });
    try std.testing.expect(!timed_out);
}

test "checkDeadline returns true after deadline" {
    var req = Request{
        .method = .GET,
        .path = "/test",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    var res = Response{};

    // Set deadline 0ms from now (immediate timeout)
    const mw = middleware(.{ .timeout_ms = 0 });
    _ = mw(&req, &res);

    // Any check after should time out
    std.time.sleep(1_000); // 1 microsecond
    const timed_out = checkDeadline(&req, &res, .{ .timeout_ms = 0 });
    try std.testing.expect(timed_out);
}
