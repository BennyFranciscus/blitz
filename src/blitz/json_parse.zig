const std = @import("std");
const mem = std.mem;

// ── JSON Parser ─────────────────────────────────────────────────────
// Comptime-powered zero-allocation JSON deserialization.
// Parses JSON strings directly into Zig structs using @typeInfo.
// Strings are zero-copy slices into the original JSON input.
//
// Usage:
//   const User = struct { name: []const u8, age: i64, active: bool };
//   if (JsonParser.parse(User, json_body)) |user| {
//       // user.name, user.age, user.active are set
//   }
//
// Features:
//   - Struct fields mapped from JSON object keys
//   - Optional fields: missing keys → null
//   - Unknown JSON keys silently skipped
//   - Nested structs and arrays supported
//   - Zero-copy strings (slices into input)
//   - Escaped strings: unescaped into caller buffer via parseAlloc
//
// Limitations:
//   - Fixed-size arrays for JSON arrays (max 32 elements)
//   - No streaming — entire JSON must be in memory
//   - f64 parsing uses std.fmt.parseFloat

pub const JsonParser = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) JsonParser {
        return .{ .input = input, .pos = 0 };
    }

    /// Parse a JSON string into a comptime-known Zig type.
    /// Returns null on parse error.
    pub fn parse(comptime T: type, input: []const u8) ?T {
        resetArena();
        var p = JsonParser.init(input);
        const result = p.parseValue(T) orelse return null;
        p.skipWhitespace();
        // Must consume entire input (no trailing garbage)
        if (p.pos != p.input.len) return null;
        return result;
    }

    /// Parse without requiring full consumption (for embedded JSON).
    pub fn parsePartial(comptime T: type, input: []const u8) ?T {
        resetArena();
        var p = JsonParser.init(input);
        return p.parseValue(T);
    }

    // ── Core dispatcher ─────────────────────────────────────────────

    fn parseValue(self: *JsonParser, comptime T: type) ?T {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return null;

        const info = @typeInfo(T);

        return switch (info) {
            .bool => self.parseBool(),
            .int => self.parseInt(T),
            .float => self.parseFloat(T),
            .optional => |opt| self.parseOptional(opt.child),
            .pointer => |ptr| blk: {
                if (ptr.size == .slice and ptr.child == u8) {
                    break :blk self.parseString();
                }
                break :blk null; // Other pointer types not supported
            },
            .@"struct" => self.parseStruct(T),
            .@"enum" => self.parseEnum(T),
            else => null,
        };
    }

    // ── Primitives ──────────────────────────────────────────────────

    fn parseBool(self: *JsonParser) ?bool {
        if (self.startsWith("true")) {
            self.pos += 4;
            return true;
        }
        if (self.startsWith("false")) {
            self.pos += 5;
            return false;
        }
        return null;
    }

    fn parseInt(self: *JsonParser, comptime T: type) ?T {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return null;

        // Handle null → 0 for optional-wrapped ints (handled by parseOptional)
        if (self.input[self.pos] == 'n') {
            if (self.startsWith("null")) {
                self.pos += 4;
                return 0;
            }
            return null;
        }

        const start = self.pos;
        // Optional negative sign
        if (self.pos < self.input.len and self.input[self.pos] == '-') {
            self.pos += 1;
        }
        // At least one digit
        if (self.pos >= self.input.len or !isDigit(self.input[self.pos])) {
            self.pos = start;
            return null;
        }
        while (self.pos < self.input.len and isDigit(self.input[self.pos])) {
            self.pos += 1;
        }
        // Skip fractional part if present (truncate float-in-int)
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.input.len and isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
        }
        // Skip exponent if present
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
                self.pos += 1;
            }
            while (self.pos < self.input.len and isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
        }

        const num_str = self.input[start..self.pos];
        // Try direct integer parse first
        return std.fmt.parseInt(T, num_str, 10) catch {
            // Try parsing as float and truncating
            const f = std.fmt.parseFloat(f64, num_str) catch return null;
            if (f < @as(f64, @floatFromInt(std.math.minInt(T))) or
                f > @as(f64, @floatFromInt(std.math.maxInt(T))))
                return null;
            return @intFromFloat(f);
        };
    }

    fn parseFloat(self: *JsonParser, comptime T: type) ?T {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return null;

        if (self.input[self.pos] == 'n') {
            if (self.startsWith("null")) {
                self.pos += 4;
                return 0;
            }
            return null;
        }

        const start = self.pos;
        // Optional negative
        if (self.pos < self.input.len and self.input[self.pos] == '-') {
            self.pos += 1;
        }
        // Digits
        if (self.pos >= self.input.len or !isDigit(self.input[self.pos])) {
            self.pos = start;
            return null;
        }
        while (self.pos < self.input.len and isDigit(self.input[self.pos])) {
            self.pos += 1;
        }
        // Fractional
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.input.len and isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
        }
        // Exponent
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
                self.pos += 1;
            }
            while (self.pos < self.input.len and isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
        }

        return std.fmt.parseFloat(T, self.input[start..self.pos]) catch null;
    }

    fn parseOptional(self: *JsonParser, comptime Child: type) ?(?Child) {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return null;

        if (self.startsWith("null")) {
            self.pos += 4;
            return @as(?Child, null);
        }

        const val = self.parseValue(Child) orelse return null;
        return @as(?Child, val);
    }

    fn parseEnum(self: *JsonParser, comptime T: type) ?T {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return null;

        // Enums can be JSON strings
        if (self.input[self.pos] == '"') {
            const str = self.parseString() orelse return null;
            return std.meta.stringToEnum(T, str);
        }

        // Or JSON integers (enum value)
        if (isDigit(self.input[self.pos]) or self.input[self.pos] == '-') {
            const tag = self.parseInt(std.meta.Tag(T)) orelse return null;
            return std.meta.intToEnum(T, tag) catch null;
        }

        return null;
    }

    // ── Strings ─────────────────────────────────────────────────────

    /// Parse a JSON string. Returns a zero-copy slice if no escapes,
    /// otherwise returns null (use parseStringAlloc for escaped strings).
    fn parseString(self: *JsonParser) ?[]const u8 {
        if (self.pos >= self.input.len or self.input[self.pos] != '"') return null;
        self.pos += 1; // skip opening "

        const start = self.pos;
        var has_escapes = false;

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '"') {
                if (has_escapes) {
                    // Need to unescape — do it in-place scan
                    return self.unescapeString(self.input[start..self.pos]);
                }
                const result = self.input[start..self.pos];
                self.pos += 1; // skip closing "
                return result;
            }
            if (ch == '\\') {
                has_escapes = true;
                self.pos += 1; // skip backslash
                if (self.pos >= self.input.len) return null;
                if (self.input[self.pos] == 'u') {
                    // \uXXXX — skip 4 hex digits
                    self.pos += 1;
                    if (self.pos + 4 > self.input.len) return null;
                    self.pos += 4;
                    continue;
                }
            }
            self.pos += 1;
        }
        return null; // Unterminated string
    }

    /// For strings with escape sequences, we can't do zero-copy.
    /// We use a thread-local bump arena so each escaped string gets its own
    /// region — no use-after-parse when multiple fields contain escapes.
    /// The arena resets at the start of each top-level parse() call.
    threadlocal var unescape_arena: [65536]u8 = undefined;
    threadlocal var arena_pos: usize = 0;

    /// Reset the bump arena — call at the start of each parse.
    fn resetArena() void {
        arena_pos = 0;
    }

    fn unescapeString(self: *JsonParser, raw: []const u8) ?[]const u8 {
        const start_pos = arena_pos;
        var i: usize = 0;

        while (i < raw.len) {
            if (arena_pos >= unescape_arena.len) return null; // overflow

            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                switch (raw[i]) {
                    '"' => {
                        unescape_arena[arena_pos] = '"';
                        arena_pos += 1;
                    },
                    '\\' => {
                        unescape_arena[arena_pos] = '\\';
                        arena_pos += 1;
                    },
                    '/' => {
                        unescape_arena[arena_pos] = '/';
                        arena_pos += 1;
                    },
                    'n' => {
                        unescape_arena[arena_pos] = '\n';
                        arena_pos += 1;
                    },
                    'r' => {
                        unescape_arena[arena_pos] = '\r';
                        arena_pos += 1;
                    },
                    't' => {
                        unescape_arena[arena_pos] = '\t';
                        arena_pos += 1;
                    },
                    'b' => {
                        unescape_arena[arena_pos] = 0x08;
                        arena_pos += 1;
                    },
                    'f' => {
                        unescape_arena[arena_pos] = 0x0C;
                        arena_pos += 1;
                    },
                    'u' => {
                        if (i + 4 >= raw.len) return null;
                        const hex = raw[i + 1 .. i + 5];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return null;
                        i += 4;
                        // Encode as UTF-8
                        if (cp < 0x80) {
                            unescape_arena[arena_pos] = @intCast(cp);
                            arena_pos += 1;
                        } else if (cp < 0x800) {
                            if (arena_pos + 2 > unescape_arena.len) return null;
                            unescape_arena[arena_pos] = @intCast(0xC0 | (cp >> 6));
                            unescape_arena[arena_pos + 1] = @intCast(0x80 | (cp & 0x3F));
                            arena_pos += 2;
                        } else {
                            if (arena_pos + 3 > unescape_arena.len) return null;
                            unescape_arena[arena_pos] = @intCast(0xE0 | (cp >> 12));
                            unescape_arena[arena_pos + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                            unescape_arena[arena_pos + 2] = @intCast(0x80 | (cp & 0x3F));
                            arena_pos += 3;
                        }
                    },
                    else => {
                        // Unknown escape — pass through
                        unescape_arena[arena_pos] = raw[i];
                        arena_pos += 1;
                    },
                }
                i += 1;
            } else {
                unescape_arena[arena_pos] = raw[i];
                arena_pos += 1;
                i += 1;
            }
        }

        self.pos += 1; // skip closing "
        return unescape_arena[start_pos..arena_pos];
    }

    // ── Structs (JSON objects) ──────────────────────────────────────

    fn parseStruct(self: *JsonParser, comptime T: type) ?T {
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '{') return null;
        self.pos += 1; // skip {

        var result: T = undefined;
        const fields = @typeInfo(T).@"struct".fields;

        // Initialize all fields to defaults or undefined
        inline for (fields) |field| {
            if (comptime field.defaultValue()) |default_val| {
                @field(result, field.name) = default_val;
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            }
            // Non-optional fields without defaults remain undefined — must be set by JSON
        }

        self.skipWhitespace();
        if (self.pos < self.input.len and self.input[self.pos] == '}') {
            self.pos += 1;
            return result;
        }

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            // Parse key
            const key = self.parseString() orelse return null;

            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != ':') return null;
            self.pos += 1; // skip :

            // Match key to struct field
            var matched = false;
            inline for (fields) |field| {
                if (mem.eql(u8, key, field.name)) {
                    @field(result, field.name) = self.parseValue(field.type) orelse return null;
                    matched = true;
                }
            }

            // Skip unknown fields
            if (!matched) {
                self.skipValue() orelse return null;
            }

            self.skipWhitespace();
            if (self.pos >= self.input.len) return null;
            if (self.input[self.pos] == '}') {
                self.pos += 1;
                return result;
            }
            if (self.input[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            return null; // Expected , or }
        }

        return null;
    }

    // ── Value skipping (for unknown fields) ─────────────────────────

    fn skipValue(self: *JsonParser) ?void {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return null;

        switch (self.input[self.pos]) {
            '"' => {
                // Skip string
                self.pos += 1;
                while (self.pos < self.input.len) {
                    if (self.input[self.pos] == '\\') {
                        self.pos += 2; // skip escape
                        continue;
                    }
                    if (self.input[self.pos] == '"') {
                        self.pos += 1;
                        return;
                    }
                    self.pos += 1;
                }
                return null;
            },
            '{' => {
                // Skip object
                self.pos += 1;
                var depth: u32 = 1;
                while (self.pos < self.input.len and depth > 0) {
                    switch (self.input[self.pos]) {
                        '{' => depth += 1,
                        '}' => depth -= 1,
                        '"' => {
                            self.pos += 1;
                            while (self.pos < self.input.len) {
                                if (self.input[self.pos] == '\\') {
                                    self.pos += 1;
                                } else if (self.input[self.pos] == '"') break;
                                self.pos += 1;
                            }
                        },
                        else => {},
                    }
                    self.pos += 1;
                }
                return;
            },
            '[' => {
                // Skip array
                self.pos += 1;
                var depth: u32 = 1;
                while (self.pos < self.input.len and depth > 0) {
                    switch (self.input[self.pos]) {
                        '[' => depth += 1,
                        ']' => depth -= 1,
                        '"' => {
                            self.pos += 1;
                            while (self.pos < self.input.len) {
                                if (self.input[self.pos] == '\\') {
                                    self.pos += 1;
                                } else if (self.input[self.pos] == '"') break;
                                self.pos += 1;
                            }
                        },
                        else => {},
                    }
                    self.pos += 1;
                }
                return;
            },
            't' => {
                if (self.startsWith("true")) {
                    self.pos += 4;
                    return;
                }
                return null;
            },
            'f' => {
                if (self.startsWith("false")) {
                    self.pos += 5;
                    return;
                }
                return null;
            },
            'n' => {
                if (self.startsWith("null")) {
                    self.pos += 4;
                    return;
                }
                return null;
            },
            else => |ch| {
                // Number
                if (isDigit(ch) or ch == '-') {
                    while (self.pos < self.input.len) {
                        const c = self.input[self.pos];
                        if (isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E') {
                            self.pos += 1;
                        } else break;
                    }
                    return;
                }
                return null;
            },
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────

    fn skipWhitespace(self: *JsonParser) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => return,
            }
        }
    }

    fn startsWith(self: *const JsonParser, needle: []const u8) bool {
        if (self.pos + needle.len > self.input.len) return false;
        return mem.eql(u8, self.input[self.pos..][0..needle.len], needle);
    }

    fn isDigit(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }
};

// ── Convenience: parse JSON array into bounded result ───────────────
// For parsing JSON arrays without heap allocation.

pub fn JsonArray(comptime T: type, comptime max_items: usize) type {
    return struct {
        items: [max_items]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn parse(input: []const u8) ?Self {
            var p = JsonParser.init(input);
            return parseFrom(&p);
        }

        pub fn parseFrom(p: *JsonParser) ?Self {
            p.skipWhitespace();
            if (p.pos >= p.input.len or p.input[p.pos] != '[') return null;
            p.pos += 1; // skip [

            var result = Self{};

            p.skipWhitespace();
            if (p.pos < p.input.len and p.input[p.pos] == ']') {
                p.pos += 1;
                return result;
            }

            while (p.pos < p.input.len) {
                if (result.len >= max_items) {
                    // Skip remaining elements
                    while (p.pos < p.input.len) {
                        p.skipValue() orelse return null;
                        p.skipWhitespace();
                        if (p.pos < p.input.len and p.input[p.pos] == ']') {
                            p.pos += 1;
                            return result;
                        }
                        if (p.pos < p.input.len and p.input[p.pos] == ',') {
                            p.pos += 1;
                            continue;
                        }
                        return null;
                    }
                    return null;
                }

                result.items[result.len] = p.parseValue(T) orelse return null;
                result.len += 1;

                p.skipWhitespace();
                if (p.pos >= p.input.len) return null;
                if (p.input[p.pos] == ']') {
                    p.pos += 1;
                    return result;
                }
                if (p.input[p.pos] == ',') {
                    p.pos += 1;
                    continue;
                }
                return null;
            }

            return null;
        }

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }
    };
}

// ── Request convenience for JSON parsing ────────────────────────────

/// Parse the request body as JSON into a comptime-known struct type.
/// Returns null if body is missing or JSON is invalid.
pub fn parseJson(comptime T: type, body: ?[]const u8) ?T {
    const b = body orelse return null;
    return JsonParser.parse(T, b);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "JsonParser: simple struct" {
    const User = struct { name: []const u8, age: i64 };
    const result = JsonParser.parse(User, "{\"name\":\"Alice\",\"age\":30}") orelse unreachable;
    try testing.expectEqualStrings("Alice", result.name);
    try testing.expectEqual(@as(i64, 30), result.age);
}

test "JsonParser: optional fields" {
    const Config = struct { host: []const u8, port: ?i64 = null, debug: ?bool = null };
    const result = JsonParser.parse(Config, "{\"host\":\"localhost\"}") orelse unreachable;
    try testing.expectEqualStrings("localhost", result.host);
    try testing.expectEqual(@as(?i64, null), result.port);
    try testing.expectEqual(@as(?bool, null), result.debug);
}

test "JsonParser: optional field with value" {
    const Config = struct { host: []const u8, port: ?i64 = null };
    const result = JsonParser.parse(Config, "{\"host\":\"0.0.0.0\",\"port\":8080}") orelse unreachable;
    try testing.expectEqualStrings("0.0.0.0", result.host);
    try testing.expectEqual(@as(?i64, 8080), result.port);
}

test "JsonParser: optional field explicit null" {
    const Config = struct { host: []const u8, port: ?i64 = null };
    const result = JsonParser.parse(Config, "{\"host\":\"x\",\"port\":null}") orelse unreachable;
    try testing.expectEqualStrings("x", result.host);
    try testing.expectEqual(@as(?i64, null), result.port);
}

test "JsonParser: bool values" {
    const Flags = struct { active: bool, deleted: bool };
    const result = JsonParser.parse(Flags, "{\"active\":true,\"deleted\":false}") orelse unreachable;
    try testing.expectEqual(true, result.active);
    try testing.expectEqual(false, result.deleted);
}

test "JsonParser: nested struct" {
    const Address = struct { city: []const u8, zip: []const u8 };
    const Person = struct { name: []const u8, address: Address };
    const result = JsonParser.parse(Person, "{\"name\":\"Bob\",\"address\":{\"city\":\"NYC\",\"zip\":\"10001\"}}") orelse unreachable;
    try testing.expectEqualStrings("Bob", result.name);
    try testing.expectEqualStrings("NYC", result.address.city);
    try testing.expectEqualStrings("10001", result.address.zip);
}

test "JsonParser: unknown fields skipped" {
    const User = struct { name: []const u8 };
    const result = JsonParser.parse(User, "{\"name\":\"Eve\",\"extra\":42,\"nested\":{\"a\":1}}") orelse unreachable;
    try testing.expectEqualStrings("Eve", result.name);
}

test "JsonParser: empty object" {
    const Empty = struct { x: ?i64 = null };
    const result = JsonParser.parse(Empty, "{}") orelse unreachable;
    try testing.expectEqual(@as(?i64, null), result.x);
}

test "JsonParser: whitespace tolerance" {
    const User = struct { name: []const u8, age: i64 };
    const result = JsonParser.parse(User, "  { \"name\" : \"Alice\" , \"age\" : 25 }  ") orelse unreachable;
    try testing.expectEqualStrings("Alice", result.name);
    try testing.expectEqual(@as(i64, 25), result.age);
}

test "JsonParser: negative int" {
    const Val = struct { x: i64 };
    const result = JsonParser.parse(Val, "{\"x\":-42}") orelse unreachable;
    try testing.expectEqual(@as(i64, -42), result.x);
}

test "JsonParser: float" {
    const Val = struct { x: f64 };
    const result = JsonParser.parse(Val, "{\"x\":3.14}") orelse unreachable;
    try testing.expect(@abs(result.x - 3.14) < 0.001);
}

test "JsonParser: escaped string" {
    const Val = struct { s: []const u8 };
    const result = JsonParser.parse(Val, "{\"s\":\"hello\\nworld\"}") orelse unreachable;
    try testing.expectEqualStrings("hello\nworld", result.s);
}

test "JsonParser: escaped quotes" {
    const Val = struct { s: []const u8 };
    const result = JsonParser.parse(Val, "{\"s\":\"say \\\"hi\\\"\"}") orelse unreachable;
    try testing.expectEqualStrings("say \"hi\"", result.s);
}

test "JsonParser: unicode escape" {
    const Val = struct { s: []const u8 };
    const result = JsonParser.parse(Val, "{\"s\":\"\\u0041\\u0042\"}") orelse unreachable;
    try testing.expectEqualStrings("AB", result.s);
}

test "JsonParser: skip array value" {
    const Val = struct { name: []const u8 };
    const result = JsonParser.parse(Val, "{\"tags\":[1,2,3],\"name\":\"x\"}") orelse unreachable;
    try testing.expectEqualStrings("x", result.name);
}

test "JsonParser: skip nested object" {
    const Val = struct { id: i64 };
    const result = JsonParser.parse(Val, "{\"meta\":{\"a\":{\"b\":1}},\"id\":99}") orelse unreachable;
    try testing.expectEqual(@as(i64, 99), result.id);
}

test "JsonParser: reject trailing garbage" {
    const Val = struct { x: i64 };
    try testing.expect(JsonParser.parse(Val, "{\"x\":1}garbage") == null);
}

test "JsonParser: reject invalid JSON" {
    const Val = struct { x: i64 };
    try testing.expect(JsonParser.parse(Val, "not json") == null);
    try testing.expect(JsonParser.parse(Val, "") == null);
    try testing.expect(JsonParser.parse(Val, "{") == null);
    try testing.expect(JsonParser.parse(Val, "{\"x\":}") == null);
}

test "JsonParser: JsonArray" {
    const IntArray = JsonArray(i64, 8);
    const result = IntArray.parse("[1,2,3,4,5]") orelse unreachable;
    try testing.expectEqual(@as(usize, 5), result.len);
    try testing.expectEqual(@as(i64, 1), result.items[0]);
    try testing.expectEqual(@as(i64, 5), result.items[4]);
}

test "JsonParser: JsonArray of structs" {
    const Item = struct { id: i64, name: []const u8 };
    const Items = JsonArray(Item, 4);
    const result = Items.parse("[{\"id\":1,\"name\":\"a\"},{\"id\":2,\"name\":\"b\"}]") orelse unreachable;
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(i64, 1), result.items[0].id);
    try testing.expectEqualStrings("b", result.items[1].name);
}

test "JsonParser: JsonArray empty" {
    const IntArray = JsonArray(i64, 8);
    const result = IntArray.parse("[]") orelse unreachable;
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "JsonParser: JsonArray overflow truncates" {
    const SmallArray = JsonArray(i64, 2);
    const result = SmallArray.parse("[1,2,3,4,5]") orelse unreachable;
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(i64, 1), result.items[0]);
    try testing.expectEqual(@as(i64, 2), result.items[1]);
}

test "JsonParser: parseJson with null body" {
    const Val = struct { x: i64 };
    try testing.expect(parseJson(Val, null) == null);
}

test "JsonParser: parseJson with valid body" {
    const Val = struct { x: i64 };
    const result = parseJson(Val, "{\"x\":42}") orelse unreachable;
    try testing.expectEqual(@as(i64, 42), result.x);
}

test "JsonParser: default field values" {
    const Config = struct { host: []const u8 = "localhost", port: i64 = 8080 };
    const result = JsonParser.parse(Config, "{}") orelse unreachable;
    try testing.expectEqualStrings("localhost", result.host);
    try testing.expectEqual(@as(i64, 8080), result.port);
}

test "JsonParser: default overridden" {
    const Config = struct { host: []const u8 = "localhost", port: i64 = 8080 };
    const result = JsonParser.parse(Config, "{\"port\":3000}") orelse unreachable;
    try testing.expectEqualStrings("localhost", result.host);
    try testing.expectEqual(@as(i64, 3000), result.port);
}

test "JsonParser: enum from string" {
    const Status = enum { active, inactive, pending };
    const Val = struct { status: Status };
    const result = JsonParser.parse(Val, "{\"status\":\"active\"}") orelse unreachable;
    try testing.expectEqual(Status.active, result.status);
}

test "JsonParser: multiple escaped fields retain independent data" {
    const Val = struct { a: []const u8, b: []const u8 };
    const result = JsonParser.parse(Val, "{\"a\":\"hello\\nworld\",\"b\":\"foo\\tbar\"}") orelse unreachable;
    // Before fix: field `a` would point at `foo\tbar` (clobbered by second parse)
    try testing.expectEqualStrings("hello\nworld", result.a);
    try testing.expectEqualStrings("foo\tbar", result.b);
}

test "JsonParser: three escaped fields in sequence" {
    const Val = struct { x: []const u8, y: []const u8, z: []const u8 };
    const result = JsonParser.parse(Val, "{\"x\":\"a\\nb\",\"y\":\"c\\td\",\"z\":\"e\\\\f\"}") orelse unreachable;
    try testing.expectEqualStrings("a\nb", result.x);
    try testing.expectEqualStrings("c\td", result.y);
    try testing.expectEqualStrings("e\\f", result.z);
}

test "JsonParser: skip string with escapes in unknown field" {
    const Val = struct { id: i64 };
    const result = JsonParser.parse(Val, "{\"desc\":\"hello\\\"world\",\"id\":1}") orelse unreachable;
    try testing.expectEqual(@as(i64, 1), result.id);
}
