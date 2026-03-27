const std = @import("std");
const elz = @import("elz");
const minish = @import("minish");
const gen = minish.gen;

const Value = elz.Value;

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
                const formatted = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;

                // Parse it
                const alloc = std.heap.page_allocator;
                const value = elz.parser.read(formatted, alloc) catch return;

                // Should be a number
                if (value != .number) return error.TestUnexpectedResult;

                // Value should match
                const expected: f64 = @floatFromInt(n);
                if (value.number != expected) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 200 },
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
                const alloc = std.heap.page_allocator;
                // We don't care about the result, just that it doesn't crash
                _ = elz.parser.read(input, alloc) catch {};
                _ = elz.parser.readAll(input, alloc) catch {};
            }
        }.property,
        .{ .num_runs = 500 },
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
                const alloc = std.heap.page_allocator;
                const source = if (b) "#t" else "#f";
                const value = elz.parser.read(source, alloc) catch return error.TestUnexpectedResult;

                if (value != .boolean) return error.TestUnexpectedResult;
                if (value.boolean != b) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 50 },
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
                const alloc = std.heap.page_allocator;
                // Build a simple string of 'a' characters
                var content: [50]u8 = undefined;
                @memset(content[0..len], 'a');

                // Wrap in quotes for parsing
                var source: [54]u8 = undefined;
                source[0] = '"';
                @memcpy(source[1 .. 1 + len], content[0..len]);
                source[1 + len] = '"';

                const value = elz.parser.read(source[0 .. 2 + len], alloc) catch return error.TestUnexpectedResult;
                if (value != .string) return error.TestUnexpectedResult;
                if (value.string.len != len) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100 },
    );
}
