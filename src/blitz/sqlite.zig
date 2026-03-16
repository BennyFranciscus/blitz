// sqlite.zig — Zero-overhead SQLite3 wrapper for Zig
//
// Thin wrapper around the SQLite3 C API via @cImport.
// Designed for server workloads: per-thread connections, prepared statements,
// typed column access, and zero heap allocations in the hot path.
//
// Usage:
//   var db = try Db.open("/data/benchmark.db", .{ .readonly = true });
//   defer db.close();
//
//   var stmt = try db.prepare("SELECT id, name FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50");
//   defer stmt.finalize();
//
//   try stmt.bindDouble(1, min_price);
//   try stmt.bindDouble(2, max_price);
//
//   while (try stmt.step()) {
//       const id = stmt.columnInt(0);
//       const name = stmt.columnText(1);
//       // ... process row
//   }
//   stmt.reset(); // reuse for next query

const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    SqliteError,
    SqliteBusy,
    SqliteMisuse,
};

/// SQLite database connection wrapper
pub const Db = struct {
    handle: *c.sqlite3,

    pub const OpenOptions = struct {
        readonly: bool = false,
        /// WAL journal mode (better concurrency for reads)
        wal: bool = false,
        /// Memory-mapped I/O size in bytes (0 = disabled)
        mmap_size: u64 = 0,
        /// Cache size in pages (negative = KB, positive = pages)
        cache_size: i32 = 0,
    };

    /// Open a database file. Returns error if file doesn't exist or can't be opened.
    pub fn open(path: [*:0]const u8, opts: OpenOptions) Error!Db {
        var flags: c_int = c.SQLITE_OPEN_NOMUTEX; // per-thread, no mutex needed
        if (opts.readonly) {
            flags |= c.SQLITE_OPEN_READONLY;
        } else {
            flags |= c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        }

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path, &db, flags, null);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return Error.SqliteError;
        }

        var self = Db{ .handle = db.? };

        // Apply pragmas
        if (opts.wal) self.exec("PRAGMA journal_mode=WAL");
        if (opts.mmap_size > 0) {
            var buf: [64]u8 = undefined;
            const pragma = std.fmt.bufPrint(&buf, "PRAGMA mmap_size={d}", .{opts.mmap_size}) catch "";
            if (pragma.len > 0) self.execSlice(pragma);
        }
        if (opts.cache_size != 0) {
            var buf: [64]u8 = undefined;
            const pragma = std.fmt.bufPrint(&buf, "PRAGMA cache_size={d}", .{opts.cache_size}) catch "";
            if (pragma.len > 0) self.execSlice(pragma);
        }

        return self;
    }

    /// Close the database connection
    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Execute a simple SQL statement (no results). Null-terminated.
    pub fn exec(self: *Db, sql: [*:0]const u8) void {
        _ = c.sqlite3_exec(self.handle, sql, null, null, null);
    }

    /// Execute a simple SQL statement from a Zig slice (copies to add null terminator)
    pub fn execSlice(self: *Db, sql: []const u8) void {
        var buf: [256]u8 = undefined;
        if (sql.len >= buf.len) return;
        @memcpy(buf[0..sql.len], sql);
        buf[sql.len] = 0;
        _ = c.sqlite3_exec(self.handle, @ptrCast(&buf), null, null, null);
    }

    /// Prepare a SQL statement for execution
    pub fn prepare(self: *Db, sql: [*:0]const u8) Error!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return Error.SqliteError;
        }
        return Statement{ .handle = stmt.? };
    }

    /// Get the last error message
    pub fn errmsg(self: *Db) [*:0]const u8 {
        return c.sqlite3_errmsg(self.handle);
    }
};

/// Prepared statement wrapper
pub const Statement = struct {
    handle: *c.sqlite3_stmt,

    /// Bind a double value to a parameter (1-indexed)
    pub fn bindDouble(self: *Statement, idx: c_int, val: f64) Error!void {
        const rc = c.sqlite3_bind_double(self.handle, idx, val);
        if (rc != c.SQLITE_OK) return Error.SqliteError;
    }

    /// Bind an integer value to a parameter (1-indexed)
    pub fn bindInt(self: *Statement, idx: c_int, val: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.handle, idx, val);
        if (rc != c.SQLITE_OK) return Error.SqliteError;
    }

    /// Bind a text value to a parameter (1-indexed)
    pub fn bindText(self: *Statement, idx: c_int, val: []const u8) Error!void {
        const rc = c.sqlite3_bind_text(self.handle, idx, val.ptr, @intCast(val.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) return Error.SqliteError;
    }

    /// Bind NULL to a parameter (1-indexed)
    pub fn bindNull(self: *Statement, idx: c_int) Error!void {
        const rc = c.sqlite3_bind_null(self.handle, idx);
        if (rc != c.SQLITE_OK) return Error.SqliteError;
    }

    /// Step to the next row. Returns true if a row is available, false if done.
    pub fn step(self: *Statement) Error!bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        if (rc == c.SQLITE_BUSY) return Error.SqliteBusy;
        return Error.SqliteError;
    }

    /// Get column count
    pub fn columnCount(self: *Statement) c_int {
        return c.sqlite3_column_count(self.handle);
    }

    /// Get an integer column value (0-indexed)
    pub fn columnInt(self: *Statement, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, idx);
    }

    /// Get a double column value (0-indexed)
    pub fn columnDouble(self: *Statement, idx: c_int) f64 {
        return c.sqlite3_column_double(self.handle, idx);
    }

    /// Get a text column value as a Zig slice (0-indexed)
    /// The returned slice is valid until the next step() or reset() call.
    pub fn columnText(self: *Statement, idx: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx);
        if (ptr == null) return "";
        const len = c.sqlite3_column_bytes(self.handle, idx);
        if (len <= 0) return "";
        return ptr[0..@intCast(len)];
    }

    /// Get a blob column value (0-indexed)
    /// The returned slice is valid until the next step() or reset() call.
    pub fn columnBlob(self: *Statement, idx: c_int) []const u8 {
        const ptr: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(self.handle, idx));
        if (ptr == null) return "";
        const len = c.sqlite3_column_bytes(self.handle, idx);
        if (len <= 0) return "";
        return ptr.?[0..@intCast(len)];
    }

    /// Check if a column is NULL (0-indexed)
    pub fn columnIsNull(self: *Statement, idx: c_int) bool {
        return c.sqlite3_column_type(self.handle, idx) == c.SQLITE_NULL;
    }

    /// Get column type (0-indexed)
    pub fn columnType(self: *Statement, idx: c_int) ColumnType {
        return switch (c.sqlite3_column_type(self.handle, idx)) {
            c.SQLITE_INTEGER => .integer,
            c.SQLITE_FLOAT => .float,
            c.SQLITE_TEXT => .text,
            c.SQLITE_BLOB => .blob,
            c.SQLITE_NULL => .null_type,
            else => .null_type,
        };
    }

    /// Reset the statement for re-execution (reuse with new bindings)
    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    /// Finalize (destroy) the statement
    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }
};

pub const ColumnType = enum {
    integer,
    float,
    text,
    blob,
    null_type,
};

// ── Tests ───────────────────────────────────────────────────────────

test "open and close in-memory database" {
    var db = Db.open(":memory:", .{}) catch return; // skip if no sqlite
    defer db.close();

    db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
    db.exec("INSERT INTO test VALUES (1, 'hello')");
    db.exec("INSERT INTO test VALUES (2, 'world')");

    var stmt = try db.prepare("SELECT id, name FROM test ORDER BY id");
    defer stmt.finalize();

    // Row 1
    const has1 = try stmt.step();
    try std.testing.expect(has1);
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    try std.testing.expectEqualStrings("hello", stmt.columnText(1));

    // Row 2
    const has2 = try stmt.step();
    try std.testing.expect(has2);
    try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
    try std.testing.expectEqualStrings("world", stmt.columnText(1));

    // Done
    const has3 = try stmt.step();
    try std.testing.expect(!has3);
}

test "bind parameters" {
    var db = Db.open(":memory:", .{}) catch return;
    defer db.close();

    db.exec("CREATE TABLE items (price REAL, name TEXT)");
    db.exec("INSERT INTO items VALUES (10.5, 'cheap')");
    db.exec("INSERT INTO items VALUES (25.0, 'medium')");
    db.exec("INSERT INTO items VALUES (99.9, 'expensive')");

    var stmt = try db.prepare("SELECT name FROM items WHERE price BETWEEN ?1 AND ?2");
    defer stmt.finalize();

    try stmt.bindDouble(1, 10.0);
    try stmt.bindDouble(2, 30.0);

    var count: usize = 0;
    while (try stmt.step()) count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);

    // Reset and re-query
    stmt.reset();
    try stmt.bindDouble(1, 90.0);
    try stmt.bindDouble(2, 100.0);

    count = 0;
    while (try stmt.step()) count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "column types" {
    var db = Db.open(":memory:", .{}) catch return;
    defer db.close();

    db.exec("CREATE TABLE types (i INTEGER, f REAL, t TEXT, b BLOB, n)");
    db.exec("INSERT INTO types VALUES (42, 3.14, 'hello', X'DEADBEEF', NULL)");

    var stmt = try db.prepare("SELECT i, f, t, b, n FROM types");
    defer stmt.finalize();

    const has = try stmt.step();
    try std.testing.expect(has);

    try std.testing.expectEqual(ColumnType.integer, stmt.columnType(0));
    try std.testing.expectEqual(ColumnType.float, stmt.columnType(1));
    try std.testing.expectEqual(ColumnType.text, stmt.columnType(2));
    try std.testing.expectEqual(ColumnType.blob, stmt.columnType(3));
    try std.testing.expectEqual(ColumnType.null_type, stmt.columnType(4));

    try std.testing.expectEqual(@as(i64, 42), stmt.columnInt(0));
    try std.testing.expect(@abs(stmt.columnDouble(1) - 3.14) < 0.001);
    try std.testing.expectEqualStrings("hello", stmt.columnText(2));
    try std.testing.expect(stmt.columnIsNull(4));
}

test "text binding" {
    var db = Db.open(":memory:", .{}) catch return;
    defer db.close();

    db.exec("CREATE TABLE t (val TEXT)");

    var ins = try db.prepare("INSERT INTO t VALUES (?1)");
    defer ins.finalize();

    try ins.bindText(1, "hello world");
    _ = try ins.step();

    var sel = try db.prepare("SELECT val FROM t");
    defer sel.finalize();

    const has = try sel.step();
    try std.testing.expect(has);
    try std.testing.expectEqualStrings("hello world", sel.columnText(0));
}

test "null column returns empty" {
    var db = Db.open(":memory:", .{}) catch return;
    defer db.close();

    db.exec("CREATE TABLE t (val TEXT)");
    db.exec("INSERT INTO t VALUES (NULL)");

    var stmt = try db.prepare("SELECT val FROM t");
    defer stmt.finalize();

    const has = try stmt.step();
    try std.testing.expect(has);
    try std.testing.expectEqualStrings("", stmt.columnText(0));
    try std.testing.expect(stmt.columnIsNull(0));
}
