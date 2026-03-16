const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const Request = types.Request;
const Response = types.Response;
const MiddlewareFn = types.MiddlewareFn;
const errors_mod = @import("errors.zig");

/// Rate limiter configuration.
pub const RateLimitConfig = struct {
    /// Maximum requests allowed in the window.
    max_requests: u32 = 100,

    /// Window duration in seconds.
    window_secs: u32 = 60,

    /// Maximum number of tracked IPs (fixed-size table).
    max_clients: u16 = 4096,
};

/// Per-client rate limit state.
const ClientState = struct {
    /// First 16 bytes of IP string (covers all IPv4 and most IPv6).
    ip_key: [16]u8 = .{0} ** 16,
    ip_len: u8 = 0,
    /// Request count in current window.
    count: u32 = 0,
    /// Window start (monotonic seconds since boot).
    window_start: i64 = 0,
};

/// Fixed-size rate limiter with linear probing.
/// Thread-safe: each worker thread gets its own server instance,
/// so rate limiting is per-thread. For exact global limits,
/// you'd need shared memory — but per-thread is fine for most APIs
/// (the total rate across N threads is N × max_requests).
pub const RateLimiter = struct {
    clients: []ClientState,
    config: RateLimitConfig,

    pub fn init(alloc: std.mem.Allocator, config: RateLimitConfig) !RateLimiter {
        const clients = try alloc.alloc(ClientState, config.max_clients);
        @memset(clients, ClientState{});
        return .{
            .clients = clients,
            .config = config,
        };
    }

    pub fn deinit(self: *RateLimiter, alloc: std.mem.Allocator) void {
        alloc.free(self.clients);
    }

    /// Check if a request from this IP is allowed. Returns remaining requests.
    /// Returns null if rate limited.
    pub fn check(self: *RateLimiter, ip: []const u8) ?u32 {
        const now = nowSecs();
        const idx = self.findOrCreate(ip, now) orelse return null;
        const client = &self.clients[idx];

        // Reset window if expired
        if (now - client.window_start >= self.config.window_secs) {
            client.count = 0;
            client.window_start = now;
        }

        if (client.count >= self.config.max_requests) {
            return null; // rate limited
        }

        client.count += 1;
        return self.config.max_requests - client.count;
    }

    /// Returns remaining seconds until the window resets for this IP.
    pub fn retryAfter(self: *RateLimiter, ip: []const u8) u32 {
        const now = nowSecs();
        const idx = self.findSlot(ip) orelse return 0;
        const client = &self.clients[idx];
        const elapsed = now - client.window_start;
        if (elapsed >= self.config.window_secs) return 0;
        return @intCast(self.config.window_secs - @as(u32, @intCast(elapsed)));
    }

    fn findSlot(self: *RateLimiter, ip: []const u8) ?usize {
        var key: [16]u8 = .{0} ** 16;
        const klen: u8 = @intCast(@min(ip.len, 16));
        @memcpy(key[0..klen], ip[0..klen]);

        const hash = hashIp(key[0..klen]);
        const cap = self.clients.len;
        var i: usize = hash % cap;
        var probes: usize = 0;

        while (probes < 16) : ({
            i = (i + 1) % cap;
            probes += 1;
        }) {
            const c = &self.clients[i];
            if (c.ip_len == klen and mem.eql(u8, c.ip_key[0..klen], key[0..klen])) {
                return i;
            }
            if (c.ip_len == 0) return null;
        }
        return null;
    }

    fn findOrCreate(self: *RateLimiter, ip: []const u8, now: i64) ?usize {
        var key: [16]u8 = .{0} ** 16;
        const klen: u8 = @intCast(@min(ip.len, 16));
        @memcpy(key[0..klen], ip[0..klen]);

        const hash = hashIp(key[0..klen]);
        const cap = self.clients.len;
        var i: usize = hash % cap;
        var probes: usize = 0;
        var oldest_idx: ?usize = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        while (probes < 16) : ({
            i = (i + 1) % cap;
            probes += 1;
        }) {
            const c = &self.clients[i];

            // Found existing entry
            if (c.ip_len == klen and mem.eql(u8, c.ip_key[0..klen], key[0..klen])) {
                return i;
            }

            // Empty slot — claim it
            if (c.ip_len == 0) {
                c.ip_key = key;
                c.ip_len = klen;
                c.count = 0;
                c.window_start = now;
                return i;
            }

            // Track oldest for eviction
            if (c.window_start < oldest_time) {
                oldest_time = c.window_start;
                oldest_idx = i;
            }
        }

        // All probe slots full — evict oldest
        if (oldest_idx) |oi| {
            const c = &self.clients[oi];
            c.ip_key = key;
            c.ip_len = klen;
            c.count = 0;
            c.window_start = now;
            return oi;
        }

        return null; // shouldn't happen with probes > 0
    }

    fn hashIp(ip: []const u8) usize {
        // FNV-1a hash
        var h: u64 = 0xcbf29ce484222325;
        for (ip) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
        return @intCast(h);
    }

    fn nowSecs() i64 {
        const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
        return ts.sec;
    }
};

/// Extract client IP from request headers.
/// Checks X-Forwarded-For, X-Real-IP, then falls back to "unknown".
pub fn clientIp(req: *const Request) []const u8 {
    // X-Forwarded-For: client, proxy1, proxy2 — take the first
    if (req.headers.get("X-Forwarded-For")) |xff| {
        if (mem.indexOf(u8, xff, ",")) |comma| {
            const ip = mem.trim(u8, xff[0..comma], " ");
            if (ip.len > 0) return ip;
        } else {
            const ip = mem.trim(u8, xff, " ");
            if (ip.len > 0) return ip;
        }
    }
    if (req.headers.get("X-Real-IP")) |xri| {
        const ip = mem.trim(u8, xri, " ");
        if (ip.len > 0) return ip;
    }
    return "unknown";
}

/// Convenience: check rate limit and send 429 response if exceeded.
/// Returns true if the request is allowed, false if rate limited.
///
/// Usage in handlers:
/// ```zig
/// var limiter = try blitz.RateLimiter.init(allocator, .{
///     .max_requests = 100,
///     .window_secs = 60,
/// });
///
/// fn myHandler(req: *blitz.Request, res: *blitz.Response) void {
///     if (!blitz.RateLimit.allow(&limiter, req, res)) return;
///     // ... handle request normally
/// }
/// ```
pub fn allow(limiter: *RateLimiter, req: *const Request, res: *Response) bool {
    const ip = clientIp(req);
    if (limiter.check(ip)) |remaining| {
        // Set standard rate limit headers
        var buf: [16]u8 = undefined;
        const remaining_str = writeU32(&buf, remaining);
        res.headers.set("X-RateLimit-Remaining", remaining_str);
        return true;
    } else {
        // Rate limited
        var retry_buf: [16]u8 = undefined;
        const retry = limiter.retryAfter(ip);
        const retry_str = writeU32(&retry_buf, retry);
        res.headers.set("Retry-After", retry_str);
        errors_mod.sendError(res, .too_many_requests, "Rate limit exceeded");
        return false;
    }
}

fn writeU32(buf: []u8, val: u32) []const u8 {
    if (val == 0) return "0";
    var v = val;
    var i: usize = buf.len;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    return buf[i..];
}

/// Thread-safe rate limiter using atomics for cross-reactor coordination.
/// Unlike `RateLimiter` (which is per-thread), this can be shared across all
/// reactor threads via a pointer, giving exact global rate limits.
///
/// Usage:
/// ```zig
/// // Create once at startup (before spawning reactors):
/// var shared_limiter = try blitz.SharedRateLimiter.init(allocator, .{
///     .max_requests = 100,
///     .window_secs = 60,
/// });
/// defer shared_limiter.deinit(allocator);
///
/// // Pass pointer to each reactor's handler:
/// fn myHandler(req: *blitz.Request, res: *blitz.Response) void {
///     if (!blitz.SharedRateLimit.allow(&shared_limiter, req, res)) return;
///     // ... handle request
/// }
/// ```
pub const SharedRateLimiter = struct {
    clients: []SharedClientState,
    config: RateLimitConfig,

    const SharedClientState = struct {
        /// First 16 bytes of IP key.
        ip_key: [16]u8 = .{0} ** 16,
        ip_len: u8 = 0,
        /// Atomic request count in current window.
        count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        /// Atomic window start (monotonic seconds).
        window_start: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
        /// Spinlock for slot initialization (0 = unlocked, 1 = locked).
        lock: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
        /// Whether this slot is occupied.
        occupied: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    };

    pub fn init(alloc: std.mem.Allocator, config: RateLimitConfig) !SharedRateLimiter {
        const clients = try alloc.alloc(SharedClientState, config.max_clients);
        @memset(clients, SharedClientState{});
        return .{
            .clients = clients,
            .config = config,
        };
    }

    pub fn deinit(self: *SharedRateLimiter, alloc: std.mem.Allocator) void {
        alloc.free(self.clients);
    }

    /// Check if a request from this IP is allowed. Returns remaining requests.
    /// Returns null if rate limited. Thread-safe.
    pub fn check(self: *SharedRateLimiter, ip: []const u8) ?u32 {
        const now = nowSecs();
        const idx = self.findOrCreate(ip, now) orelse return null;
        const client = &self.clients[idx];

        // Check if window expired — try to reset atomically
        const ws = client.window_start.load(.acquire);
        if (now - ws >= self.config.window_secs) {
            // Try to claim the reset
            if (client.window_start.cmpxchgStrong(ws, now, .acq_rel, .acquire) == null) {
                // We won the race — reset count
                client.count.store(0, .release);
            }
            // If we lost the race, another thread reset it — fall through
        }

        // Atomically increment count
        const prev = client.count.fetchAdd(1, .acq_rel);
        if (prev >= self.config.max_requests) {
            // Over limit — undo our increment (best-effort, slight overcount is ok)
            _ = client.count.fetchSub(1, .acq_rel);
            return null;
        }

        return self.config.max_requests - prev - 1;
    }

    /// Returns remaining seconds until the window resets for this IP.
    pub fn retryAfter(self: *SharedRateLimiter, ip: []const u8) u32 {
        const now = nowSecs();
        const idx = self.findSlot(ip) orelse return 0;
        const client = &self.clients[idx];
        const ws = client.window_start.load(.acquire);
        const elapsed = now - ws;
        if (elapsed >= self.config.window_secs) return 0;
        return @intCast(self.config.window_secs - @as(u32, @intCast(elapsed)));
    }

    fn findSlot(self: *SharedRateLimiter, ip: []const u8) ?usize {
        var key: [16]u8 = .{0} ** 16;
        const klen: u8 = @intCast(@min(ip.len, 16));
        @memcpy(key[0..klen], ip[0..klen]);

        const hash = hashIp(key[0..klen]);
        const cap = self.clients.len;
        var i: usize = hash % cap;
        var probes: usize = 0;

        while (probes < 16) : ({
            i = (i + 1) % cap;
            probes += 1;
        }) {
            const c = &self.clients[i];
            if (c.occupied.load(.acquire) == 0) return null;
            if (c.ip_len == klen and mem.eql(u8, c.ip_key[0..klen], key[0..klen])) {
                return i;
            }
        }
        return null;
    }

    fn findOrCreate(self: *SharedRateLimiter, ip: []const u8, now: i64) ?usize {
        var key: [16]u8 = .{0} ** 16;
        const klen: u8 = @intCast(@min(ip.len, 16));
        @memcpy(key[0..klen], ip[0..klen]);

        const hash = hashIp(key[0..klen]);
        const cap = self.clients.len;
        var i: usize = hash % cap;
        var probes: usize = 0;
        var oldest_idx: ?usize = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        while (probes < 16) : ({
            i = (i + 1) % cap;
            probes += 1;
        }) {
            const c = &self.clients[i];

            // Found existing entry
            if (c.occupied.load(.acquire) == 1 and
                c.ip_len == klen and mem.eql(u8, c.ip_key[0..klen], key[0..klen]))
            {
                return i;
            }

            // Empty slot — try to claim via spinlock
            if (c.occupied.load(.acquire) == 0) {
                if (c.lock.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                    // Won the lock — initialize
                    c.ip_key = key;
                    c.ip_len = klen;
                    c.count.store(0, .release);
                    c.window_start.store(now, .release);
                    c.occupied.store(1, .release);
                    c.lock.store(0, .release);
                    return i;
                }
                // Lost the lock — another thread is initializing, skip
            }

            // Track oldest for eviction
            const ws = c.window_start.load(.acquire);
            if (ws < oldest_time) {
                oldest_time = ws;
                oldest_idx = i;
            }
        }

        // All probe slots full — evict oldest
        if (oldest_idx) |oi| {
            const c = &self.clients[oi];
            if (c.lock.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                c.ip_key = key;
                c.ip_len = klen;
                c.count.store(0, .release);
                c.window_start.store(now, .release);
                c.occupied.store(1, .release);
                c.lock.store(0, .release);
                return oi;
            }
        }

        return null;
    }
};

/// Convenience: check shared rate limit and send 429 response if exceeded.
/// Thread-safe version of `allow()` for use with `SharedRateLimiter`.
pub fn allowShared(limiter: *SharedRateLimiter, req: *const Request, res: *Response) bool {
    const ip = clientIp(req);
    if (limiter.check(ip)) |remaining| {
        var buf: [16]u8 = undefined;
        const remaining_str = writeU32(&buf, remaining);
        res.headers.set("X-RateLimit-Remaining", remaining_str);
        return true;
    } else {
        var retry_buf: [16]u8 = undefined;
        const retry = limiter.retryAfter(ip);
        const retry_str = writeU32(&retry_buf, retry);
        res.headers.set("Retry-After", retry_str);
        errors_mod.sendError(res, .too_many_requests, "Rate limit exceeded");
        return false;
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "RateLimiter: allows requests within limit" {
    var limiter = try RateLimiter.init(std.testing.allocator, .{
        .max_requests = 3,
        .window_secs = 60,
        .max_clients = 16,
    });
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 2), limiter.check("1.2.3.4"));
    try std.testing.expectEqual(@as(?u32, 1), limiter.check("1.2.3.4"));
    try std.testing.expectEqual(@as(?u32, 0), limiter.check("1.2.3.4"));
    try std.testing.expectEqual(@as(?u32, null), limiter.check("1.2.3.4")); // limited
}

test "RateLimiter: separate buckets per IP" {
    var limiter = try RateLimiter.init(std.testing.allocator, .{
        .max_requests = 2,
        .window_secs = 60,
        .max_clients = 16,
    });
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 1), limiter.check("10.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 1), limiter.check("10.0.0.2"));
    try std.testing.expectEqual(@as(?u32, 0), limiter.check("10.0.0.1"));
    try std.testing.expectEqual(@as(?u32, null), limiter.check("10.0.0.1")); // limited
    try std.testing.expectEqual(@as(?u32, 0), limiter.check("10.0.0.2")); // still ok
}

test "RateLimiter: hash collision handling" {
    var limiter = try RateLimiter.init(std.testing.allocator, .{
        .max_requests = 10,
        .window_secs = 60,
        .max_clients = 4, // very small — forces collisions
    });
    defer limiter.deinit(std.testing.allocator);

    // These should work even in a tiny table
    _ = limiter.check("192.168.1.1");
    _ = limiter.check("192.168.1.2");
    _ = limiter.check("192.168.1.3");
    // Table is nearly full but shouldn't crash
    _ = limiter.check("192.168.1.4");
}

test "clientIp: X-Forwarded-For with multiple proxies" {
    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    req.headers.set("X-Forwarded-For", "203.0.113.50, 70.41.3.18, 150.172.238.178");
    try std.testing.expectEqualStrings("203.0.113.50", clientIp(&req));
}

test "clientIp: X-Real-IP fallback" {
    var req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    req.headers.set("X-Real-IP", "10.0.0.1");
    try std.testing.expectEqualStrings("10.0.0.1", clientIp(&req));
}

test "clientIp: no headers — returns unknown" {
    const req = Request{
        .method = .GET,
        .path = "/",
        .query = null,
        .headers = .{},
        .body = null,
        .raw_header = "",
    };
    try std.testing.expectEqualStrings("unknown", clientIp(&req));
}

test "SharedRateLimiter: allows requests within limit" {
    var limiter = try SharedRateLimiter.init(std.testing.allocator, .{
        .max_requests = 3,
        .window_secs = 60,
        .max_clients = 16,
    });
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 2), limiter.check("1.2.3.4"));
    try std.testing.expectEqual(@as(?u32, 1), limiter.check("1.2.3.4"));
    try std.testing.expectEqual(@as(?u32, 0), limiter.check("1.2.3.4"));
    try std.testing.expectEqual(@as(?u32, null), limiter.check("1.2.3.4")); // limited
}

test "SharedRateLimiter: separate buckets per IP" {
    var limiter = try SharedRateLimiter.init(std.testing.allocator, .{
        .max_requests = 2,
        .window_secs = 60,
        .max_clients = 16,
    });
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 1), limiter.check("10.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 1), limiter.check("10.0.0.2"));
    try std.testing.expectEqual(@as(?u32, 0), limiter.check("10.0.0.1"));
    try std.testing.expectEqual(@as(?u32, null), limiter.check("10.0.0.1")); // limited
    try std.testing.expectEqual(@as(?u32, 0), limiter.check("10.0.0.2")); // still ok
}

test "SharedRateLimiter: hash collision handling" {
    var limiter = try SharedRateLimiter.init(std.testing.allocator, .{
        .max_requests = 10,
        .window_secs = 60,
        .max_clients = 4, // very small — forces collisions
    });
    defer limiter.deinit(std.testing.allocator);

    _ = limiter.check("192.168.1.1");
    _ = limiter.check("192.168.1.2");
    _ = limiter.check("192.168.1.3");
    _ = limiter.check("192.168.1.4");
}
