// database.zig — REST API with SQLite database
//
// Demonstrates:
// - SQLite integration with per-thread connections
// - JSON serialization of query results
// - Query parameter parsing for filtering
// - Context injection for shared state
//
// Build: zig build database
// Run:   ./zig-out/bin/database
// Test:  curl http://localhost:8080/items?min=10&max=50

const std = @import("std");
const mem = std.mem;
const blitz = @import("blitz");

// ── Application State ───────────────────────────────────────────────

const AppState = struct {
    db_path: [*:0]const u8,
};

// Per-thread database connection (lazy-initialized)
threadlocal var tls_db: ?blitz.SqliteDb = null;
threadlocal var tls_stmt_list: ?blitz.SqliteStatement = null;
threadlocal var tls_stmt_get: ?blitz.SqliteStatement = null;

fn getDb() ?*blitz.SqliteDb {
    if (tls_db != null) return &(tls_db.?);

    tls_db = blitz.SqliteDb.open(":memory:", .{}) catch return null;

    // Create sample data
    tls_db.?.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, price REAL, category TEXT)");
    tls_db.?.exec("INSERT INTO items VALUES (1, 'Widget A', 9.99, 'electronics')");
    tls_db.?.exec("INSERT INTO items VALUES (2, 'Gadget B', 24.50, 'electronics')");
    tls_db.?.exec("INSERT INTO items VALUES (3, 'Tool C', 5.99, 'tools')");
    tls_db.?.exec("INSERT INTO items VALUES (4, 'Part D', 149.99, 'industrial')");
    tls_db.?.exec("INSERT INTO items VALUES (5, 'Accessory E', 3.50, 'accessories')");

    tls_stmt_list = tls_db.?.prepare("SELECT id, name, price, category FROM items WHERE price BETWEEN ?1 AND ?2 ORDER BY price LIMIT 50") catch return null;
    tls_stmt_get = tls_db.?.prepare("SELECT id, name, price, category FROM items WHERE id = ?1") catch return null;

    return &(tls_db.?);
}

// ── Handlers ────────────────────────────────────────────────────────

fn listItems(req: *blitz.Request, res: *blitz.Response) void {
    _ = getDb() orelse {
        _ = res.setStatus(.internal_server_error).text("DB unavailable");
        return;
    };

    // Parse query params
    var min_price: f64 = 0.0;
    var max_price: f64 = 99999.0;
    if (req.query) |q| {
        var it = mem.splitScalar(u8, q, '&');
        while (it.next()) |pair| {
            if (mem.indexOfScalar(u8, pair, '=')) |eq| {
                const key = pair[0..eq];
                const val = pair[eq + 1 ..];
                if (mem.eql(u8, key, "min")) min_price = std.fmt.parseFloat(f64, val) catch 0.0;
                if (mem.eql(u8, key, "max")) max_price = std.fmt.parseFloat(f64, val) catch 99999.0;
            }
        }
    }

    var stmt = &(tls_stmt_list.?);
    stmt.reset();
    stmt.bindDouble(1, min_price) catch return;
    stmt.bindDouble(2, max_price) catch return;

    // Build JSON array
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    const prefix = "{\"items\":[";
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    var count: usize = 0;
    while (true) {
        const has_row = stmt.step() catch break;
        if (!has_row) break;

        if (count > 0) {
            buf[pos] = ',';
            pos += 1;
        }

        const id = stmt.columnInt(0);
        const name = stmt.columnText(1);
        const price = stmt.columnDouble(2);
        const category = stmt.columnText(3);

        const written = std.fmt.bufPrint(buf[pos..], "{{\"id\":{d},\"name\":\"{s}\",\"price\":{d:.2},\"category\":\"{s}\"}}", .{
            id, name, price, category,
        }) catch break;
        pos += written.len;
        count += 1;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "],\"count\":{d}}}", .{count}) catch return;
    pos += suffix.len;

    _ = res.json(buf[0..pos]);
}

fn getItem(req: *blitz.Request, res: *blitz.Response) void {
    _ = getDb() orelse {
        _ = res.setStatus(.internal_server_error).text("DB unavailable");
        return;
    };

    const id_str = req.params.get("id") orelse {
        _ = blitz.badRequest(res, "Missing id");
        return;
    };
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        _ = blitz.badRequest(res, "Invalid id");
        return;
    };

    var stmt = &(tls_stmt_get.?);
    stmt.reset();
    stmt.bindInt(1, id) catch return;

    const has_row = stmt.step() catch {
        _ = blitz.internalError(res, "Query failed");
        return;
    };

    if (!has_row) {
        _ = blitz.notFound(res, "Item not found");
        return;
    }

    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"name\":\"{s}\",\"price\":{d:.2},\"category\":\"{s}\"}}", .{
        stmt.columnInt(0),
        stmt.columnText(1),
        stmt.columnDouble(2),
        stmt.columnText(3),
    }) catch return;

    _ = res.json(json);
}

fn handleIndex(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.json("{\"message\":\"Blitz SQLite Example\",\"endpoints\":[\"/items\",\"/items/:id\"]}");
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var router = blitz.Router.init(alloc);

    router.get("/", handleIndex);
    router.get("/items", listItems);
    router.get("/items/:id", getItem);

    var server = blitz.Server.init(&router, .{
        .port = 8080,
        .compression = true,
    });
    try server.listen();
}
