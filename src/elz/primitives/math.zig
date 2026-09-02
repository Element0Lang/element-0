const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

// --- Numeric tower helpers ---

fn toF64(v: Value) f64 {
    return switch (v) {
        .number => |n| n,
        .exact_integer => |n| @as(f64, @floatFromInt(n)),
        .rational => |r| @as(f64, @floatFromInt(r.numerator)) / @as(f64, @floatFromInt(r.denominator)),
        .complex => |c| c.real, // lossy; callers should check
        else => unreachable,
    };
}

fn gcdU64(a: u64, b: u64) u64 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

fn absU64(x: i64) u64 {
    if (x == std.math.minInt(i64)) return @as(u64, 1) << 63;
    return @intCast(if (x < 0) -x else x);
}

/// Normalizes a rational n/d to canonical form.
pub fn normalizeRational(n: i64, d: i64, alloc: std.mem.Allocator) ElzError!Value {
    if (d == 0) return ElzError.DivisionByZero;
    // Determine sign and absolute values without overflow on i64.minInt
    var num: i64 = n;
    var den: i64 = d;
    if (den < 0) {
        // Negate. Skip overflow check: den != minInt because if it were, gcd math would also blow up; treat as Overflow.
        if (den == std.math.minInt(i64) or num == std.math.minInt(i64)) return ElzError.Overflow;
        num = -num;
        den = -den;
    }
    const an = absU64(num);
    const ad = absU64(den);
    const g = gcdU64(an, ad);
    const g_i: i64 = @intCast(g);
    const rn = @divExact(num, g_i);
    const rd = @divExact(den, g_i);
    if (rd == 1) return Value{ .exact_integer = rn };
    const rat = alloc.create(core.Rational) catch return ElzError.OutOfMemory;
    rat.* = .{ .numerator = rn, .denominator = rd };
    return Value{ .rational = rat };
}

fn ratParts(v: Value) struct { n: i64, d: i64 } {
    return switch (v) {
        .exact_integer => |i| .{ .n = i, .d = 1 },
        .rational => |r| .{ .n = r.numerator, .d = r.denominator },
        else => unreachable,
    };
}

fn mulOv(a: i64, b: i64) ElzError!i64 {
    const r = @mulWithOverflow(a, b);
    if (r[1] != 0) return ElzError.Overflow;
    return r[0];
}

fn addOv(a: i64, b: i64) ElzError!i64 {
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return ElzError.Overflow;
    return r[0];
}

fn subOv(a: i64, b: i64) ElzError!i64 {
    const r = @subWithOverflow(a, b);
    if (r[1] != 0) return ElzError.Overflow;
    return r[0];
}

fn isExactKind(v: Value) bool {
    return v == .exact_integer or v == .rational;
}

fn isRealKind(v: Value) bool {
    return v == .number or v == .exact_integer or v == .rational;
}

fn numAdd(a: Value, b: Value, alloc: std.mem.Allocator) ElzError!Value {
    if (a == .exact_integer and b == .exact_integer) {
        const res = try addOv(a.exact_integer, b.exact_integer);
        return Value{ .exact_integer = res };
    }
    if (isExactKind(a) and isExactKind(b)) {
        const ap = ratParts(a);
        const bp = ratParts(b);
        const t1 = try mulOv(ap.n, bp.d);
        const t2 = try mulOv(bp.n, ap.d);
        const num = try addOv(t1, t2);
        const den = try mulOv(ap.d, bp.d);
        return normalizeRational(num, den, alloc);
    }
    if (a == .complex or b == .complex) {
        const ar: f64 = if (a == .complex) a.complex.real else toF64(a);
        const ai: f64 = if (a == .complex) a.complex.imag else 0;
        const br: f64 = if (b == .complex) b.complex.real else toF64(b);
        const bi: f64 = if (b == .complex) b.complex.imag else 0;
        const c = alloc.create(core.Complex) catch return ElzError.OutOfMemory;
        c.* = .{ .real = ar + br, .imag = ai + bi };
        return Value{ .complex = c };
    }
    return Value{ .number = toF64(a) + toF64(b) };
}

fn numSub(a: Value, b: Value, alloc: std.mem.Allocator) ElzError!Value {
    if (a == .exact_integer and b == .exact_integer) {
        const res = try subOv(a.exact_integer, b.exact_integer);
        return Value{ .exact_integer = res };
    }
    if (isExactKind(a) and isExactKind(b)) {
        const ap = ratParts(a);
        const bp = ratParts(b);
        const t1 = try mulOv(ap.n, bp.d);
        const t2 = try mulOv(bp.n, ap.d);
        const num = try subOv(t1, t2);
        const den = try mulOv(ap.d, bp.d);
        return normalizeRational(num, den, alloc);
    }
    if (a == .complex or b == .complex) {
        const ar: f64 = if (a == .complex) a.complex.real else toF64(a);
        const ai: f64 = if (a == .complex) a.complex.imag else 0;
        const br: f64 = if (b == .complex) b.complex.real else toF64(b);
        const bi: f64 = if (b == .complex) b.complex.imag else 0;
        const c = alloc.create(core.Complex) catch return ElzError.OutOfMemory;
        c.* = .{ .real = ar - br, .imag = ai - bi };
        return Value{ .complex = c };
    }
    return Value{ .number = toF64(a) - toF64(b) };
}

fn numMul(a: Value, b: Value, alloc: std.mem.Allocator) ElzError!Value {
    if (a == .exact_integer and b == .exact_integer) {
        const res = try mulOv(a.exact_integer, b.exact_integer);
        return Value{ .exact_integer = res };
    }
    if (isExactKind(a) and isExactKind(b)) {
        const ap = ratParts(a);
        const bp = ratParts(b);
        const num = try mulOv(ap.n, bp.n);
        const den = try mulOv(ap.d, bp.d);
        return normalizeRational(num, den, alloc);
    }
    if (a == .complex or b == .complex) {
        const ar: f64 = if (a == .complex) a.complex.real else toF64(a);
        const ai: f64 = if (a == .complex) a.complex.imag else 0;
        const br: f64 = if (b == .complex) b.complex.real else toF64(b);
        const bi: f64 = if (b == .complex) b.complex.imag else 0;
        const c = alloc.create(core.Complex) catch return ElzError.OutOfMemory;
        c.* = .{ .real = ar * br - ai * bi, .imag = ar * bi + ai * br };
        return Value{ .complex = c };
    }
    return Value{ .number = toF64(a) * toF64(b) };
}

fn numDiv(a: Value, b: Value, alloc: std.mem.Allocator) ElzError!Value {
    if (isExactKind(a) and isExactKind(b)) {
        const ap = ratParts(a);
        const bp = ratParts(b);
        if (bp.n == 0) return ElzError.DivisionByZero;
        const num = try mulOv(ap.n, bp.d);
        const den = try mulOv(ap.d, bp.n);
        return normalizeRational(num, den, alloc);
    }
    if (a == .complex or b == .complex) {
        const ar: f64 = if (a == .complex) a.complex.real else toF64(a);
        const ai: f64 = if (a == .complex) a.complex.imag else 0;
        const br: f64 = if (b == .complex) b.complex.real else toF64(b);
        const bi: f64 = if (b == .complex) b.complex.imag else 0;
        const denom = br * br + bi * bi;
        if (denom == 0) return ElzError.DivisionByZero;
        const c = alloc.create(core.Complex) catch return ElzError.OutOfMemory;
        c.* = .{ .real = (ar * br + ai * bi) / denom, .imag = (ai * br - ar * bi) / denom };
        return Value{ .complex = c };
    }
    const denf = toF64(b);
    if (denf == 0) return ElzError.DivisionByZero;
    return Value{ .number = toF64(a) / denf };
}

fn numNegate(a: Value, alloc: std.mem.Allocator) ElzError!Value {
    return switch (a) {
        .exact_integer => |n| blk: {
            if (n == std.math.minInt(i64)) break :blk ElzError.Overflow;
            break :blk Value{ .exact_integer = -n };
        },
        .rational => |r| blk: {
            if (r.numerator == std.math.minInt(i64)) break :blk ElzError.Overflow;
            const new_r = alloc.create(core.Rational) catch return ElzError.OutOfMemory;
            new_r.* = .{ .numerator = -r.numerator, .denominator = r.denominator };
            break :blk Value{ .rational = new_r };
        },
        .number => |n| Value{ .number = -n },
        .complex => |c| blk: {
            const new_c = alloc.create(core.Complex) catch return ElzError.OutOfMemory;
            new_c.* = .{ .real = -c.real, .imag = -c.imag };
            break :blk Value{ .complex = new_c };
        },
        else => ElzError.InvalidArgument,
    };
}

// --- Primitive procedures ---

pub fn add(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .exact_integer = 0 };
    var acc = args.items[0];
    if (!acc.isNumeric()) return ElzError.InvalidArgument;
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        acc = try numAdd(acc, arg, env.allocator);
    }
    return acc;
}

pub fn sub(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    if (!args.items[0].isNumeric()) return ElzError.InvalidArgument;
    if (args.items.len == 1) {
        return numNegate(args.items[0], env.allocator);
    }
    var acc = args.items[0];
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        acc = try numSub(acc, arg, env.allocator);
    }
    return acc;
}

pub fn mul(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .exact_integer = 1 };
    var acc = args.items[0];
    if (!acc.isNumeric()) return ElzError.InvalidArgument;
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        acc = try numMul(acc, arg, env.allocator);
    }
    return acc;
}

pub fn div(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;
    if (!args.items[0].isNumeric()) return ElzError.InvalidArgument;
    if (args.items.len == 1) {
        // (/ x) = 1/x
        return numDiv(Value{ .exact_integer = 1 }, args.items[0], env.allocator);
    }
    var acc = args.items[0];
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        acc = try numDiv(acc, arg, env.allocator);
    }
    return acc;
}

fn cmp2(a: Value, b: Value) ElzError!std.math.Order {
    if (!a.isNumeric() or !b.isNumeric()) return ElzError.InvalidArgument;
    // Exact-exact comparison without float loss
    if (isExactKind(a) and isExactKind(b)) {
        const ap = ratParts(a);
        const bp = ratParts(b);
        // ap.n/ap.d vs bp.n/bp.d -> compare ap.n * bp.d vs bp.n * ap.d (both denominators positive)
        const lhs = try mulOv(ap.n, bp.d);
        const rhs = try mulOv(bp.n, ap.d);
        if (lhs < rhs) return .lt;
        if (lhs > rhs) return .gt;
        return .eq;
    }
    if (a == .complex or b == .complex) return ElzError.InvalidArgument;
    const af = toF64(a);
    const bf = toF64(b);
    if (af < bf) return .lt;
    if (af > bf) return .gt;
    return .eq;
}

/// Chained n-ary comparison: true when every adjacent pair satisfies `ok`.
fn chainCompare(args: core.ValueList, comptime ok: fn (std.math.Order) bool) ElzError!Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;
    for (args.items[0 .. args.items.len - 1], args.items[1..]) |a, b| {
        const o = try cmp2(a, b);
        if (!ok(o)) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

pub fn le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainCompare(args, struct {
        fn ok(o: std.math.Order) bool {
            return o != .gt;
        }
    }.ok);
}

pub fn lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainCompare(args, struct {
        fn ok(o: std.math.Order) bool {
            return o == .lt;
        }
    }.ok);
}

pub fn ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainCompare(args, struct {
        fn ok(o: std.math.Order) bool {
            return o != .lt;
        }
    }.ok);
}

pub fn gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainCompare(args, struct {
        fn ok(o: std.math.Order) bool {
            return o == .gt;
        }
    }.ok);
}

pub fn eq_num(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;
    for (args.items[0 .. args.items.len - 1], args.items[1..]) |ca, cb| {
        if (!try numEq2(ca, cb)) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

fn numEq2(a: Value, b: Value) ElzError!bool {
    if (!a.isNumeric() or !b.isNumeric()) return ElzError.InvalidArgument;
    if (a == .complex or b == .complex) {
        const ar: f64 = if (a == .complex) a.complex.real else toF64(a);
        const ai: f64 = if (a == .complex) a.complex.imag else 0;
        const br: f64 = if (b == .complex) b.complex.real else toF64(b);
        const bi: f64 = if (b == .complex) b.complex.imag else 0;
        return ar == br and ai == bi;
    }
    const o = try cmp2(a, b);
    return o == .eq;
}

fn isqrt(n: u64) u64 {
    if (n < 2) return n;
    var x = n;
    var y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}

pub fn sqrt(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (!v.isNumeric()) return ElzError.InvalidArgument;
    if (v == .exact_integer and v.exact_integer >= 0) {
        const n: u64 = @intCast(v.exact_integer);
        const r = isqrt(n);
        if (r * r == n) return Value{ .exact_integer = @intCast(r) };
    }
    if (v == .complex) {
        // Principal square root of a complex number.
        const c = v.complex;
        const m = std.math.sqrt(std.math.hypot(c.real, c.imag));
        const a = std.math.atan2(c.imag, c.real) / 2;
        const out = env.allocator.create(core.Complex) catch return ElzError.OutOfMemory;
        out.* = .{ .real = m * std.math.cos(a), .imag = m * std.math.sin(a) };
        return Value{ .complex = out };
    }
    const f = v.asFloat() orelse return ElzError.InvalidArgument;
    if (f < 0) {
        // The square root of a negative real is imaginary.
        const out = env.allocator.create(core.Complex) catch return ElzError.OutOfMemory;
        out.* = .{ .real = 0, .imag = std.math.sqrt(-f) };
        return Value{ .complex = out };
    }
    return Value{ .number = std.math.sqrt(f) };
}

pub fn sin(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.sin(f) };
}

pub fn cos(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.cos(f) };
}

pub fn tan(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.tan(f) };
}

pub fn asin(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.asin(f) };
}

pub fn acos(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.acos(f) };
}

pub fn atan(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 2) {
        const y = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
        const x = args.items[1].asFloat() orelse return ElzError.InvalidArgument;
        return Value{ .number = std.math.atan2(y, x) };
    }
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.atan(f) };
}

pub fn log(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.log(f64, std.math.e, f) };
}

/// R7RS requires the result of `max` and `min` to be inexact when any argument
/// is inexact, even if the extremum itself is exact.
fn contaminate(best: Value, saw_inexact: bool) ElzError!Value {
    if (!saw_inexact or best == .number) return best;
    return Value{ .number = best.asFloat() orelse return ElzError.InvalidArgument };
}

pub fn max(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    var best = args.items[0];
    if (!best.isNumeric()) return ElzError.InvalidArgument;
    var saw_inexact = best == .number;
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        if (arg == .number) saw_inexact = true;
        const o = try cmp2(arg, best);
        if (o == .gt) best = arg;
    }
    return contaminate(best, saw_inexact);
}

pub fn min(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    var best = args.items[0];
    if (!best.isNumeric()) return ElzError.InvalidArgument;
    var saw_inexact = best == .number;
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        if (arg == .number) saw_inexact = true;
        const o = try cmp2(arg, best);
        if (o == .lt) best = arg;
    }
    return contaminate(best, saw_inexact);
}

pub fn mod(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a == .exact_integer and b == .exact_integer) {
        if (b.exact_integer == 0) return ElzError.DivisionByZero;
        return Value{ .exact_integer = @mod(a.exact_integer, b.exact_integer) };
    }
    const af = a.asFloat() orelse return ElzError.InvalidArgument;
    const bf = b.asFloat() orelse return ElzError.InvalidArgument;
    if (bf == 0) return ElzError.DivisionByZero;
    _ = env;
    return Value{ .number = @mod(af, bf) };
}

/// Rounds to the nearest integer, resolving a tie to the even neighbour, as
/// R7RS `round` requires (`@round` breaks ties away from zero instead).
fn roundHalfEven(x: f64) f64 {
    const nearest = @round(x);
    if (@abs(x - @trunc(x)) == 0.5 and @rem(nearest, 2) != 0) {
        return nearest - std.math.sign(x);
    }
    return nearest;
}

/// Rounds the exact rational n/d with the given mode. All four operations keep
/// exactness, so the result is always an exact integer here.
fn roundRational(n: i64, d: i64, comptime mode: enum { floor, ceiling, truncate, round }) ElzError!Value {
    const q = @divFloor(n, d); // d > 0 in canonical form
    const rem: i128 = @as(i128, n) - @as(i128, q) * @as(i128, d);
    const result: i128 = switch (mode) {
        .floor => q,
        .ceiling => if (rem != 0) @as(i128, q) + 1 else q,
        .truncate => @divTrunc(n, d),
        .round => blk: {
            const twice = rem * 2;
            if (twice > d) break :blk @as(i128, q) + 1;
            if (twice < d) break :blk q;
            // Exactly halfway: pick the even neighbour.
            break :blk if (@rem(q, 2) == 0) @as(i128, q) else @as(i128, q) + 1;
        },
    };
    if (result > std.math.maxInt(i64) or result < std.math.minInt(i64)) return ElzError.Overflow;
    return Value{ .exact_integer = @intCast(result) };
}

pub fn floor_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => return v,
        .rational => |r| return roundRational(r.numerator, r.denominator, .floor),
        // An inexact argument yields an inexact integer (R7RS 6.2.6).
        .number => |n| return Value{ .number = @floor(n) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn ceiling(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => return v,
        .rational => |r| return roundRational(r.numerator, r.denominator, .ceiling),
        .number => |n| return Value{ .number = @ceil(n) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn round_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => return v,
        .rational => |r| return roundRational(r.numerator, r.denominator, .round),
        .number => |n| return Value{ .number = roundHalfEven(n) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn truncate(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => return v,
        .rational => |r| return roundRational(r.numerator, r.denominator, .truncate),
        .number => |n| return Value{ .number = @trunc(n) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn expt(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (!a.isNumeric() or !b.isNumeric()) return ElzError.InvalidArgument;
    // Exact integer base, non-negative exact integer exponent: exact result
    if (isExactKind(a) and b == .exact_integer) {
        const p = ratParts(a);
        const negative = b.exact_integer < 0;
        if (negative and p.n == 0) return ElzError.DivisionByZero;
        // Magnitude of the exponent, computed without overflowing on minInt.
        const exp_abs: u64 = if (negative) absU64(b.exact_integer) else @intCast(b.exact_integer);
        var num: i64 = 1;
        var den: i64 = 1;
        var base_n = p.n;
        var base_d = p.d;
        var exp = exp_abs;
        while (exp > 0) : (exp >>= 1) {
            if ((exp & 1) == 1) {
                num = try mulOv(num, base_n);
                den = try mulOv(den, base_d);
            }
            if (exp > 1) {
                base_n = try mulOv(base_n, base_n);
                base_d = try mulOv(base_d, base_d);
            }
        }
        // A negative exponent inverts the result.
        return if (negative)
            normalizeRational(den, num, env.allocator)
        else
            normalizeRational(num, den, env.allocator);
    }
    const af = a.asFloat() orelse return ElzError.InvalidArgument;
    const bf = b.asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.pow(f64, af, bf) };
}

pub fn exp_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.exp(f) };
}

pub fn even_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => |i| return Value{ .boolean = @mod(i, 2) == 0 },
        .number => |n| {
            if (@floor(n) != n) return Value{ .boolean = false };
            const max_safe: f64 = @floatFromInt(std.math.maxInt(i64));
            const min_safe: f64 = @floatFromInt(std.math.minInt(i64));
            if (n > max_safe or n < min_safe) return ElzError.InvalidArgument;
            const i: i64 = @intFromFloat(n);
            return Value{ .boolean = @mod(i, 2) == 0 };
        },
        else => return ElzError.InvalidArgument,
    }
}

pub fn odd_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => |i| return Value{ .boolean = @mod(i, 2) != 0 },
        .number => |n| {
            if (@floor(n) != n) return Value{ .boolean = false };
            const max_safe: f64 = @floatFromInt(std.math.maxInt(i64));
            const min_safe: f64 = @floatFromInt(std.math.minInt(i64));
            if (n > max_safe or n < min_safe) return ElzError.InvalidArgument;
            const i: i64 = @intFromFloat(n);
            return Value{ .boolean = @mod(i, 2) != 0 };
        },
        else => return ElzError.InvalidArgument,
    }
}

pub fn zero_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return Value{ .boolean = switch (v) {
        .exact_integer => |i| i == 0,
        .rational => |r| r.numerator == 0,
        .number => |n| n == 0,
        .complex => |c| c.real == 0 and c.imag == 0,
        else => return ElzError.InvalidArgument,
    } };
}

pub fn positive_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return Value{ .boolean = switch (v) {
        .exact_integer => |i| i > 0,
        .rational => |r| r.numerator > 0,
        .number => |n| n > 0,
        else => return ElzError.InvalidArgument,
    } };
}

pub fn negative_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return Value{ .boolean = switch (v) {
        .exact_integer => |i| i < 0,
        .rational => |r| r.numerator < 0,
        .number => |n| n < 0,
        else => return ElzError.InvalidArgument,
    } };
}

pub fn abs_fn(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .exact_integer => |i| blk: {
            if (i == std.math.minInt(i64)) break :blk ElzError.Overflow;
            break :blk Value{ .exact_integer = if (i < 0) -i else i };
        },
        .rational => |r| blk: {
            if (r.numerator == std.math.minInt(i64)) break :blk ElzError.Overflow;
            const new_r = env.allocator.create(core.Rational) catch return ElzError.OutOfMemory;
            new_r.* = .{ .numerator = if (r.numerator < 0) -r.numerator else r.numerator, .denominator = r.denominator };
            break :blk Value{ .rational = new_r };
        },
        .number => |n| Value{ .number = @abs(n) },
        else => ElzError.InvalidArgument,
    };
}

pub fn exact_to_inexact(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .exact_integer => |i| Value{ .number = @floatFromInt(i) },
        .rational => |r| Value{ .number = @as(f64, @floatFromInt(r.numerator)) / @as(f64, @floatFromInt(r.denominator)) },
        .number => v,
        .complex => v,
        else => ElzError.InvalidArgument,
    };
}

pub fn inexact_to_exact(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .exact_integer, .rational => v,
        .number => |n| blk: {
            if (std.math.isNan(n) or std.math.isInf(n)) break :blk ElzError.InvalidArgument;
            const r = dyadicFromFloat(n) catch break :blk v; // exact form out of range: keep as inexact
            break :blk try ratToValue(r, false, env.allocator);
        },
        else => ElzError.InvalidArgument,
    };
}

pub fn quotient(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .exact_integer or b != .exact_integer) return ElzError.InvalidArgument;
    if (b.exact_integer == 0) return ElzError.DivisionByZero;
    return Value{ .exact_integer = @divTrunc(a.exact_integer, b.exact_integer) };
}

pub fn remainder(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .exact_integer or b != .exact_integer) return ElzError.InvalidArgument;
    if (b.exact_integer == 0) return ElzError.DivisionByZero;
    return Value{ .exact_integer = @rem(a.exact_integer, b.exact_integer) };
}

pub fn modulo(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .exact_integer or b != .exact_integer) return ElzError.InvalidArgument;
    if (b.exact_integer == 0) return ElzError.DivisionByZero;
    return Value{ .exact_integer = @mod(a.exact_integer, b.exact_integer) };
}

pub fn gcd_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .exact_integer = 0 };
    var acc: u64 = 0;
    for (args.items) |arg| {
        if (arg != .exact_integer) return ElzError.InvalidArgument;
        const a = absU64(arg.exact_integer);
        acc = if (acc == 0) a else gcdU64(acc, a);
    }
    if (acc > @as(u64, std.math.maxInt(i64))) return ElzError.Overflow;
    return Value{ .exact_integer = @intCast(acc) };
}

pub fn lcm_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .exact_integer = 1 };
    var acc: u64 = 1;
    for (args.items) |arg| {
        if (arg != .exact_integer) return ElzError.InvalidArgument;
        const a = absU64(arg.exact_integer);
        if (a == 0) return Value{ .exact_integer = 0 };
        const g = gcdU64(acc, a);
        const prod = @mulWithOverflow(acc, a / g);
        if (prod[1] != 0) return ElzError.Overflow;
        acc = prod[0];
    }
    if (acc > @as(u64, std.math.maxInt(i64))) return ElzError.Overflow;
    return Value{ .exact_integer = @intCast(acc) };
}

// --- Rational accessors ---

const Rat128 = struct { n: i128, d: i128 };

const RAT128_LIMIT: i128 = 1 << 96;

fn gcdI128(a: i128, b: i128) i128 {
    var x = if (a < 0) -a else a;
    var y = if (b < 0) -b else b;
    while (y != 0) {
        const t = y;
        y = @rem(x, y);
        x = t;
    }
    return x;
}

fn ratNorm(n: i128, d: i128) ElzError!Rat128 {
    if (d == 0) return ElzError.DivisionByZero;
    const sign: i128 = if (d < 0) -1 else 1;
    const g = gcdI128(n, d);
    const rn = if (g == 0) n else sign * @divExact(n, g);
    const rd = if (g == 0) d else sign * @divExact(d, g);
    if (rn > RAT128_LIMIT or rn < -RAT128_LIMIT or rd > RAT128_LIMIT) return ElzError.Overflow;
    return .{ .n = rn, .d = rd };
}

fn ratSub128(a: Rat128, b: Rat128) ElzError!Rat128 {
    return ratNorm(a.n * b.d - b.n * a.d, a.d * b.d);
}

fn ratAdd128(a: Rat128, b: Rat128) ElzError!Rat128 {
    return ratNorm(a.n * b.d + b.n * a.d, a.d * b.d);
}

fn ratRecip128(a: Rat128) ElzError!Rat128 {
    return ratNorm(a.d, a.n);
}

fn ratLt128(a: Rat128, b: Rat128) bool {
    return a.n * b.d < b.n * a.d;
}

fn ratFloor128(a: Rat128) Rat128 {
    return .{ .n = @divFloor(a.n, a.d), .d = 1 };
}

/// Converts a finite f64 to its exact rational value. Binary floats are dyadic
/// rationals, so repeated doubling terminates; values whose exact form does not
/// fit in the i128 budget return Overflow.
fn dyadicFromFloat(x: f64) ElzError!Rat128 {
    if (std.math.isNan(x) or std.math.isInf(x)) return ElzError.InvalidArgument;
    var v = x;
    var d: i128 = 1;
    while (@floor(v) != v) {
        v *= 2;
        d *= 2;
        if (d > RAT128_LIMIT) return ElzError.Overflow;
    }
    const limit: f64 = @floatFromInt(RAT128_LIMIT);
    if (v > limit or v < -limit) return ElzError.Overflow;
    return .{ .n = @intFromFloat(v), .d = d };
}

fn ratFromValue(v: Value) ElzError!Rat128 {
    return switch (v) {
        .exact_integer => |i| .{ .n = i, .d = 1 },
        .rational => |r| .{ .n = r.numerator, .d = r.denominator },
        .number => |n| dyadicFromFloat(n),
        else => ElzError.InvalidArgument,
    };
}

fn ratToValue(r: Rat128, inexact: bool, alloc: std.mem.Allocator) ElzError!Value {
    if (inexact) {
        return Value{ .number = @as(f64, @floatFromInt(r.n)) / @as(f64, @floatFromInt(r.d)) };
    }
    if (r.n > std.math.maxInt(i64) or r.n < std.math.minInt(i64) or r.d > std.math.maxInt(i64)) {
        return ElzError.Overflow;
    }
    return normalizeRational(@intCast(r.n), @intCast(r.d), alloc);
}

pub fn numerator_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .exact_integer => v,
        .rational => |r| Value{ .exact_integer = r.numerator },
        .number => |n| blk: {
            const r = try dyadicFromFloat(n);
            break :blk Value{ .number = @floatFromInt(r.n) };
        },
        else => ElzError.InvalidArgument,
    };
}

pub fn denominator_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .exact_integer => Value{ .exact_integer = 1 },
        .rational => |r| Value{ .exact_integer = r.denominator },
        .number => |n| blk: {
            const r = try dyadicFromFloat(n);
            break :blk Value{ .number = @floatFromInt(r.d) };
        },
        else => ElzError.InvalidArgument,
    };
}

/// Simplest rational in [x, y], assuming 0 < x < y.
fn simplestPositive(x: Rat128, y: Rat128) ElzError!Rat128 {
    const fx = ratFloor128(x);
    const fy = ratFloor128(y);
    if (fx.n == x.n and x.d == 1) return x;
    if (fx.n == fy.n) {
        const inner = try simplestPositive(
            try ratRecip128(try ratSub128(y, fy)),
            try ratRecip128(try ratSub128(x, fx)),
        );
        return ratAdd128(fx, try ratRecip128(inner));
    }
    return .{ .n = fx.n + 1, .d = 1 };
}

fn simplestRational(lo: Rat128, hi: Rat128) ElzError!Rat128 {
    if (ratLt128(hi, lo)) return simplestRational(hi, lo);
    if (!ratLt128(lo, hi)) return lo;
    const zero = Rat128{ .n = 0, .d = 1 };
    if (ratLt128(zero, lo)) return simplestPositive(lo, hi);
    if (ratLt128(hi, zero)) {
        const r = try simplestPositive(.{ .n = -hi.n, .d = hi.d }, .{ .n = -lo.n, .d = lo.d });
        return .{ .n = -r.n, .d = r.d };
    }
    return zero;
}

pub fn rationalize_fn(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const x = try ratFromValue(args.items[0]);
    const tol = try ratFromValue(args.items[1]);
    const abs_tol = Rat128{ .n = if (tol.n < 0) -tol.n else tol.n, .d = tol.d };
    const result = try simplestRational(try ratSub128(x, abs_tol), try ratAdd128(x, abs_tol));
    const inexact = args.items[0] == .number or args.items[1] == .number;
    return ratToValue(result, inexact, env.allocator);
}

// --- R7RS numeric names and predicates ---

pub fn exact_integer_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .exact_integer };
}

pub fn square_fn(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (!v.isNumeric()) return ElzError.InvalidArgument;
    return numMul(v, v, env.allocator);
}

pub fn exact_integer_sqrt(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (v != .exact_integer or v.exact_integer < 0) return ElzError.InvalidArgument;
    const n: u64 = @intCast(v.exact_integer);
    const s = isqrt(n);
    const items = env.allocator.alloc(Value, 2) catch return ElzError.OutOfMemory;
    items[0] = Value{ .exact_integer = @intCast(s) };
    items[1] = Value{ .exact_integer = @intCast(n - s * s) };
    const mv = env.allocator.create(core.MultiValues) catch return ElzError.OutOfMemory;
    mv.* = .{ .items = items };
    return Value{ .multi_values = mv };
}

pub fn finite_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return switch (args.items[0]) {
        .exact_integer, .rational => Value{ .boolean = true },
        .number => |n| Value{ .boolean = std.math.isFinite(n) },
        .complex => |c| Value{ .boolean = std.math.isFinite(c.real) and std.math.isFinite(c.imag) },
        else => ElzError.InvalidArgument,
    };
}

pub fn infinite_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return switch (args.items[0]) {
        .exact_integer, .rational => Value{ .boolean = false },
        .number => |n| Value{ .boolean = std.math.isInf(n) },
        .complex => |c| Value{ .boolean = std.math.isInf(c.real) or std.math.isInf(c.imag) },
        else => ElzError.InvalidArgument,
    };
}

pub fn nan_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return switch (args.items[0]) {
        .exact_integer, .rational => Value{ .boolean = false },
        .number => |n| Value{ .boolean = std.math.isNan(n) },
        .complex => |c| Value{ .boolean = std.math.isNan(c.real) or std.math.isNan(c.imag) },
        else => ElzError.InvalidArgument,
    };
}

// --- Floor and truncate division families ---

fn intDivArgs(args: core.ValueList) ElzError!struct { a: i64, b: i64 } {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .exact_integer or b != .exact_integer) return ElzError.InvalidArgument;
    if (b.exact_integer == 0) return ElzError.DivisionByZero;
    if (a.exact_integer == std.math.minInt(i64) and b.exact_integer == -1) return ElzError.Overflow;
    return .{ .a = a.exact_integer, .b = b.exact_integer };
}

fn twoValues(a: Value, b: Value, alloc: std.mem.Allocator) ElzError!Value {
    const items = alloc.alloc(Value, 2) catch return ElzError.OutOfMemory;
    items[0] = a;
    items[1] = b;
    const mv = alloc.create(core.MultiValues) catch return ElzError.OutOfMemory;
    mv.* = .{ .items = items };
    return Value{ .multi_values = mv };
}

pub fn floor_div(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const p = try intDivArgs(args);
    return twoValues(
        Value{ .exact_integer = @divFloor(p.a, p.b) },
        Value{ .exact_integer = @mod(p.a, p.b) },
        env.allocator,
    );
}

pub fn floor_quotient(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const p = try intDivArgs(args);
    return Value{ .exact_integer = @divFloor(p.a, p.b) };
}

pub fn floor_remainder(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const p = try intDivArgs(args);
    return Value{ .exact_integer = @mod(p.a, p.b) };
}

pub fn truncate_div(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const p = try intDivArgs(args);
    return twoValues(
        Value{ .exact_integer = @divTrunc(p.a, p.b) },
        Value{ .exact_integer = @rem(p.a, p.b) },
        env.allocator,
    );
}

pub fn truncate_quotient(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const p = try intDivArgs(args);
    return Value{ .exact_integer = @divTrunc(p.a, p.b) };
}

pub fn truncate_remainder(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const p = try intDivArgs(args);
    return Value{ .exact_integer = @rem(p.a, p.b) };
}

// --- Complex accessors and constructors ---

fn realToF64(v: Value) ElzError!f64 {
    return switch (v) {
        .number, .exact_integer, .rational => toF64(v),
        else => ElzError.InvalidArgument,
    };
}

pub fn make_rectangular(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const re = try realToF64(args.items[0]);
    const im = try realToF64(args.items[1]);
    const c = env.allocator.create(core.Complex) catch return ElzError.OutOfMemory;
    c.* = .{ .real = re, .imag = im };
    return Value{ .complex = c };
}

pub fn make_polar(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const mag = try realToF64(args.items[0]);
    const ang = try realToF64(args.items[1]);
    const c = env.allocator.create(core.Complex) catch return ElzError.OutOfMemory;
    c.* = .{ .real = mag * std.math.cos(ang), .imag = mag * std.math.sin(ang) };
    return Value{ .complex = c };
}

pub fn real_part(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .complex => |c| Value{ .number = c.real },
        .number, .exact_integer, .rational => v,
        else => ElzError.InvalidArgument,
    };
}

pub fn imag_part(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .complex => |c| Value{ .number = c.imag },
        .number, .exact_integer, .rational => Value{ .exact_integer = 0 },
        else => ElzError.InvalidArgument,
    };
}

pub fn magnitude(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (v == .complex) {
        return Value{ .number = std.math.hypot(v.complex.real, v.complex.imag) };
    }
    return abs_fn(interp, env, args, fuel);
}

pub fn angle(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .complex => |c| Value{ .number = std.math.atan2(c.imag, c.real) },
        .number, .exact_integer, .rational => if (toF64(v) < 0)
            Value{ .number = std.math.pi }
        else
            Value{ .exact_integer = 0 },
        else => ElzError.InvalidArgument,
    };
}

test "math primitives" {
    const allocator = std.testing.allocator;
    const testing = std.testing;
    var interp_stub: interpreter.Interpreter = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .root_env = undefined,
        .last_error_message = null,
        .module_cache = undefined,
    };
    const env_stub = try core.Environment.init(allocator, null);
    defer {
        env_stub.bindings.deinit();
        allocator.destroy(env_stub);
    }
    var fuel: u64 = 1000;

    var args = core.ValueList.init(allocator);
    defer args.deinit();

    // exact + exact -> exact
    try args.append(Value{ .exact_integer = 1 });
    try args.append(Value{ .exact_integer = 2 });
    var result = try add(&interp_stub, env_stub, args, &fuel);
    try testing.expect(result == .exact_integer);
    try testing.expectEqual(@as(i64, 3), result.exact_integer);

    // exact - exact -> exact
    args.clearRetainingCapacity();
    try args.append(Value{ .exact_integer = 5 });
    try args.append(Value{ .exact_integer = 2 });
    result = try sub(&interp_stub, env_stub, args, &fuel);
    try testing.expect(result == .exact_integer);
    try testing.expectEqual(@as(i64, 3), result.exact_integer);

    // 1/3 rational
    args.clearRetainingCapacity();
    try args.append(Value{ .exact_integer = 1 });
    try args.append(Value{ .exact_integer = 3 });
    result = try div(&interp_stub, env_stub, args, &fuel);
    try testing.expect(result == .rational);
    try testing.expectEqual(@as(i64, 1), result.rational.numerator);
    try testing.expectEqual(@as(i64, 3), result.rational.denominator);
    allocator.destroy(result.rational);

    // div by zero
    args.clearRetainingCapacity();
    try args.append(Value{ .exact_integer = 6 });
    try args.append(Value{ .exact_integer = 0 });
    const div_err = div(&interp_stub, env_stub, args, &fuel);
    try testing.expectError(ElzError.DivisionByZero, div_err);

    // mixed exact + inexact -> inexact
    args.clearRetainingCapacity();
    try args.append(Value{ .exact_integer = 1 });
    try args.append(Value{ .number = 1.0 });
    result = try add(&interp_stub, env_stub, args, &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 2.0), result.number);
}
