const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const Thread = std.Thread;
const IoUring = linux.IoUring;
const BufferGroup = IoUring.BufferGroup;

const types = @import("types.zig");
const parser = @import("parser.zig");
const Router = @import("router.zig").Router;
const compress_mod = @import("compress.zig");
const log_mod = @import("log.zig");
const Request = types.Request;
const Response = types.Response;

// ── Constants ───────────────────────────────────────────────────────
const MAX_CONNS: usize = 65536;
const RING_ENTRIES: u16 = 4096;
const CQE_BATCH: usize = 256;
const RECV_BUF_SIZE: u32 = 4096;
const RECV_BUF_COUNT: u16 = 4096; // must be power of 2
const SEND_BUF_SIZE: usize = 16384;
const BUFFER_GROUP_ID: u16 = 0;
const COMPRESS_BUF_SIZE: usize = 131072; // 128KB

// Socket constants
const SOCK_STREAM: u32 = linux.SOCK.STREAM;
const SOCK_NONBLOCK: u32 = linux.SOCK.NONBLOCK;
const AF_INET: u32 = linux.AF.INET;
const SOL_SOCKET: i32 = 1;
const SO_REUSEPORT: u32 = 15;
const SO_REUSEADDR: u32 = 2;
const IPPROTO_TCP: i32 = 6;
const TCP_NODELAY: u32 = 1;
const MSG_NOSIGNAL: u32 = 0x4000;

// io_uring setup flags (may not be in Zig 0.14 std)
const IORING_SETUP_SINGLE_ISSUER: u32 = 1 << 12; // 5.18+
const IORING_SETUP_DEFER_TASKRUN: u32 = 1 << 13; // 6.1+

// CQE flags
const IORING_CQE_F_MORE: u32 = 1 << 1;
const IORING_CQE_F_NOTIF: u32 = linux.IORING_CQE_F_NOTIF; // 1 << 3, zero-copy send notification

// Registered file descriptor flag
const IOSQE_FIXED_FILE: u8 = linux.IOSQE_FIXED_FILE;

// ── User data encoding ─────────────────────────────────────────────
// Pack operation type (upper 8 bits) + fd (lower 24 bits) into u64
const Op = enum(u8) {
    accept = 1,
    recv = 2,
    send = 3,
    cancel = 4,
    close = 5,
};

fn packUserData(op: Op, fd: i32) u64 {
    return (@as(u64, @intFromEnum(op)) << 56) | @as(u64, @intCast(@as(u32, @bitCast(fd))));
}

fn unpackOp(ud: u64) Op {
    return @enumFromInt(@as(u8, @truncate(ud >> 56)));
}

fn unpackFd(ud: u64) i32 {
    return @bitCast(@as(u32, @truncate(ud)));
}

// ── Connection state ────────────────────────────────────────────────
const ConnState = struct {
    // Accumulated partial request data (when a single recv buffer doesn't have a complete request)
    read_buf: [65536]u8 = undefined,
    read_len: usize = 0,

    // Write buffer for responses
    write_buf: std.ArrayList(u8),

    // Send state
    write_off: usize = 0,
    send_inflight: bool = false,
    zc_notif_pending: bool = false, // true while waiting for send_zc notification CQE

    // Dynamic read buffer for large request bodies (e.g. uploads)
    dyn_buf: ?[]u8 = null,
    dyn_len: usize = 0,
    dyn_alloc: ?std.mem.Allocator = null,

    fn init(alloc: std.mem.Allocator) ConnState {
        return .{
            .write_buf = std.ArrayList(u8).init(alloc),
        };
    }

    /// Promote from static buffer to dynamic heap buffer of given size.
    fn promoteToDynamic(self: *ConnState, a: std.mem.Allocator, needed: usize) bool {
        const buf = a.alloc(u8, needed) catch return false;
        if (self.read_len > 0) {
            @memcpy(buf[0..self.read_len], self.read_buf[0..self.read_len]);
        }
        self.dyn_buf = buf;
        self.dyn_len = self.read_len;
        self.dyn_alloc = a;
        return true;
    }

    /// Free dynamic buffer and revert to static.
    fn revertToStatic(self: *ConnState) void {
        if (self.dyn_buf) |buf| {
            if (self.dyn_alloc) |a| {
                a.free(buf);
            }
        }
        self.dyn_buf = null;
        self.dyn_len = 0;
        self.dyn_alloc = null;
        self.read_len = 0;
    }

    /// Get the active read slice.
    fn readSlice(self: *ConnState) []const u8 {
        if (self.dyn_buf) |buf| return buf[0..self.dyn_len];
        return self.read_buf[0..self.read_len];
    }

    /// Get remaining writable portion of active buffer.
    fn readBufRemaining(self: *ConnState) ?[]u8 {
        if (self.dyn_buf) |buf| {
            if (self.dyn_len >= buf.len) return null;
            return buf[self.dyn_len..];
        }
        if (self.read_len >= 65536) return null;
        return self.read_buf[self.read_len..];
    }

    /// Advance read position after successful read.
    fn advanceRead(self: *ConnState, n: usize) void {
        if (self.dyn_buf != null) {
            self.dyn_len += n;
        } else {
            self.read_len += n;
        }
    }

    /// Get active read length.
    fn activeReadLen(self: *ConnState) usize {
        if (self.dyn_buf != null) return self.dyn_len;
        return self.read_len;
    }

    fn reset(self: *ConnState) void {
        self.revertToStatic();
        self.write_buf.clearRetainingCapacity();
        self.write_off = 0;
        self.send_inflight = false;
        self.zc_notif_pending = false;
    }

    fn deinit(self: *ConnState) void {
        self.revertToStatic();
        self.write_buf.deinit();
    }
};

// ── Connection Pool for io_uring ─────────────────────────────────────
// Pre-allocated pool of ConnState objects to avoid malloc/free per connection.
// Uses a stack-based free list for O(1) acquire/release.
const URING_POOL_SIZE: usize = 4096;

const UringConnPool = struct {
    slots: []ConnState,
    free_stack: []u16, // indices into slots
    free_count: usize,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) ?UringConnPool {
        const slots = alloc.alloc(ConnState, URING_POOL_SIZE) catch return null;
        const stack = alloc.alloc(u16, URING_POOL_SIZE) catch {
            alloc.free(slots);
            return null;
        };
        // Initialize free stack: all slots available (reverse order so 0 is popped first)
        for (0..URING_POOL_SIZE) |i| {
            stack[i] = @intCast(URING_POOL_SIZE - 1 - i);
        }
        // Initialize all ConnState write_buf ArrayLists
        for (slots) |*s| {
            s.* = ConnState.init(alloc);
        }
        return .{
            .slots = slots,
            .free_stack = stack,
            .free_count = URING_POOL_SIZE,
            .alloc = alloc,
        };
    }

    fn acquire(self: *UringConnPool) ?*ConnState {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const idx = self.free_stack[self.free_count];
        const st = &self.slots[idx];
        st.reset();
        return st;
    }

    fn release(self: *UringConnPool, st: *ConnState) void {
        // Calculate index from pointer arithmetic
        const base = @intFromPtr(self.slots.ptr);
        const ptr = @intFromPtr(st);
        const stride = @sizeOf(ConnState);
        const idx = (ptr - base) / stride;
        if (idx < URING_POOL_SIZE and self.free_count < URING_POOL_SIZE) {
            self.free_stack[self.free_count] = @intCast(idx);
            self.free_count += 1;
        }
    }

    fn isPooled(self: *UringConnPool, st: *ConnState) bool {
        const base = @intFromPtr(self.slots.ptr);
        const ptr = @intFromPtr(st);
        return ptr >= base and ptr < base + @sizeOf(ConnState) * URING_POOL_SIZE;
    }

    fn deinit(self: *UringConnPool) void {
        for (self.slots) |*s| {
            s.deinit();
        }
        self.alloc.free(self.slots);
        self.alloc.free(self.free_stack);
    }
};

// ── Server Configuration ────────────────────────────────────────────
pub const Config = struct {
    port: u16 = 8080,
    threads: ?usize = null,
    compression: bool = true,
    shutdown_timeout: u32 = 30,
    logging: log_mod.LogConfig = .{},
};

// ── Shared shutdown state ───────────────────────────────────────────
var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn isShuttingDown() bool {
    return shutdown_flag.load(.acquire);
}

// ── Signal handling (self-pipe trick, same as epoll server) ─────────
var signal_pipe: [2]i32 = .{ -1, -1 };

fn signalHandler(_: c_int) callconv(.C) void {
    const buf = [_]u8{1};
    _ = posix.write(signal_pipe[1], &buf) catch {};
}

const libc = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("signal.h");
});

fn installSignalHandlers() void {
    const pipe_result = linux.syscall2(.pipe2, @intFromPtr(&signal_pipe), 0o4000 | 0o2000000);
    const pipe_signed: i64 = @bitCast(pipe_result);
    if (pipe_signed < 0) return;

    var act: libc.struct_sigaction = std.mem.zeroes(libc.struct_sigaction);
    act.__sigaction_handler = .{ .sa_handler = signalHandler };
    act.sa_flags = libc.SA_RESTART;
    _ = libc.sigaction(libc.SIGTERM, &act, null);
    _ = libc.sigaction(libc.SIGINT, &act, null);
}

// ── Server ──────────────────────────────────────────────────────────
pub const UringServer = struct {
    router: *Router,
    config: Config,

    pub fn init(router: *Router, config: Config) UringServer {
        return .{ .router = router, .config = config };
    }

    pub fn listen(self: *UringServer) !void {
        installSignalHandlers();

        const n_threads = self.config.threads orelse @max(Thread.getCpuCount() catch 1, 1);

        var threads = std.ArrayList(Thread).init(std.heap.c_allocator);
        defer threads.deinit();

        for (1..n_threads) |_| {
            const t = try Thread.spawn(.{}, workerThread, .{ self.router, self.config, false });
            try threads.append(t);
        }

        workerThread(self.router, self.config, true);

        for (threads.items) |t| {
            t.join();
        }
    }
};

fn workerThread(router: *Router, config: Config, is_primary: bool) void {
    const alloc = std.heap.c_allocator;
    const compression_enabled = config.compression;
    const log_config = config.logging;
    const logging = log_config.enabled;

    // Create listening socket with SO_REUSEPORT
    const sock: i32 = @intCast(posix.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0) catch return);
    defer posix.close(sock);

    setSockOptInt(sock, SOL_SOCKET, SO_REUSEPORT, 1);
    setSockOptInt(sock, SOL_SOCKET, SO_REUSEADDR, 1);
    setSockOptInt(sock, IPPROTO_TCP, TCP_NODELAY, 1);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, config.port);
    posix.bind(sock, &address.any, address.getOsSockLen()) catch return;
    posix.listen(sock, 4096) catch return;

    // Initialize io_uring with SINGLE_ISSUER + DEFER_TASKRUN
    var params = mem.zeroInit(linux.io_uring_params, .{
        .flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN,
        .sq_thread_idle = 1000,
    });

    var ring = IoUring.init_params(RING_ENTRIES, &params) catch blk: {
        // Fallback: try without DEFER_TASKRUN (requires kernel 6.1+)
        var params2 = mem.zeroInit(linux.io_uring_params, .{
            .flags = IORING_SETUP_SINGLE_ISSUER,
            .sq_thread_idle = 1000,
        });
        break :blk IoUring.init_params(RING_ENTRIES, &params2) catch blk2: {
            // Fallback: no special flags
            break :blk2 IoUring.init(RING_ENTRIES, 0) catch return;
        };
    };
    defer ring.deinit();

    // Try to register sparse file descriptor table for direct I/O
    // This avoids per-IO fd table lookup overhead (atomic refcount on struct file)
    // Falls back to regular fds on older kernels (< 5.19)
    const use_direct_fds = blk: {
        ring.register_files_sparse(@intCast(MAX_CONNS)) catch break :blk false;
        break :blk true;
    };

    // send_zc (zero-copy send) — probe on first send, fallback to regular send if kernel < 6.0
    // State: 0 = untested, 1 = supported, 2 = unsupported
    var send_zc_state: u8 = 0;

    // Allocate recv buffer slab for BufferGroup
    const slab_size: usize = @as(usize, RECV_BUF_COUNT) * @as(usize, RECV_BUF_SIZE);
    const slab = alloc.alloc(u8, slab_size) catch return;
    defer alloc.free(slab);

    // Initialize kernel-managed buffer ring (replaces provide_buffers)
    // BufferGroup uses shared memory — buffer return is zero-SQE (just a memory write)
    var buf_group = BufferGroup.init(
        &ring,
        BUFFER_GROUP_ID,
        slab,
        RECV_BUF_SIZE,
        RECV_BUF_COUNT,
    ) catch return;
    defer buf_group.deinit();

    // Connection state array (sparse, indexed by fd or file index)
    var conns: [MAX_CONNS]?*ConnState = undefined;
    @memset(&conns, null);

    // Connection pool — pre-allocated ConnState objects for O(1) acquire/release
    var pool_opt = UringConnPool.init(alloc);
    defer {
        if (pool_opt) |*p| p.deinit();
    }

    // Arm multishot accept (direct or regular depending on kernel support)
    if (use_direct_fds) {
        armMultishotAcceptDirect(&ring, sock) catch return;
    } else {
        armMultishotAccept(&ring, sock) catch return;
    }
    _ = ring.submit() catch return;

    // Monitor signal pipe on primary thread
    if (is_primary and signal_pipe[0] >= 0) {
        // Use poll_add for signal pipe (regular fd, not registered)
        _ = ring.poll_add(
            packUserData(.cancel, signal_pipe[0]),
            signal_pipe[0],
            linux.POLL.IN,
        ) catch {};
        _ = ring.submit() catch {};
    }

    // Main event loop
    var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;

    while (!shutdown_flag.load(.acquire)) {
        const count = ring.copy_cqes(&cqes, 1) catch |err| {
            if (err == error.SignalInterrupt) continue;
            break;
        };
        if (count == 0) continue;

        var compress_buf: [COMPRESS_BUF_SIZE]u8 = undefined;
        var needs_submit = false;

        for (cqes[0..count]) |cqe| {
            const ud = cqe.user_data;
            if (ud == 0) continue; // internal completion
            const op = unpackOp(ud);
            const fd = unpackFd(ud);
            const res = cqe.res;

            switch (op) {
                .accept => {
                    if (res >= 0) {
                        // res is either a real fd (regular) or file index (direct)
                        const conn_idx: usize = @intCast(@as(u32, @bitCast(@as(i32, res))));

                        // Set TCP_NODELAY only for regular fds (direct fds don't expose real fd)
                        if (!use_direct_fds) {
                            setSockOptInt(res, IPPROTO_TCP, TCP_NODELAY, 1);
                        }

                        if (conn_idx < MAX_CONNS) {
                            // Try pool first, fall back to heap allocation
                            const from_pool = if (pool_opt) |*p| p.acquire() else null;
                            const st: *ConnState = from_pool orelse alloc.create(ConnState) catch {
                                if (use_direct_fds) {
                                    _ = ring.close_direct(packUserData(.close, @as(i32, res)), @intCast(@as(u32, @bitCast(@as(i32, res))))) catch {};
                                    needs_submit = true;
                                } else {
                                    posix.close(@intCast(@as(u32, @bitCast(@as(i32, res)))));
                                }
                                continue;
                            };
                            // Only init if heap-allocated (pool slots are pre-initialized and reset on acquire)
                            if (from_pool == null) {
                                st.* = ConnState.init(alloc);
                            }
                            conns[conn_idx] = st;

                            // Arm multishot recv using buffer group
                            const recv_sqe = buf_group.recv_multishot(
                                packUserData(.recv, @as(i32, res)),
                                @as(i32, res),
                                0,
                            ) catch {
                                if (pool_opt) |*p| {
                                    if (p.isPooled(st)) { p.release(st); } else { st.deinit(); alloc.destroy(st); }
                                } else { st.deinit(); alloc.destroy(st); }
                                conns[conn_idx] = null;
                                if (use_direct_fds) {
                                    _ = ring.close_direct(packUserData(.close, @as(i32, res)), @intCast(@as(u32, @bitCast(@as(i32, res))))) catch {};
                                    needs_submit = true;
                                } else {
                                    posix.close(@intCast(@as(u32, @bitCast(@as(i32, res)))));
                                }
                                continue;
                            };

                            // Set IOSQE_FIXED_FILE for direct fd mode
                            if (use_direct_fds) {
                                recv_sqe.flags |= IOSQE_FIXED_FILE;
                            }

                            needs_submit = true;
                        } else {
                            if (use_direct_fds) {
                                _ = ring.close_direct(packUserData(.close, @as(i32, res)), @intCast(@as(u32, @bitCast(@as(i32, res))))) catch {};
                                needs_submit = true;
                            } else {
                                posix.close(@intCast(@as(u32, @bitCast(@as(i32, res)))));
                            }
                        }
                    }

                    // Re-arm multishot accept if kernel dropped it
                    if (cqe.flags & IORING_CQE_F_MORE == 0) {
                        if (use_direct_fds) {
                            armMultishotAcceptDirect(&ring, sock) catch {};
                        } else {
                            armMultishotAccept(&ring, sock) catch {};
                        }
                        needs_submit = true;
                    }
                },

                .recv => {
                    const has_more = (cqe.flags & IORING_CQE_F_MORE) != 0;

                    if (res <= 0) {
                        // Connection closed or error — return buffer if present
                        if (cqe.buffer_id()) |_| {
                            buf_group.put_cqe(cqe) catch {};
                        } else |_| {}
                        const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
                        if (uidx < MAX_CONNS) {
                            if (conns[uidx]) |st| {
                                if (pool_opt) |*p| {
                                    if (p.isPooled(st)) { p.release(st); } else { st.deinit(); alloc.destroy(st); }
                                } else { st.deinit(); alloc.destroy(st); }
                                conns[uidx] = null;
                            }
                            if (use_direct_fds) {
                                _ = ring.close_direct(packUserData(.close, fd), @intCast(@as(u32, @bitCast(fd)))) catch {};
                                needs_submit = true;
                            } else {
                                posix.close(@intCast(@as(u32, @bitCast(fd))));
                            }
                        }
                        continue;
                    }

                    // Get recv data from buffer group
                    const recv_data = buf_group.get_cqe(cqe) catch continue;

                    const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
                    if (uidx < MAX_CONNS) {
                        if (conns[uidx]) |st| {
                            // Copy recv data into active buffer (static or dynamic)
                            if (st.dyn_buf) |dbuf| {
                                const space = dbuf.len - st.dyn_len;
                                const copy_len = @min(recv_data.len, space);
                                @memcpy(dbuf[st.dyn_len..][0..copy_len], recv_data[0..copy_len]);
                                st.dyn_len += copy_len;
                            } else {
                                const space = st.read_buf.len - st.read_len;
                                const copy_len = @min(recv_data.len, space);
                                @memcpy(st.read_buf[st.read_len..][0..copy_len], recv_data[0..copy_len]);
                                st.read_len += copy_len;
                            }

                            // Return buffer to kernel ASAP (zero-SQE — just a memory write!)
                            buf_group.put_cqe(cqe) catch {};

                            // Parse and handle pipelined requests
                            var off: usize = 0;
                            var close_after_write = false;
                            const cur_len = st.activeReadLen();
                            const cur_data = st.readSlice();
                            while (off < cur_len) {
                                const result = parser.parse(cur_data[off..cur_len]) orelse {
                                    // If headers are complete but parse failed, check for large body
                                    const remaining = cur_data[off..cur_len];
                                    if (mem.indexOf(u8, remaining, "\r\n\r\n")) |hdr_end| {
                                        // Check if large body needs promotion
                                        const cl = detectContentLength(remaining[0 .. hdr_end + 4]);
                                        if (cl != null and cl.? > 65536 and st.dyn_buf == null) {
                                            const total_needed = hdr_end + 4 + cl.?;
                                            _ = st.promoteToDynamic(alloc, total_needed);
                                            // Wait for next recv CQE to deliver more body data
                                            break;
                                        }
                                        // If dynamic buffer active but body still incomplete, wait
                                        if (st.dyn_buf != null) {
                                            break;
                                        }
                                        // Genuinely bad request — send 400
                                        const bad_resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Request";
                                        st.write_buf.appendSlice(bad_resp) catch {};
                                        off += hdr_end + 4;
                                        close_after_write = true;
                                        break;
                                    }
                                    break;
                                };
                                var req = result.request;
                                var resp = Response{};

                                if (shutdown_flag.load(.acquire)) {
                                    resp.headers.set("Connection", "close");
                                }

                                const req_start = if (logging) log_mod.now() else 0;

                                router.handle(&req, &resp);

                                if (compression_enabled) {
                                    _ = compress_mod.compressResponse(&compress_buf, &req, &resp);
                                }

                                if (logging) {
                                    log_mod.logRequest(log_config, &req, &resp, req_start);
                                }

                                resp.writeTo(&st.write_buf);
                                off += result.total_len;
                            }

                            // Compact read buffer
                            if (off > 0) {
                                if (st.dyn_buf != null) {
                                    // Done with large body — revert to static buffer
                                    const rem = st.dyn_len - off;
                                    if (rem > 0 and rem <= 65536) {
                                        @memcpy(st.read_buf[0..rem], st.dyn_buf.?[off..st.dyn_len]);
                                    }
                                    st.revertToStatic();
                                    st.read_len = if (rem <= 65536) rem else 0;
                                } else {
                                    const rem = st.read_len - off;
                                    if (rem > 0) std.mem.copyForwards(u8, st.read_buf[0..rem], st.read_buf[off..st.read_len]);
                                    st.read_len = rem;
                                }
                            }

                            // Submit send if we have data and no send in flight
                            if (st.write_buf.items.len > st.write_off and !st.send_inflight) {
                                const send_data = st.write_buf.items[st.write_off..];
                                if (send_zc_state != 2) {
                                    // Try zero-copy send (probe on first attempt)
                                    armSendZcEx(&ring, fd, send_data, use_direct_fds) catch {
                                        // send_zc SQE prep failed — fall back to regular send
                                        armSendEx(&ring, fd, send_data, use_direct_fds) catch {};
                                    };
                                } else {
                                    armSendEx(&ring, fd, send_data, use_direct_fds) catch {};
                                }
                                st.send_inflight = true;
                                needs_submit = true;
                            }
                        } else {
                            // No ConnState — still need to return buffer
                            buf_group.put_cqe(cqe) catch {};
                        }
                    } else {
                        // fd out of range — return buffer
                        buf_group.put_cqe(cqe) catch {};
                    }

                    // Re-arm recv if multishot was dropped
                    if (!has_more) {
                        if (uidx < MAX_CONNS and conns[uidx] != null) {
                            const re_recv_sqe = buf_group.recv_multishot(
                                packUserData(.recv, fd),
                                fd,
                                0,
                            ) catch continue;
                            if (use_direct_fds) {
                                re_recv_sqe.flags |= IOSQE_FIXED_FILE;
                            }
                            needs_submit = true;
                        }
                    }
                },

                .send => {
                    const uidx: usize = @intCast(@as(u32, @bitCast(fd)));
                    if (uidx >= MAX_CONNS) continue;
                    const st = conns[uidx] orelse continue;

                    // Handle send_zc notification CQE — buffer is now safe to reuse
                    if (cqe.flags & IORING_CQE_F_NOTIF != 0) {
                        st.zc_notif_pending = false;
                        // Now safe to reuse write buffer
                        if (!st.send_inflight) {
                            st.write_buf.clearRetainingCapacity();
                            st.write_off = 0;

                            if (shutdown_flag.load(.acquire)) {
                                if (pool_opt) |*p| {
                                    if (p.isPooled(st)) { p.release(st); } else { st.deinit(); alloc.destroy(st); }
                                } else { st.deinit(); alloc.destroy(st); }
                                conns[uidx] = null;
                                if (use_direct_fds) {
                                    _ = ring.close_direct(packUserData(.close, fd), @intCast(@as(u32, @bitCast(fd)))) catch {};
                                    needs_submit = true;
                                } else {
                                    posix.close(@intCast(@as(u32, @bitCast(fd))));
                                }
                            }
                        }
                        continue;
                    }

                    if (res <= 0) {
                        // Send error — check if it's send_zc not supported (-EINVAL/-ENOSYS)
                        if (send_zc_state == 0 and (res == -22 or res == -38)) {
                            // send_zc not supported by kernel — mark and retry with regular send
                            send_zc_state = 2;
                            armSendEx(&ring, fd, st.write_buf.items[st.write_off..], use_direct_fds) catch {
                                st.send_inflight = false;
                            };
                            needs_submit = true;
                            continue;
                        }
                        // Real send error — close connection
                        if (pool_opt) |*p| {
                            if (p.isPooled(st)) { p.release(st); } else { st.deinit(); alloc.destroy(st); }
                        } else { st.deinit(); alloc.destroy(st); }
                        conns[uidx] = null;
                        if (use_direct_fds) {
                            _ = ring.close_direct(packUserData(.close, fd), @intCast(@as(u32, @bitCast(fd)))) catch {};
                            needs_submit = true;
                        } else {
                            posix.close(@intCast(@as(u32, @bitCast(fd))));
                        }
                        continue;
                    }

                    // Successful send — mark send_zc as supported if probing
                    if (send_zc_state == 0 and (cqe.flags & IORING_CQE_F_MORE) != 0) {
                        send_zc_state = 1; // send_zc confirmed working
                    }

                    // Check if send_zc notification will follow (IORING_CQE_F_MORE set)
                    const zc_notif_coming = (cqe.flags & IORING_CQE_F_MORE) != 0;
                    if (zc_notif_coming) {
                        st.zc_notif_pending = true;
                    }

                    st.write_off += @as(usize, @intCast(res));

                    if (st.write_off < st.write_buf.items.len) {
                        // Partial send — resubmit remainder
                        // For partial sends, use regular send to avoid complex buffer lifetime tracking
                        armSendEx(&ring, fd, st.write_buf.items[st.write_off..], use_direct_fds) catch {
                            st.send_inflight = false;
                        };
                        needs_submit = true;
                    } else {
                        // Send complete
                        st.send_inflight = false;

                        if (!st.zc_notif_pending) {
                            // No notification pending — safe to reuse buffer now
                            st.write_buf.clearRetainingCapacity();
                            st.write_off = 0;

                            if (shutdown_flag.load(.acquire)) {
                                if (pool_opt) |*p| {
                                    if (p.isPooled(st)) { p.release(st); } else { st.deinit(); alloc.destroy(st); }
                                } else { st.deinit(); alloc.destroy(st); }
                                conns[uidx] = null;
                                if (use_direct_fds) {
                                    _ = ring.close_direct(packUserData(.close, fd), @intCast(@as(u32, @bitCast(fd)))) catch {};
                                    needs_submit = true;
                                } else {
                                    posix.close(@intCast(@as(u32, @bitCast(fd))));
                                }
                            }
                        }
                        // If zc_notif_pending, buffer cleanup deferred to notification handler above
                    }
                },

                .close => {
                    // close_direct completion — fd slot is now free in the registered table
                    // Nothing to do; the kernel has already freed the slot
                },

                .cancel => {
                    // Signal pipe readable or cancel completion — check for shutdown
                    if (is_primary and fd == signal_pipe[0]) {
                        var sig_buf: [16]u8 = undefined;
                        _ = posix.read(signal_pipe[0], &sig_buf) catch {};
                        shutdown_flag.store(true, .release);
                    }
                },
            }
        }

        if (needs_submit) {
            _ = ring.submit() catch {};
        }
    }

    // Cleanup: close all connections
    for (0..MAX_CONNS) |i| {
        if (conns[i]) |st| {
            if (pool_opt) |*p| {
                if (p.isPooled(st)) { p.release(st); } else { st.deinit(); alloc.destroy(st); }
            } else { st.deinit(); alloc.destroy(st); }
            conns[i] = null;
            if (use_direct_fds) {
                _ = ring.close_direct(packUserData(.close, @as(i32, @intCast(i))), @intCast(i)) catch {};
            } else {
                posix.close(@intCast(i));
            }
        }
    }
    // Submit any pending close_direct operations during cleanup
    if (use_direct_fds) {
        _ = ring.submit() catch {};
    }
    // Unregister file table (ring deinit will handle this too, but be explicit)
    if (use_direct_fds) {
        ring.unregister_files() catch {};
    }
}

// ── SQE helpers ─────────────────────────────────────────────────────

fn armMultishotAccept(ring: *IoUring, sock: i32) !void {
    _ = try ring.accept_multishot(
        packUserData(.accept, sock),
        sock,
        null,
        null,
        SOCK_NONBLOCK,
    );
}

fn armMultishotAcceptDirect(ring: *IoUring, sock: i32) !void {
    _ = try ring.accept_multishot_direct(
        packUserData(.accept, sock),
        sock,
        null,
        null,
        SOCK_NONBLOCK,
    );
}

fn armSendEx(ring: *IoUring, fd: i32, data: []const u8, fixed_file: bool) !void {
    const sqe = try ring.send(
        packUserData(.send, fd),
        fd,
        data,
        MSG_NOSIGNAL,
    );
    if (fixed_file) {
        sqe.flags |= IOSQE_FIXED_FILE;
    }
}

fn armSendZcEx(ring: *IoUring, fd: i32, data: []const u8, fixed_file: bool) !void {
    const sqe = try ring.send_zc(
        packUserData(.send, fd),
        fd,
        data,
        MSG_NOSIGNAL,
        0, // zc_flags — no IORING_SEND_ZC_REPORT_USAGE needed
    );
    if (fixed_file) {
        sqe.flags |= IOSQE_FIXED_FILE;
    }
}

fn setSockOptInt(fd: i32, level: i32, optname: u32, val: c_int) void {
    const v = mem.toBytes(val);
    posix.setsockopt(fd, level, optname, &v) catch {};
}

/// Scan raw header bytes for a Content-Length value.
fn detectContentLength(headers: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < headers.len) {
        const line_end = mem.indexOf(u8, headers[pos..], "\r\n") orelse headers.len - pos;
        const line = headers[pos .. pos + line_end];
        if (line.len > 16) {
            const colon = mem.indexOfScalar(u8, line, ':') orelse {
                pos += line_end + 2;
                continue;
            };
            const name = line[0..colon];
            if (name.len == 14 and types.asciiEqlIgnoreCase(name, "Content-Length")) {
                const value = mem.trimLeft(u8, line[colon + 1 ..], " ");
                return std.fmt.parseInt(usize, value, 10) catch null;
            }
        }
        pos += line_end + 2;
    }
    return null;
}
