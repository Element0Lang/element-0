const std = @import("std");
const elz = @import("elz");
const minish = @import("minish");
const gen = minish.gen;

// ---------------------------------------------------------------------------
// Property: json-serialize then json-deserialize a number == original
// ---------------------------------------------------------------------------

test "property: JSON number roundtrip" {
    const allocator = std.testing.allocator;

    try minish.check(
        allocator,
        gen.int(i32),
        struct {
            fn property(n: i32) !void {
                var buf: [64]u8 = undefined;
                const expr = std.fmt.bufPrint(&buf, "(json-deserialize (json-serialize {d}))", .{n}) catch return;

                var interp = elz.Interpreter.init(.{}) catch return;
                defer interp.deinit();

                var fuel: u64 = 10000;
                const result = interp.evalString(expr, &fuel) catch return;

                switch (result) {
                    .exact_integer => |i| {
                        if (i != @as(i64, n)) return error.TestUnexpectedResult;
                    },
                    .number => |f| {
                        const expected: f64 = @floatFromInt(n);
                        if (f != expected) return error.TestUnexpectedResult;
                    },
                    else => return error.TestUnexpectedResult,
                }
            }
        }.property,
        .{ .num_runs = 100 },
    );
}

// ---------------------------------------------------------------------------
// Property: json-serialize then json-deserialize a boolean == original
// ---------------------------------------------------------------------------

test "property: JSON boolean roundtrip" {
    const allocator = std.testing.allocator;

    try minish.check(
        allocator,
        gen.boolean(),
        struct {
            fn property(b: bool) !void {
                const expr = if (b) "(json-deserialize (json-serialize #t))" else "(json-deserialize (json-serialize #f))";

                var interp = elz.Interpreter.init(.{}) catch return;
                defer interp.deinit();

                var fuel: u64 = 10000;
                const result = interp.evalString(expr, &fuel) catch return;

                if (result != .boolean) return error.TestUnexpectedResult;
                if (result.boolean != b) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 50 },
    );
}
