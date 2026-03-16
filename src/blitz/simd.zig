const std = @import("std");

// ── SIMD-accelerated byte scanning for HTTP parsing ─────────────────
// Uses @Vector for portable SIMD across SSE2/AVX2/NEON.
// Falls back to scalar for short inputs or when alignment doesn't matter.

/// Find the position of "\r\n\r\n" (header terminator) in data.
/// Returns the index of the first '\r' of the terminator, or null if not found.
/// This is the primary hot path in HTTP parsing — called on every request.
pub fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;

    // For short inputs, scalar is faster (no vector setup overhead)
    if (data.len < 32) {
        return findHeaderEndScalar(data);
    }

    // SIMD: scan 16 bytes at a time looking for '\r' bytes
    // When found, check if it's the start of "\r\n\r\n"
    const V = @Vector(16, u8);
    const cr_vec: V = @splat('\r');

    var i: usize = 0;
    const end = data.len -| 3; // safe limit for 4-byte check

    // Process 16-byte chunks
    while (i + 16 <= end) {
        const chunk: V = data[i..][0..16].*;
        const matches = chunk == cr_vec;
        var mask = @as(u16, @bitCast(matches));

        while (mask != 0) {
            const bit: u5 = @ctz(mask);
            const pos = i + @as(usize, bit);
            if (pos + 3 < data.len and
                data[pos + 1] == '\n' and
                data[pos + 2] == '\r' and
                data[pos + 3] == '\n')
            {
                return pos;
            }
            mask &= mask - 1; // clear lowest set bit
        }
        i += 16;
    }

    // Scalar tail
    while (i < end) {
        if (data[i] == '\r' and
            i + 3 < data.len and
            data[i + 1] == '\n' and
            data[i + 2] == '\r' and
            data[i + 3] == '\n')
        {
            return i;
        }
        i += 1;
    }

    return null;
}

/// Find the position of "\r\n" (line terminator) in data.
/// Returns the index of the '\r', or null if not found.
/// Used for request line parsing and header line scanning.
pub fn findCRLF(data: []const u8) ?usize {
    if (data.len < 2) return null;

    if (data.len < 32) {
        return findCRLFScalar(data);
    }

    const V = @Vector(16, u8);
    const cr_vec: V = @splat('\r');

    var i: usize = 0;
    const end = data.len -| 1;

    while (i + 16 <= end) {
        const chunk: V = data[i..][0..16].*;
        const matches = chunk == cr_vec;
        var mask = @as(u16, @bitCast(matches));

        while (mask != 0) {
            const bit: u5 = @ctz(mask);
            const pos = i + @as(usize, bit);
            if (pos + 1 < data.len and data[pos + 1] == '\n') {
                return pos;
            }
            mask &= mask - 1;
        }
        i += 16;
    }

    // Scalar tail
    while (i < end) {
        if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') {
            return i;
        }
        i += 1;
    }

    return null;
}

/// Find the position of a single byte in data (like memchr).
/// SIMD-accelerated for longer inputs.
pub fn findByte(data: []const u8, needle: u8) ?usize {
    if (data.len < 32) {
        return std.mem.indexOfScalar(u8, data, needle);
    }

    const V = @Vector(16, u8);
    const needle_vec: V = @splat(needle);

    var i: usize = 0;

    while (i + 16 <= data.len) {
        const chunk: V = data[i..][0..16].*;
        const matches = chunk == needle_vec;
        const mask = @as(u16, @bitCast(matches));

        if (mask != 0) {
            return i + @as(usize, @ctz(mask));
        }
        i += 16;
    }

    // Scalar tail
    while (i < data.len) {
        if (data[i] == needle) return i;
        i += 1;
    }

    return null;
}

// ── Scalar fallbacks ────────────────────────────────────────────────

fn findHeaderEndScalar(data: []const u8) ?usize {
    if (data.len < 4) return null;
    var i: usize = 0;
    const end = data.len - 3;
    while (i < end) : (i += 1) {
        if (data[i] == '\r' and
            data[i + 1] == '\n' and
            data[i + 2] == '\r' and
            data[i + 3] == '\n')
        {
            return i;
        }
    }
    return null;
}

fn findCRLFScalar(data: []const u8) ?usize {
    if (data.len < 2) return null;
    var i: usize = 0;
    const end = data.len - 1;
    while (i < end) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n') {
            return i;
        }
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "findHeaderEnd basic" {
    const data = "GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    const pos = findHeaderEnd(data).?;
    try std.testing.expectEqual(@as(usize, 23), pos);
    try std.testing.expectEqualStrings("\r\n\r\n", data[pos .. pos + 4]);
}

test "findHeaderEnd not found" {
    try std.testing.expectEqual(@as(?usize, null), findHeaderEnd("GET / HTTP/1.1\r\nHost: a\r\n"));
    try std.testing.expectEqual(@as(?usize, null), findHeaderEnd("short"));
    try std.testing.expectEqual(@as(?usize, null), findHeaderEnd(""));
}

test "findHeaderEnd long input" {
    // Force SIMD path with >32 bytes
    var buf: [256]u8 = undefined;
    @memset(&buf, 'X');
    buf[200] = '\r';
    buf[201] = '\n';
    buf[202] = '\r';
    buf[203] = '\n';
    try std.testing.expectEqual(@as(usize, 200), findHeaderEnd(&buf).?);
}

test "findHeaderEnd at start" {
    try std.testing.expectEqual(@as(usize, 0), findHeaderEnd("\r\n\r\nrest").?);
}

test "findHeaderEnd multiple CRs" {
    const data = "Header1: val\r\nHeader2: val\r\n\r\nbody";
    const pos = findHeaderEnd(data).?;
    try std.testing.expectEqual(@as(usize, 27), pos);
}

test "findCRLF basic" {
    try std.testing.expectEqual(@as(usize, 14), findCRLF("GET / HTTP/1.1\r\nHost").?);
}

test "findCRLF long" {
    var buf: [128]u8 = undefined;
    @memset(&buf, 'A');
    buf[100] = '\r';
    buf[101] = '\n';
    try std.testing.expectEqual(@as(usize, 100), findCRLF(&buf).?);
}

test "findByte basic" {
    try std.testing.expectEqual(@as(usize, 3), findByte("abc:def", ':').?);
    try std.testing.expectEqual(@as(?usize, null), findByte("abcdef", ':'));
}

test "findByte long" {
    var buf: [128]u8 = undefined;
    @memset(&buf, 'A');
    buf[80] = 'Z';
    try std.testing.expectEqual(@as(usize, 80), findByte(&buf, 'Z').?);
}
