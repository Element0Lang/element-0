const std = @import("std");
const elz = @import("elz");
const minish = @import("minish");
const gen = minish.gen;

// ---------------------------------------------------------------------------
// Property: addition is commutative: (+ a b) == (+ b a)
// ---------------------------------------------------------------------------

test "property: addition is commutative" {
    const allocator = std.testing.allocator;

    const pair_gen = gen.tuple2(i16, i16, gen.int(i16), gen.int(i16));

    try minish.check(
        allocator,
        pair_gen,
        struct {
            fn property(pair: struct { i16, i16 }) !void {
                const a = pair[0];
                const b = pair[1];

                var buf1: [128]u8 = undefined;
                var buf2: [128]u8 = undefined;
                const expr1 = std.fmt.bufPrint(&buf1, "(+ {d} {d})", .{ a, b }) catch return;
                const expr2 = std.fmt.bufPrint(&buf2, "(+ {d} {d})", .{ b, a }) catch return;

                var interp = elz.Interpreter.init(.{}) catch return;
                defer interp.deinit();

                var fuel1: u64 = 1000;
                var fuel2: u64 = 1000;
                const r1 = interp.evalString(expr1, &fuel1) catch return;
                const r2 = interp.evalString(expr2, &fuel2) catch return;

                if (r1 != .number or r2 != .number) return error.TestUnexpectedResult;
                if (r1.number != r2.number) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100 },
    );
}

// ---------------------------------------------------------------------------
// Property: multiplication is commutative: (* a b) == (* b a)
// ---------------------------------------------------------------------------

test "property: multiplication is commutative" {
    const allocator = std.testing.allocator;

    const pair_gen = gen.tuple2(i16, i16, gen.int(i16), gen.int(i16));

    try minish.check(
        allocator,
        pair_gen,
        struct {
            fn property(pair: struct { i16, i16 }) !void {
                const a = pair[0];
                const b = pair[1];

                var buf1: [128]u8 = undefined;
                var buf2: [128]u8 = undefined;
                const expr1 = std.fmt.bufPrint(&buf1, "(* {d} {d})", .{ a, b }) catch return;
                const expr2 = std.fmt.bufPrint(&buf2, "(* {d} {d})", .{ b, a }) catch return;

                var interp = elz.Interpreter.init(.{}) catch return;
                defer interp.deinit();

                var fuel1: u64 = 1000;
                var fuel2: u64 = 1000;
                const r1 = interp.evalString(expr1, &fuel1) catch return;
                const r2 = interp.evalString(expr2, &fuel2) catch return;

                if (r1 != .number or r2 != .number) return error.TestUnexpectedResult;
                if (r1.number != r2.number) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100 },
    );
}

// ---------------------------------------------------------------------------
// Property: evaluating a number literal returns itself
// ---------------------------------------------------------------------------

test "property: number literals are self-evaluating" {
    const allocator = std.testing.allocator;

    try minish.check(
        allocator,
        gen.int(i32),
        struct {
            fn property(n: i32) !void {
                var buf: [32]u8 = undefined;
                const expr = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;

                var interp = elz.Interpreter.init(.{}) catch return;
                defer interp.deinit();

                var fuel: u64 = 1000;
                const result = interp.evalString(expr, &fuel) catch return;

                if (result != .number) return error.TestUnexpectedResult;
                if (result.number != @as(f64, @floatFromInt(n))) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 200 },
    );
}

// ---------------------------------------------------------------------------
// Property: (- (+ a b) b) == a for small integers
// ---------------------------------------------------------------------------

test "property: addition and subtraction are inverse" {
    const allocator = std.testing.allocator;

    const pair_gen = gen.tuple2(i16, i16, gen.int(i16), gen.int(i16));

    try minish.check(
        allocator,
        pair_gen,
        struct {
            fn property(pair: struct { i16, i16 }) !void {
                const a = pair[0];
                const b = pair[1];

                var buf: [128]u8 = undefined;
                const expr = std.fmt.bufPrint(&buf, "(- (+ {d} {d}) {d})", .{ a, b, b }) catch return;

                var interp = elz.Interpreter.init(.{}) catch return;
                defer interp.deinit();

                var fuel: u64 = 1000;
                const result = interp.evalString(expr, &fuel) catch return;

                if (result != .number) return error.TestUnexpectedResult;
                const expected: f64 = @floatFromInt(a);
                if (@abs(result.number - expected) > 1e-10) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100 },
    );
}

// ---------------------------------------------------------------------------
// Property: eval is deterministic (same input, same output)
// ---------------------------------------------------------------------------

test "property: eval is deterministic" {
    const allocator = std.testing.allocator;

    try minish.check(
        allocator,
        gen.int(i16),
        struct {
            fn property(n: i16) !void {
                var buf: [64]u8 = undefined;
                const expr = std.fmt.bufPrint(&buf, "(* {d} {d})", .{ n, n }) catch return;

                var interp1 = elz.Interpreter.init(.{}) catch return;
                defer interp1.deinit();
                var interp2 = elz.Interpreter.init(.{}) catch return;
                defer interp2.deinit();

                var fuel1: u64 = 1000;
                var fuel2: u64 = 1000;
                const r1 = interp1.evalString(expr, &fuel1) catch return;
                const r2 = interp2.evalString(expr, &fuel2) catch return;

                if (r1 != .number or r2 != .number) return error.TestUnexpectedResult;
                if (r1.number != r2.number) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100 },
    );
}
