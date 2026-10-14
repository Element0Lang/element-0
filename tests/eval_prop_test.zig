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
                const expr1 = try std.fmt.bufPrint(&buf1, "(+ {d} {d})", .{ a, b });
                const expr2 = try std.fmt.bufPrint(&buf2, "(+ {d} {d})", .{ b, a });

                var interp = try elz.Interpreter.init(.{});
                defer interp.deinit();

                var fuel1: u64 = 1000;
                var fuel2: u64 = 1000;
                const r1 = try interp.evalString(expr1, &fuel1);
                const r2 = try interp.evalString(expr2, &fuel2);

                if (r1 != .exact_integer or r2 != .exact_integer) return error.TestUnexpectedResult;
                if (r1.exact_integer != r2.exact_integer) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100, .seed = 1001 },
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
                const expr1 = try std.fmt.bufPrint(&buf1, "(* {d} {d})", .{ a, b });
                const expr2 = try std.fmt.bufPrint(&buf2, "(* {d} {d})", .{ b, a });

                var interp = try elz.Interpreter.init(.{});
                defer interp.deinit();

                var fuel1: u64 = 1000;
                var fuel2: u64 = 1000;
                const r1 = try interp.evalString(expr1, &fuel1);
                const r2 = try interp.evalString(expr2, &fuel2);

                if (r1 != .exact_integer or r2 != .exact_integer) return error.TestUnexpectedResult;
                if (r1.exact_integer != r2.exact_integer) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100, .seed = 1002 },
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
                const expr = try std.fmt.bufPrint(&buf, "{d}", .{n});

                var interp = try elz.Interpreter.init(.{});
                defer interp.deinit();

                var fuel: u64 = 1000;
                const result = try interp.evalString(expr, &fuel);

                if (result != .exact_integer) return error.TestUnexpectedResult;
                if (result.exact_integer != @as(i64, n)) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 200, .seed = 1003 },
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
                const expr = try std.fmt.bufPrint(&buf, "(- (+ {d} {d}) {d})", .{ a, b, b });

                var interp = try elz.Interpreter.init(.{});
                defer interp.deinit();

                var fuel: u64 = 1000;
                const result = try interp.evalString(expr, &fuel);

                if (result != .exact_integer) return error.TestUnexpectedResult;
                if (result.exact_integer != @as(i64, a)) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100, .seed = 1004 },
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
                const expr = try std.fmt.bufPrint(&buf, "(* {d} {d})", .{ n, n });

                var interp1 = try elz.Interpreter.init(.{});
                defer interp1.deinit();
                var interp2 = try elz.Interpreter.init(.{});
                defer interp2.deinit();

                var fuel1: u64 = 1000;
                var fuel2: u64 = 1000;
                const r1 = try interp1.evalString(expr, &fuel1);
                const r2 = try interp2.evalString(expr, &fuel2);

                if (r1 != .exact_integer or r2 != .exact_integer) return error.TestUnexpectedResult;
                if (r1.exact_integer != r2.exact_integer) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 100, .seed = 1005 },
    );
}
