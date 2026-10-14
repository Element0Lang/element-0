const std = @import("std");
const elz = @import("elz");
const minish = @import("minish");
const gen = minish.gen;

// ---------------------------------------------------------------------------
// Property: parsing a number literal and writing it back produces a valid number
// ---------------------------------------------------------------------------

test "property: number parse-write roundtrip" {
    const allocator = std.testing.allocator;

    try minish.check(
        allocator,
        gen.int(i32),
        struct {
            fn property(n: i32) !void {
                // Format the number as Element 0 would
                var buf: [64]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&buf, "{d}", .{n});

                // Parse it
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                const value = try elz.parser.read(formatted, alloc);

                // Integer literals now parse as exact_integer
                if (value != .exact_integer) return error.TestUnexpectedResult;
                if (value.exact_integer != @as(i64, n)) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 200, .seed = 1201 },
    );
}

// ---------------------------------------------------------------------------
// Property: parser never crashes on arbitrary input
// ---------------------------------------------------------------------------

test "property: parser does not crash on arbitrary strings" {
    const allocator = std.testing.allocator;

    try minish.check(
        allocator,
        gen.string(.{ .min_len = 0, .max_len = 100 }),
        struct {
            fn property(input: []const u8) !void {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                // We don't care about the result, just that it doesn't crash
                _ = elz.parser.read(input, alloc) catch {};
                _ = elz.parser.readAll(input, alloc) catch {};
            }
        }.property,
        .{ .num_runs = 500, .seed = 1202 },
    );
}

// ---------------------------------------------------------------------------
// Property: boolean roundtrip
// ---------------------------------------------------------------------------

test "property: boolean parse-write roundtrip" {
    const allocator = std.testing.allocator;

    try minish.check(
        allocator,
        gen.boolean(),
        struct {
            fn property(b: bool) !void {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                const source = if (b) "#t" else "#f";
                const value = try elz.parser.read(source, alloc);

                if (value != .boolean) return error.TestUnexpectedResult;
                if (value.boolean != b) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 50, .seed = 1203 },
    );
}

// ---------------------------------------------------------------------------
// Property: string literal roundtrip (simple ASCII, no special chars)
// ---------------------------------------------------------------------------

test "property: simple string parse-write roundtrip" {
    const allocator = std.testing.allocator;

    try minish.check(
        allocator,
        gen.intRange(u8, 1, 50),
        struct {
            fn property(len: u8) !void {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                // Build a simple string of 'a' characters
                var content: [50]u8 = undefined;
                @memset(content[0..len], 'a');

                // Wrap in quotes for parsing
                var source: [54]u8 = undefined;
                source[0] = '"';
                @memcpy(source[1 .. 1 + len], content[0..len]);
                source[1 + len] = '"';

                const value = try elz.parser.read(source[0 .. 2 + len], alloc);
                if (value != .string) return error.TestUnexpectedResult;
                if (value.string.bytes.len != len) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100, .seed = 1204 },
    );
}
