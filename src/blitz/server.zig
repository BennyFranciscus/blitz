const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const Thread = std.Thread;

const types = @import("types.zig");
const parser = @import("parser.zig");
const Router = @import("router.zig").Router;
const pool_mod = @import("pool.zig");
const ConnPool = pool_mod.ConnPool;
const ConnState = pool_mod.ConnState;
const Request = types.Request;
const Response = types.Response;

// ── Constants ───────────────────────────────────────────────────────
const MAX_EVENTS: usize = 512;
const BUF_SIZE: usize = 65536;
const MAX_CONNS: usize = 65536;
const SOCK_STREAM: u32 = linux.SOCK.STREAM;
const SOCK_NONBLOCK: u32 = linux.SOCK.NONBLOCK;
const AF_INET: u32 = linux.AF.INET;
const SOL_SOCKET: i32 = 1;
const SO_REUSEPORT: u32 = 15;
const SO_REUSEADDR: u32 = 2;
const IPPROTO_TCP: i32 = 6;
const TCP_NODELAY: u32 = 1;

// ── Server Configuration ────────────────────────────────────────────
pub const Config = struct {
    port: u16 = 8080,
    threads: ?usize = null, // null = auto-detect
    keep_alive_timeout: u32 = 60, // seconds (0 = disable)
};

// ── Server ──────────────────────────────────────────────────────────
pub const Server = struct {
    router: *Router,
    config: Config,

    pub fn init(router: *Router, config: Config) Server {
        return .{ .router = router, .config = config };
    }

    /// Start the server — blocks forever
    pub fn listen(self: *Server) !void {
        const n_threads = self.config.threads orelse @max(Thread.getCpuCount() catch 1, 1);

        var threads = std.ArrayList(Thread).init(std.heap.c_allocator);
        defer threads.deinit();

        for (1..n_threads) |_| {
            const t = try Thread.spawn(.{}, workerThread, .{ self.router, self.config });
            try threads.append(t);
        }

        workerThread(self.router, self.config);
    }
};

// Default pool size per worker thread (covers most concurrent connections)
const POOL_SIZE: usize = 4096;

// Sentinel fd for the timerfd (keep-alive sweep timer)
const TIMER_FD_SENTINEL: i32 = -2;

fn workerThread(router: *Router, config: Config) void {
    const alloc = std.heap.c_allocator;
    const port = config.port;
    const ka_timeout: i64 = @intCast(config.keep_alive_timeout);

    // Initialize connection pool for this worker
    var pool = ConnPool.init(alloc, POOL_SIZE) catch return;
    _ = &pool;

    const sock: i32 = @intCast(posix.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0) catch return);
    defer posix.close(sock);

    setSockOptInt(sock, SOL_SOCKET, SO_REUSEPORT, 1);
    setSockOptInt(sock, SOL_SOCKET, SO_REUSEADDR, 1);
    setSockOptInt(sock, IPPROTO_TCP, TCP_NODELAY, 1);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    posix.bind(sock, &address.any, address.getOsSockLen()) catch return;
    posix.listen(sock, 4096) catch return;

    const epfd = posix.epoll_create1(linux.EPOLL.CLOEXEC) catch return;
    defer posix.close(epfd);

    var listen_ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = sock } };
    posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sock, &listen_ev) catch return;

    // Set up timerfd for keep-alive sweep (fires every 10 seconds)
    var timer_fd: i32 = -1;
    if (ka_timeout > 0) {
        timer_fd = timerfdCreate() orelse -1;
        if (timer_fd >= 0) {
            // Sweep interval: every 10 seconds (or half the timeout if small)
            const half = @divTrunc(ka_timeout, 2);
            const interval: i64 = if (ka_timeout < 20) (if (half > 1) half else 1) else 10;
            timerfdSetInterval(timer_fd, interval);
            var timer_ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = timer_fd } };
            posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, timer_fd, &timer_ev) catch {
                posix.close(timer_fd);
                timer_fd = -1;
            };
        }
    }
    defer if (timer_fd >= 0) posix.close(timer_fd);

    var conns: [MAX_CONNS]?*ConnState = undefined;
    @memset(&conns, null);
    var events: [MAX_EVENTS]linux.epoll_event = undefined;

    while (true) {
        const n = posix.epoll_wait(epfd, &events, -1);
        for (events[0..n]) |ev| {
            const fd = ev.data.fd;

            if (fd == sock) {
                acceptLoop(&pool, sock, epfd, &conns, ka_timeout > 0);
                continue;
            }

            // Timer event — sweep idle connections
            if (fd == timer_fd) {
                // Read the timerfd to clear the event
                var timer_buf: [8]u8 = undefined;
                _ = posix.read(timer_fd, &timer_buf) catch {};
                sweepIdleConns(&pool, &conns, epfd, ka_timeout);
                continue;
            }

            const uidx: usize = @intCast(fd);
            if (uidx >= MAX_CONNS) continue;
            const st = conns[uidx] orelse continue;

            if (ev.events & linux.EPOLL.IN != 0) {
                var should_close = false;

                while (st.read_len < BUF_SIZE) {
                    const n_read = posix.read(fd, st.read_buf[st.read_len..]) catch {
                        should_close = true;
                        break;
                    };
                    if (n_read == 0) {
                        should_close = true;
                        break;
                    }
                    st.read_len += n_read;
                }

                // Parse and handle pipelined requests
                var off: usize = 0;
                while (off < st.read_len) {
                    const result = parser.parse(st.read_buf[off..st.read_len]) orelse break;
                    var req = result.request;
                    var res = Response{};

                    router.handle(&req, &res);
                    res.writeTo(&st.write_list);

                    off += result.total_len;
                }

                if (off > 0) {
                    const rem = st.read_len - off;
                    if (rem > 0) std.mem.copyForwards(u8, st.read_buf[0..rem], st.read_buf[off..st.read_len]);
                    st.read_len = rem;
                    // Touch on successful request processing
                    st.touch();
                }

                // Flush writes
                if (st.write_list.items.len > st.write_off) {
                    const written = posix.write(fd, st.write_list.items[st.write_off..]) catch blk: {
                        should_close = true;
                        break :blk 0;
                    };
                    st.write_off += written;
                    if (st.write_off >= st.write_list.items.len) {
                        st.write_list.clearRetainingCapacity();
                        st.write_off = 0;
                    } else {
                        var mev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET, .data = .{ .fd = fd } };
                        posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &mev) catch {};
                    }
                }

                if (should_close and st.write_off >= st.write_list.items.len) {
                    closeConn(&pool, &conns, epfd, fd, uidx);
                    continue;
                }
            }

            if (ev.events & linux.EPOLL.OUT != 0) {
                if (conns[uidx]) |s| {
                    if (s.write_list.items.len > s.write_off) {
                        const w = posix.write(fd, s.write_list.items[s.write_off..]) catch {
                            closeConn(&pool, &conns, epfd, fd, uidx);
                            continue;
                        };
                        s.write_off += w;
                    }
                    if (s.write_off >= s.write_list.items.len) {
                        s.write_list.clearRetainingCapacity();
                        s.write_off = 0;
                        var mev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = fd } };
                        posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &mev) catch {};
                    }
                }
            }

            if (ev.events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
                closeConn(&pool, &conns, epfd, fd, uidx);
            }
        }
    }
}

fn acceptLoop(pool: *ConnPool, sock: i32, epfd: i32, conns: *[MAX_CONNS]?*ConnState, track_time: bool) void {
    while (true) {
        var caddr: posix.sockaddr = undefined;
        var clen: posix.socklen_t = @sizeOf(posix.sockaddr);
        const cfd = posix.accept(sock, &caddr, &clen, SOCK_NONBLOCK) catch break;
        const cfd_i: i32 = @intCast(cfd);
        setSockOptInt(cfd_i, IPPROTO_TCP, TCP_NODELAY, 1);

        const uidx: usize = @intCast(cfd);
        if (uidx >= MAX_CONNS) {
            posix.close(cfd);
            continue;
        }

        const st = pool.acquire() orelse {
            posix.close(cfd);
            continue;
        };
        st.fd = cfd_i;
        if (track_time) st.touch();
        conns[uidx] = st;

        var cev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = cfd_i } };
        posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, cfd_i, &cev) catch {
            pool.release(st);
            conns[uidx] = null;
            posix.close(cfd);
        };
    }
}

fn closeConn(pool: *ConnPool, conns: *[MAX_CONNS]?*ConnState, epfd: i32, fd: i32, uidx: usize) void {
    posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null) catch {};
    if (conns[uidx]) |s| {
        pool.release(s);
        conns[uidx] = null;
    }
    posix.close(fd);
}

/// Sweep idle connections that exceed the keep-alive timeout.
fn sweepIdleConns(pool: *ConnPool, conns: *[MAX_CONNS]?*ConnState, epfd: i32, timeout: i64) void {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return;
    const now = ts.sec;
    const cutoff = now - timeout;

    for (0..MAX_CONNS) |i| {
        if (conns[i]) |st| {
            if (st.last_active > 0 and st.last_active < cutoff) {
                const fd: i32 = @intCast(i);
                closeConn(pool, conns, epfd, fd, i);
            }
        }
    }
}

// ── timerfd helpers ─────────────────────────────────────────────────

const TFD_CLOEXEC = 0o2000000;
const TFD_NONBLOCK = 0o4000;

fn timerfdCreate() ?i32 {
    // timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC)
    const fd = linux.syscall2(.timerfd_create, 1, TFD_NONBLOCK | TFD_CLOEXEC);
    const signed: i64 = @bitCast(fd);
    if (signed < 0) return null;
    return @intCast(signed);
}

const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

const Itimerspec = extern struct {
    interval: Timespec,
    value: Timespec,
};

fn timerfdSetInterval(fd: i32, seconds: i64) void {
    const spec = Itimerspec{
        .interval = .{ .sec = seconds, .nsec = 0 },
        .value = .{ .sec = seconds, .nsec = 0 },
    };
    // timerfd_settime(fd, 0, &spec, null)
    _ = linux.syscall4(.timerfd_settime, @as(usize, @intCast(fd)), 0, @intFromPtr(&spec), 0);
}

fn setSockOptInt(fd: i32, level: i32, optname: u32, val: c_int) void {
    const v = mem.toBytes(val);
    posix.setsockopt(fd, level, optname, &v) catch {};
}
