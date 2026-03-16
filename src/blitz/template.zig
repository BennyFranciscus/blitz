// Template Engine — Mustache-like zero-allocation templates
//
// Syntax:
//   {{ name }}           — variable substitution (HTML-escaped)
//   {{{ name }}}         — raw variable (no escaping)
//   {{# if cond }}...{{/ if }}          — conditional block
//   {{# unless cond }}...{{/ unless }}  — negated conditional
//   {{# each items }}...{{/ each }}     — iteration (use {{ . }} for current item)
//   {{! comment }}       — comment (stripped from output)
//
// Usage:
//   const page = blitz.Template.compile(
//       \\<h1>{{ title }}</h1>
//       \\<p>Hello {{ name }}!</p>
//   );
//   var buf: [4096]u8 = undefined;
//   const html = page.render(&buf, .{ .title = "Home", .name = "Alice" });
//   // html = "<h1>Home</h1>\n<p>Hello Alice!</p>\n"

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// HTML-escape a string into buf at pos, return new pos or null on overflow
fn htmlEscapeInto(buf: []u8, start: usize, s: []const u8) ?usize {
    var pos = start;
    for (s) |ch| {
        switch (ch) {
            '&' => {
                if (pos + 5 > buf.len) return null;
                @memcpy(buf[pos .. pos + 5], "&amp;");
                pos += 5;
            },
            '<' => {
                if (pos + 4 > buf.len) return null;
                @memcpy(buf[pos .. pos + 4], "&lt;");
                pos += 4;
            },
            '>' => {
                if (pos + 4 > buf.len) return null;
                @memcpy(buf[pos .. pos + 4], "&gt;");
                pos += 4;
            },
            '"' => {
                if (pos + 6 > buf.len) return null;
                @memcpy(buf[pos .. pos + 6], "&quot;");
                pos += 6;
            },
            '\'' => {
                if (pos + 5 > buf.len) return null;
                @memcpy(buf[pos .. pos + 5], "&#39;");
                pos += 5;
            },
            else => {
                if (pos >= buf.len) return null;
                buf[pos] = ch;
                pos += 1;
            },
        }
    }
    return pos;
}

/// Check if a value is "truthy"
fn checkTruthy(val: anytype) bool {
    const T = @TypeOf(val);
    const info = @typeInfo(T);
    return switch (info) {
        .bool => val,
        .optional => if (val) |v| checkTruthy(v) else false,
        .pointer => |ptr| switch (ptr.size) {
            .slice => val.len > 0,
            .one => {
                const child = @typeInfo(ptr.child);
                if (child == .array and child.array.child == u8) {
                    return @as([]const u8, val).len > 0;
                }
                return true;
            },
            else => true,
        },
        .int, .comptime_int => val != 0,
        .array => |arr| if (arr.child == u8) arr.len > 0 else true,
        else => true,
    };
}

/// Coerce a value to a string slice
fn coerceToString(val: anytype) ?[]const u8 {
    const T = @TypeOf(val);
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) val else null,
            .one => {
                // Pointer to array (e.g., *const [11:0]u8 from string literal)
                const child = @typeInfo(ptr.child);
                if (child == .array and child.array.child == u8) {
                    return @as([]const u8, val);
                }
                return null;
            },
            else => null,
        },
        .optional => if (val) |v| coerceToString(v) else null,
        .array => |arr| if (arr.child == u8) @as([]const u8, &val) else null,
        else => null,
    };
}

// ── Comptime helpers ────────────────────────────────────────────────

fn ct_indexOf(s: []const u8, start: usize, needle: []const u8) ?usize {
    if (start + needle.len > s.len) return null;
    var i = start;
    while (i + needle.len <= s.len) : (i += 1) {
        if (ct_eql(s[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn ct_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn ct_trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}

fn ct_startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return ct_eql(s[0..prefix.len], prefix);
}

// ── Comptime operation types ────────────────────────────────────────

const OpKind = enum {
    literal,
    variable, // HTML-escaped
    raw_variable,
    if_start,
    unless_start,
    each_start,
    section_end,
    comment,
};

const Op = struct {
    kind: OpKind,
    text: []const u8, // literal text or variable/section name
};

/// Count the number of ops in a template source (comptime)
fn countOps(comptime source: []const u8) usize {
    comptime {
        var count: usize = 0;
        var pos: usize = 0;
        while (pos < source.len) {
            if (ct_indexOf(source, pos, "{{")) |tag_start| {
                if (tag_start > pos) count += 1;
                if (tag_start + 2 < source.len and source[tag_start + 2] == '{') {
                    const cs = tag_start + 3;
                    if (ct_indexOf(source, cs, "}}}")) |close| {
                        count += 1;
                        pos = close + 3;
                    } else {
                        count += 1;
                        pos = tag_start + 3;
                    }
                    continue;
                }
                const cs = tag_start + 2;
                if (ct_indexOf(source, cs, "}}")) |close| {
                    count += 1;
                    pos = close + 2;
                } else {
                    count += 1;
                    pos = tag_start + 2;
                }
            } else {
                count += 1;
                break;
            }
        }
        return count;
    }
}

/// Parse template source into a comptime fixed-size array of ops
fn parseOps(comptime source: []const u8) [countOps(source)]Op {
    comptime {
        const N = countOps(source);
        var ops: [N]Op = undefined;
        var count: usize = 0;
        var pos: usize = 0;

        while (pos < source.len) {
            if (ct_indexOf(source, pos, "{{")) |tag_start| {
                if (tag_start > pos) {
                    ops[count] = .{ .kind = .literal, .text = source[pos..tag_start] };
                    count += 1;
                }

                if (tag_start + 2 < source.len and source[tag_start + 2] == '{') {
                    const cs = tag_start + 3;
                    if (ct_indexOf(source, cs, "}}}")) |close| {
                        ops[count] = .{ .kind = .raw_variable, .text = ct_trim(source[cs..close]) };
                        count += 1;
                        pos = close + 3;
                    } else {
                        ops[count] = .{ .kind = .literal, .text = source[tag_start .. tag_start + 3] };
                        count += 1;
                        pos = tag_start + 3;
                    }
                    continue;
                }

                const cs = tag_start + 2;
                if (ct_indexOf(source, cs, "}}")) |close| {
                    const content = ct_trim(source[cs..close]);

                    if (content.len > 0 and content[0] == '!') {
                        ops[count] = .{ .kind = .comment, .text = ct_trim(content[1..]) };
                        count += 1;
                    } else if (content.len > 1 and content[0] == '#') {
                        const rest = ct_trim(content[1..]);
                        if (ct_startsWith(rest, "if ")) {
                            ops[count] = .{ .kind = .if_start, .text = ct_trim(rest[3..]) };
                            count += 1;
                        } else if (ct_startsWith(rest, "unless ")) {
                            ops[count] = .{ .kind = .unless_start, .text = ct_trim(rest[7..]) };
                            count += 1;
                        } else if (ct_startsWith(rest, "each ")) {
                            ops[count] = .{ .kind = .each_start, .text = ct_trim(rest[5..]) };
                            count += 1;
                        } else {
                            ops[count] = .{ .kind = .if_start, .text = rest };
                            count += 1;
                        }
                    } else if (content.len > 1 and content[0] == '/') {
                        ops[count] = .{ .kind = .section_end, .text = ct_trim(content[1..]) };
                        count += 1;
                    } else {
                        ops[count] = .{ .kind = .variable, .text = content };
                        count += 1;
                    }
                    pos = close + 2;
                } else {
                    ops[count] = .{ .kind = .literal, .text = source[tag_start .. tag_start + 2] };
                    count += 1;
                    pos = tag_start + 2;
                }
            } else {
                ops[count] = .{ .kind = .literal, .text = source[pos..] };
                count += 1;
                break;
            }
        }
        return ops;
    }
}

/// Find the matching section end index, handling nesting
fn ct_findSectionEnd(comptime ops: anytype, comptime start: usize) usize {
    comptime {
        var depth: usize = 1;
        var idx = start + 1;
        while (idx < ops.len) : (idx += 1) {
            switch (ops[idx].kind) {
                .if_start, .unless_start, .each_start => depth += 1,
                .section_end => {
                    depth -= 1;
                    if (depth == 0) return idx;
                },
                else => {},
            }
        }
        @compileError("unmatched section in template");
    }
}

/// Generate a render function for a slice of ops (recursive for sections)
fn RenderSlice(comptime ops: anytype) type {
    return struct {
        pub fn render(buf: []u8, pos_in: usize, data: anytype) ?usize {
            var pos = pos_in;

            comptime var i = 0;
            inline while (i < ops.len) {
                const op = ops[i];
                switch (op.kind) {
                    .literal => {
                        if (pos + op.text.len > buf.len) return null;
                        @memcpy(buf[pos .. pos + op.text.len], op.text);
                        pos += op.text.len;
                        i += 1;
                    },
                    .variable => {
                        if (comptime ct_eql(op.text, ".")) {
                            // Current item in each loop — data should be string
                            if (coerceToString(data)) |val| {
                                pos = htmlEscapeInto(buf, pos, val) orelse return null;
                            }
                        } else {
                            if (@hasField(@TypeOf(data), op.text)) {
                                if (coerceToString(@field(data, op.text))) |val| {
                                    pos = htmlEscapeInto(buf, pos, val) orelse return null;
                                }
                            }
                        }
                        i += 1;
                    },
                    .raw_variable => {
                        if (comptime ct_eql(op.text, ".")) {
                            if (coerceToString(data)) |val| {
                                if (pos + val.len > buf.len) return null;
                                @memcpy(buf[pos .. pos + val.len], val);
                                pos += val.len;
                            }
                        } else {
                            if (@hasField(@TypeOf(data), op.text)) {
                                if (coerceToString(@field(data, op.text))) |val| {
                                    if (pos + val.len > buf.len) return null;
                                    @memcpy(buf[pos .. pos + val.len], val);
                                    pos += val.len;
                                }
                            }
                        }
                        i += 1;
                    },
                    .if_start => {
                        const end_idx = comptime ct_findSectionEnd(ops, i);
                        const body_ops = ops[i + 1 .. end_idx];
                        if (@hasField(@TypeOf(data), op.text)) {
                            if (checkTruthy(@field(data, op.text))) {
                                pos = RenderSlice(body_ops).render(buf, pos, data) orelse return null;
                            }
                        }
                        i = end_idx + 1;
                    },
                    .unless_start => {
                        const end_idx = comptime ct_findSectionEnd(ops, i);
                        const body_ops = ops[i + 1 .. end_idx];
                        if (@hasField(@TypeOf(data), op.text)) {
                            if (!checkTruthy(@field(data, op.text))) {
                                pos = RenderSlice(body_ops).render(buf, pos, data) orelse return null;
                            }
                        } else {
                            // Missing field is falsy, so unless renders
                            pos = RenderSlice(body_ops).render(buf, pos, data) orelse return null;
                        }
                        i = end_idx + 1;
                    },
                    .each_start => {
                        const end_idx = comptime ct_findSectionEnd(ops, i);
                        const body_ops = ops[i + 1 .. end_idx];
                        if (@hasField(@TypeOf(data), op.text)) {
                            const arr = @field(data, op.text);
                            for (arr) |item| {
                                // Render body with item as context for "."
                                // For "." references, pass the item string
                                pos = RenderSliceWithItem(body_ops).render(buf, pos, data, item) orelse return null;
                            }
                        }
                        i = end_idx + 1;
                    },
                    .section_end => {
                        i += 1;
                    },
                    .comment => {
                        i += 1;
                    },
                }
            }
            return pos;
        }
    };
}

/// Render function for inside each loops — has access to current item via "."
fn RenderSliceWithItem(comptime ops: anytype) type {
    return struct {
        pub fn render(buf: []u8, pos_in: usize, data: anytype, item: anytype) ?usize {
            var pos = pos_in;

            comptime var i = 0;
            inline while (i < ops.len) {
                const op = ops[i];
                switch (op.kind) {
                    .literal => {
                        if (pos + op.text.len > buf.len) return null;
                        @memcpy(buf[pos .. pos + op.text.len], op.text);
                        pos += op.text.len;
                        i += 1;
                    },
                    .variable => {
                        if (comptime ct_eql(op.text, ".")) {
                            if (coerceToString(item)) |val| {
                                pos = htmlEscapeInto(buf, pos, val) orelse return null;
                            }
                        } else {
                            if (@hasField(@TypeOf(data), op.text)) {
                                if (coerceToString(@field(data, op.text))) |val| {
                                    pos = htmlEscapeInto(buf, pos, val) orelse return null;
                                }
                            }
                        }
                        i += 1;
                    },
                    .raw_variable => {
                        if (comptime ct_eql(op.text, ".")) {
                            if (coerceToString(item)) |val| {
                                if (pos + val.len > buf.len) return null;
                                @memcpy(buf[pos .. pos + val.len], val);
                                pos += val.len;
                            }
                        } else {
                            if (@hasField(@TypeOf(data), op.text)) {
                                if (coerceToString(@field(data, op.text))) |val| {
                                    if (pos + val.len > buf.len) return null;
                                    @memcpy(buf[pos .. pos + val.len], val);
                                    pos += val.len;
                                }
                            }
                        }
                        i += 1;
                    },
                    .if_start, .unless_start, .each_start => {
                        const end_idx = comptime ct_findSectionEnd(ops, i);
                        // Nested sections in each loops — just skip for simplicity
                        i = end_idx + 1;
                    },
                    .section_end => {
                        i += 1;
                    },
                    .comment => {
                        i += 1;
                    },
                }
            }
            return pos;
        }
    };
}

// ── Public API ──────────────────────────────────────────────────────

/// Comptime template compilation — returns a struct with a specialized render function
pub const Template = struct {
    /// Compile a template at comptime and return a renderer
    /// Usage:
    ///   const page = Template.compile("<h1>{{ title }}</h1>");
    ///   const html = page.render(&buf, .{ .title = "Hello" });
    pub fn compile(comptime source: []const u8) type {
        const ops = comptime parseOps(source);
        return struct {
            const all_ops = ops;
            /// Render the template with the given struct data into a buffer.
            /// Returns the rendered slice, or null on buffer overflow.
            pub fn render(buf: []u8, data: anytype) ?[]const u8 {
                const final_pos = RenderSlice(&all_ops).render(buf, 0, data) orelse return null;
                return buf[0..final_pos];
            }
        };
    }
};

// ── Runtime template (non-comptime, uses string map) ────────────────

const SegmentKind = enum {
    literal,
    variable,
    raw_variable,
    if_start,
    unless_start,
    each_start,
    section_end,
    comment,
};

const Segment = struct {
    kind: SegmentKind,
    text: []const u8,
};

/// Parse a template at runtime (allocates segment array)
pub fn parseRuntime(alloc: std.mem.Allocator, source: []const u8) !RuntimeTemplate {
    var segments = std.ArrayList(Segment).init(alloc);
    var pos: usize = 0;

    while (pos < source.len) {
        if (mem.indexOf(u8, source[pos..], "{{")) |rel_start| {
            const tag_start = pos + rel_start;
            if (tag_start > pos) {
                try segments.append(.{ .kind = .literal, .text = source[pos..tag_start] });
            }

            // Raw variable {{{ }}}
            if (tag_start + 2 < source.len and source[tag_start + 2] == '{') {
                const cs = tag_start + 3;
                if (mem.indexOf(u8, source[cs..], "}}}")) |rc| {
                    try segments.append(.{ .kind = .raw_variable, .text = mem.trim(u8, source[cs .. cs + rc], " \t") });
                    pos = cs + rc + 3;
                } else {
                    try segments.append(.{ .kind = .literal, .text = source[tag_start .. tag_start + 3] });
                    pos = tag_start + 3;
                }
                continue;
            }

            const cs = tag_start + 2;
            if (mem.indexOf(u8, source[cs..], "}}")) |rc| {
                const close = cs + rc;
                const content = mem.trim(u8, source[cs..close], " \t");

                if (content.len > 0 and content[0] == '!') {
                    try segments.append(.{ .kind = .comment, .text = mem.trim(u8, content[1..], " \t") });
                } else if (content.len > 1 and content[0] == '#') {
                    const rest = mem.trim(u8, content[1..], " \t");
                    if (mem.startsWith(u8, rest, "if ")) {
                        try segments.append(.{ .kind = .if_start, .text = mem.trim(u8, rest[3..], " \t") });
                    } else if (mem.startsWith(u8, rest, "unless ")) {
                        try segments.append(.{ .kind = .unless_start, .text = mem.trim(u8, rest[7..], " \t") });
                    } else if (mem.startsWith(u8, rest, "each ")) {
                        try segments.append(.{ .kind = .each_start, .text = mem.trim(u8, rest[5..], " \t") });
                    } else {
                        try segments.append(.{ .kind = .if_start, .text = rest });
                    }
                } else if (content.len > 1 and content[0] == '/') {
                    try segments.append(.{ .kind = .section_end, .text = mem.trim(u8, content[1..], " \t") });
                } else {
                    try segments.append(.{ .kind = .variable, .text = content });
                }
                pos = close + 2;
            } else {
                try segments.append(.{ .kind = .literal, .text = source[tag_start .. tag_start + 2] });
                pos = tag_start + 2;
            }
        } else {
            try segments.append(.{ .kind = .literal, .text = source[pos..] });
            break;
        }
    }

    return RuntimeTemplate{
        .segments = try segments.toOwnedSlice(),
        .alloc = alloc,
    };
}

/// Runtime-parsed template with string-map rendering
pub const RuntimeTemplate = struct {
    segments: []Segment,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *RuntimeTemplate) void {
        self.alloc.free(self.segments);
    }

    /// Render using a struct as key-value map (field names → string values)
    pub fn renderMap(self: RuntimeTemplate, buf: []u8, values: anytype) ?[]const u8 {
        var pos: usize = 0;
        var seg_idx: usize = 0;

        while (seg_idx < self.segments.len) {
            const seg = self.segments[seg_idx];
            switch (seg.kind) {
                .literal => {
                    if (pos + seg.text.len > buf.len) return null;
                    @memcpy(buf[pos .. pos + seg.text.len], seg.text);
                    pos += seg.text.len;
                    seg_idx += 1;
                },
                .variable => {
                    if (rtMapGet(values, seg.text)) |val| {
                        pos = htmlEscapeInto(buf, pos, val) orelse return null;
                    }
                    seg_idx += 1;
                },
                .raw_variable => {
                    if (rtMapGet(values, seg.text)) |val| {
                        if (pos + val.len > buf.len) return null;
                        @memcpy(buf[pos .. pos + val.len], val);
                        pos += val.len;
                    }
                    seg_idx += 1;
                },
                .if_start => {
                    const val = rtMapGet(values, seg.text);
                    if (val != null and val.?.len > 0) {
                        seg_idx += 1;
                    } else {
                        seg_idx = rtSkipSection(self.segments, seg_idx) orelse return null;
                    }
                },
                .unless_start => {
                    const val = rtMapGet(values, seg.text);
                    if (val == null or val.?.len == 0) {
                        seg_idx += 1;
                    } else {
                        seg_idx = rtSkipSection(self.segments, seg_idx) orelse return null;
                    }
                },
                .each_start => {
                    seg_idx = rtSkipSection(self.segments, seg_idx) orelse return null;
                },
                .section_end => seg_idx += 1,
                .comment => seg_idx += 1,
            }
        }
        return buf[0..pos];
    }
};

fn rtSkipSection(segments: []const Segment, start: usize) ?usize {
    var depth: usize = 1;
    var idx = start + 1;
    while (idx < segments.len) {
        switch (segments[idx].kind) {
            .if_start, .unless_start, .each_start => depth += 1,
            .section_end => {
                depth -= 1;
                if (depth == 0) return idx + 1;
            },
            else => {},
        }
        idx += 1;
    }
    return null;
}

/// Look up a field in a struct by runtime string name
fn rtMapGet(map: anytype, key: []const u8) ?[]const u8 {
    const T = @TypeOf(map);
    const info = @typeInfo(T);
    if (info == .@"struct") {
        inline for (info.@"struct".fields) |field| {
            if (mem.eql(u8, field.name, key)) {
                return coerceToString(@field(map, field.name));
            }
        }
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "simple variable substitution" {
    const Page = Template.compile("Hello {{ name }}!");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{ .name = "World" });
    try testing.expectEqualStrings("Hello World!", result.?);
}

test "multiple variables" {
    const Page = Template.compile("{{ greeting }}, {{ name }}! Welcome to {{ place }}.");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{
        .greeting = "Hello",
        .name = "Alice",
        .place = "Blitz",
    });
    try testing.expectEqualStrings("Hello, Alice! Welcome to Blitz.", result.?);
}

test "HTML escaping" {
    const Page = Template.compile("{{ content }}");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{ .content = "<script>alert('xss')</script>" });
    try testing.expectEqualStrings("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;", result.?);
}

test "raw variable no escaping" {
    const Page = Template.compile("{{{ html }}}");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{ .html = "<b>bold</b>" });
    try testing.expectEqualStrings("<b>bold</b>", result.?);
}

test "if section truthy" {
    const Page = Template.compile("{{# if logged_in }}Welcome back!{{/ if }}");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{ .logged_in = true });
    try testing.expectEqualStrings("Welcome back!", result.?);
}

test "if section falsy" {
    const Page = Template.compile("{{# if logged_in }}Welcome back!{{/ if }}");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{ .logged_in = false });
    try testing.expectEqualStrings("", result.?);
}

test "unless section" {
    const Page = Template.compile("{{# unless has_error }}All good!{{/ unless }}");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{ .has_error = false });
    try testing.expectEqualStrings("All good!", result.?);
}

test "unless section truthy" {
    const Page = Template.compile("{{# unless has_error }}All good!{{/ unless }}");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{ .has_error = true });
    try testing.expectEqualStrings("", result.?);
}

test "each loop" {
    const Page = Template.compile("<ul>{{# each items }}<li>{{ . }}</li>{{/ each }}</ul>");
    var buf: [256]u8 = undefined;
    const items = [_][]const u8{ "apple", "banana", "cherry" };
    const result = Page.render(&buf, .{ .items = @as([]const []const u8, &items) });
    try testing.expectEqualStrings("<ul><li>apple</li><li>banana</li><li>cherry</li></ul>", result.?);
}

test "comment stripped" {
    const Page = Template.compile("Hello{{! this is a comment }} World");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{});
    try testing.expectEqualStrings("Hello World", result.?);
}

test "mixed template" {
    const Page = Template.compile(
        \\<head><title>{{ title }}</title></head>
        \\{{# if show_header }}<h1>{{ title }}</h1>{{/ if }}
        \\<p>Hello {{ name }}!</p>
    );
    var buf: [1024]u8 = undefined;
    const result = Page.render(&buf, .{
        .title = "My Page",
        .show_header = true,
        .name = "Alice",
    });
    try testing.expect(result != null);
    try testing.expect(mem.indexOf(u8, result.?, "<h1>My Page</h1>") != null);
    try testing.expect(mem.indexOf(u8, result.?, "Hello Alice!") != null);
}

test "buffer overflow returns null" {
    const Page = Template.compile("Hello {{ name }}! This is a longer template.");
    var buf: [5]u8 = undefined;
    const result = Page.render(&buf, .{ .name = "World" });
    try testing.expect(result == null);
}

test "if section with string" {
    const Page = Template.compile("{{# if name }}Hi {{ name }}!{{/ if }}");
    var buf: [256]u8 = undefined;
    // Non-empty string is truthy
    const result1 = Page.render(&buf, .{ .name = "Bob" });
    try testing.expectEqualStrings("Hi Bob!", result1.?);
    // Empty string is falsy
    const result2 = Page.render(&buf, .{ .name = "" });
    try testing.expectEqualStrings("", result2.?);
}

test "nested sections" {
    const Page = Template.compile("{{# if a }}A{{# if b }}B{{/ if }}{{/ if }}");
    var buf: [256]u8 = undefined;
    const result1 = Page.render(&buf, .{ .a = true, .b = true });
    try testing.expectEqualStrings("AB", result1.?);
    const result2 = Page.render(&buf, .{ .a = true, .b = false });
    try testing.expectEqualStrings("A", result2.?);
    const result3 = Page.render(&buf, .{ .a = false, .b = true });
    try testing.expectEqualStrings("", result3.?);
}

test "special chars in escaping" {
    const Page = Template.compile("{{ text }}");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{ .text = "a&b<c>d\"e'f" });
    try testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&#39;f", result.?);
}

test "literal only template" {
    const Page = Template.compile("No variables here");
    var buf: [256]u8 = undefined;
    const result = Page.render(&buf, .{});
    try testing.expectEqualStrings("No variables here", result.?);
}

test "runtime template parse and render" {
    const alloc = testing.allocator;
    var tmpl = try parseRuntime(alloc, "Hello {{ name }}!");
    defer tmpl.deinit();
    var buf: [256]u8 = undefined;
    const result = tmpl.renderMap(&buf, .{ .name = "World" });
    try testing.expectEqualStrings("Hello World!", result.?);
}

test "runtime template conditionals" {
    const alloc = testing.allocator;
    var tmpl = try parseRuntime(alloc, "{{# if show }}Visible{{/ if }}");
    defer tmpl.deinit();
    var buf: [256]u8 = undefined;
    const result = tmpl.renderMap(&buf, .{ .show = "yes" });
    try testing.expectEqualStrings("Visible", result.?);
}

test "each loop with escaping" {
    const Page = Template.compile("{{# each items }}[{{ . }}]{{/ each }}");
    var buf: [256]u8 = undefined;
    const items = [_][]const u8{ "a&b", "<c>" };
    const result = Page.render(&buf, .{ .items = @as([]const []const u8, &items) });
    try testing.expectEqualStrings("[a&amp;b][&lt;c&gt;]", result.?);
}

test "each loop raw" {
    const Page = Template.compile("{{# each items }}{{{ . }}}|{{/ each }}");
    var buf: [256]u8 = undefined;
    const items = [_][]const u8{ "<b>", "&" };
    const result = Page.render(&buf, .{ .items = @as([]const []const u8, &items) });
    try testing.expectEqualStrings("<b>|&|", result.?);
}
