const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const Method = types.Method;
const Request = types.Request;
const Headers = types.Headers;

// ── HTTP/1.1 Request Parser ─────────────────────────────────────────
// Zero-copy: all slices point into the original buffer.
// Supports pipelined requests (returns total_len consumed).

pub const ParseResult = struct {
    request: Request,
    total_len: usize,
};

pub fn parse(data: []const u8) ?ParseResult {
    // Find header end
    const hdr_end = mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    const hdr = data[0..hdr_end];

    // Request line
    const req_end = mem.indexOf(u8, hdr, "\r\n") orelse return null;
    const req_line = hdr[0..req_end];

    const sp1 = mem.indexOfScalar(u8, req_line, ' ') orelse return null;
    const method_str = req_line[0..sp1];
    const method = Method.fromString(method_str) orelse return null;

    const rest = req_line[sp1 + 1 ..];
    const sp2 = mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const uri = rest[0..sp2];

    var path = uri;
    var query: ?[]const u8 = null;
    if (mem.indexOfScalar(u8, uri, '?')) |qp| {
        path = uri[0..qp];
        query = uri[qp + 1 ..];
    }

    // Parse headers — manual loop for performance (avoids iterator overhead)
    var headers = Headers{};
    var content_length: ?usize = null;
    var chunked = false;

    {
        const hdr_data = hdr[req_end + 2 ..];
        var pos2: usize = 0;
        while (pos2 < hdr_data.len) {
            const remaining = hdr_data[pos2..];
            const line_end_opt = mem.indexOf(u8, remaining, "\r\n");
            const line_end = line_end_opt orelse remaining.len;
            if (line_end == 0) {
                pos2 += 2;
                continue;
            }
            const line = remaining[0..line_end];
            pos2 += line_end + (if (line_end_opt != null) @as(usize, 2) else line_end);

            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = mem.trimLeft(u8, line[colon + 1 ..], " ");

            headers.append(name, value);

            // Check Content-Length (fast first-char check)
            if (name.len == 14 and (name[0] == 'C' or name[0] == 'c') and types.asciiEqlIgnoreCase(name, "Content-Length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch null;
            }
            // Check Transfer-Encoding
            else if (name.len == 17 and (name[0] == 'T' or name[0] == 't') and types.asciiEqlIgnoreCase(name, "Transfer-Encoding")) {
                if (value.len >= 7 and types.asciiEqlIgnoreCase(value[0..7], "chunked")) {
                    chunked = true;
                }
            }
        }
    }

    const body_start = hdr_end + 4;

    if (chunked) {
        const remaining = data[body_start..];
        if (mem.indexOf(u8, remaining, "0\r\n\r\n")) |end_pos| {
            const total = body_start + end_pos + 5;
            if (total > data.len) return null;
            const chunk_body = parseFirstChunk(remaining[0..end_pos]);
            return .{
                .request = .{
                    .method = method,
                    .path = path,
                    .query = query,
                    .headers = headers,
                    .body = chunk_body,
                    .content_length = content_length,
                    .raw_header = hdr,
                },
                .total_len = total,
            };
        }
        if (mem.indexOf(u8, remaining, "\r\n0\r\n")) |end_pos| {
            const total = body_start + end_pos + 5;
            if (total > data.len) return null;
            const chunk_body = parseFirstChunk(remaining[0..end_pos]);
            return .{
                .request = .{
                    .method = method,
                    .path = path,
                    .query = query,
                    .headers = headers,
                    .body = chunk_body,
                    .content_length = content_length,
                    .raw_header = hdr,
                },
                .total_len = total,
            };
        }
        return null;
    }

    if (content_length) |cl| {
        if (data.len < body_start + cl) return null;
        return .{
            .request = .{
                .method = method,
                .path = path,
                .query = query,
                .headers = headers,
                .body = data[body_start .. body_start + cl],
                .content_length = content_length,
                .raw_header = hdr,
            },
            .total_len = body_start + cl,
        };
    }

    return .{
        .request = .{
            .method = method,
            .path = path,
            .query = query,
            .headers = headers,
            .body = null,
            .content_length = content_length,
            .raw_header = hdr,
        },
        .total_len = body_start,
    };
}

/// Parse only headers — returns request with body=null and header_len set.
/// Used for body discard mode where we don't need to buffer the body.
/// Returns null if headers aren't complete yet.
pub const HeaderResult = struct {
    request: Request,
    header_len: usize, // bytes consumed by headers (up to and including \r\n\r\n)
    content_length: ?usize,
};

pub fn parseHeaders(data: []const u8) ?HeaderResult {
    const hdr_end = mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    // Include the final \r\n of the last header so the line scanner can find it
    const hdr = data[0 .. hdr_end + 2];

    const req_end = mem.indexOf(u8, hdr, "\r\n") orelse return null;
    const req_line = hdr[0..req_end];

    const sp1 = mem.indexOfScalar(u8, req_line, ' ') orelse return null;
    const method_str = req_line[0..sp1];
    const method = Method.fromString(method_str) orelse return null;

    const rest = req_line[sp1 + 1 ..];
    const sp2 = mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const uri = rest[0..sp2];

    var path = uri;
    var query: ?[]const u8 = null;
    if (mem.indexOfScalar(u8, uri, '?')) |qp| {
        path = uri[0..qp];
        query = uri[qp + 1 ..];
    }

    var headers = Headers{};
    var content_length: ?usize = null;
    var pos: usize = req_end + 2;
    while (pos < hdr_end + 2) {
        const line_end = mem.indexOf(u8, hdr[pos..], "\r\n") orelse break;
        const line = hdr[pos .. pos + line_end];
        pos += line_end + 2;

        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = mem.trimLeft(u8, line[colon + 1 ..], " ");
        headers.set(name, value);

        if (name.len == 14 and types.asciiEqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }

    return .{
        .request = .{
            .method = method,
            .path = path,
            .query = query,
            .headers = headers,
            .body = null,
            .content_length = content_length,
            .raw_header = hdr,
        },
        .header_len = hdr_end + 4,
        .content_length = content_length,
    };
}

fn parseFirstChunk(data: []const u8) ?[]const u8 {
    const crlf = mem.indexOf(u8, data, "\r\n") orelse return null;
    const size = std.fmt.parseInt(usize, data[0..crlf], 16) catch return null;
    if (size == 0) return "";
    const start = crlf + 2;
    if (data.len < start + size) return null;
    return data[start .. start + size];
}
