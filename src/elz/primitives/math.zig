const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");
const bigint = @import("../bigint.zig");

// --- Numeric tower helpers ---

fn toF64(v: Value) f64 {
    return switch (v) {
        .number => |n| n,
        .exact_integer => |n| @as(f64, @floatFromInt(n)),
        .bigint => |b| bigint.toF64(b),
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
    return v == .exact_integer or v == .bigint or v == .rational;
}

fn isRealKind(v: Value) bool {
    return v == .number or v == .exact_integer or v == .bigint or v == .rational;
}

/// Exact arithmetic on two exact operands. Integer results that overflow an
/// i64 promote to big integers; rationals keep i64 components, so a rational
/// combined with a big integer reports Overflow.
fn exactArith(op: bigint.Op, a: Value, b: Value, alloc: std.mem.Allocator) ElzError!Value {
    if (bigint.isInteger(a) and bigint.isInteger(b)) {
        if (a == .exact_integer and b == .exact_integer) {
            const x = a.exact_integer;
            const y = b.exact_integer;
            const r = switch (op) {
                .add => @addWithOverflow(x, y),
                .sub => @subWithOverflow(x, y),
                .mul => @mulWithOverflow(x, y),
            };
            if (r[1] == 0) return Value{ .exact_integer = r[0] };
        }
        return bigint.arith(alloc, op, a, b);
    }
    if (a == .bigint or b == .bigint) return ElzError.Overflow;
    const ap = ratParts(a);
    const bp = ratParts(b);
    switch (op) {
        .add, .sub => {
            const t1 = try mulOv(ap.n, bp.d);
            const t2 = try mulOv(bp.n, ap.d);
            const num = if (op == .add) try addOv(t1, t2) else try subOv(t1, t2);
            const den = try mulOv(ap.d, bp.d);
            return normalizeRational(num, den, alloc);
        },
        .mul => {
            const num = try mulOv(ap.n, bp.n);
            const den = try mulOv(ap.d, bp.d);
            return normalizeRational(num, den, alloc);
        },
    }
}

fn numAdd(a: Value, b: Value, alloc: std.mem.Allocator) ElzError!Value {
    if (isExactKind(a) and isExactKind(b)) return exactArith(.add, a, b, alloc);
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
    if (isExactKind(a) and isExactKind(b)) return exactArith(.sub, a, b, alloc);
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
    if (isExactKind(a) and isExactKind(b)) return exactArith(.mul, a, b, alloc);
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
    if (a == .bigint or b == .bigint) {
        if (!bigint.isInteger(a) or !bigint.isInteger(b)) return ElzError.Overflow;
        // An exact quotient stays an integer; anything else would need a
        // rational with big components, which this build does not have.
        const d = try bigint.divide(alloc, .trunc, a, b);
        if (d.r == .exact_integer and d.r.exact_integer == 0) return d.q;
        return ElzError.Overflow;
    }
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
        // An exact zero divisor is an error; an inexact one follows IEEE.
        if (denom == 0 and isExactKind(b)) return ElzError.DivisionByZero;
        const c = alloc.create(core.Complex) catch return ElzError.OutOfMemory;
        c.* = .{ .real = (ar * br + ai * bi) / denom, .imag = (ai * br - ar * bi) / denom };
        return Value{ .complex = c };
    }
    // R7RS: dividing by an exact zero is an error, but an inexact zero
    // divisor yields an infinity or NaN.
    if (isExactKind(b) and ratParts(b).n == 0) return ElzError.DivisionByZero;
    return Value{ .number = toF64(a) / toF64(b) };
}

fn numNegate(a: Value, alloc: std.mem.Allocator) ElzError!Value {
    return switch (a) {
        .exact_integer => |n| blk: {
            if (n == std.math.minInt(i64)) break :blk try bigint.negate(alloc, a);
            break :blk Value{ .exact_integer = -n };
        },
        .bigint => try bigint.negate(alloc, a),
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

pub fn add(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .exact_integer = 0 };
    var acc = args.items[0];
    if (!acc.isNumeric()) return interp.fail(ElzError.InvalidArgument, "+: expected a number, got {s}", .{core.typeName(acc)});
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return interp.fail(ElzError.InvalidArgument, "+: expected a number, got {s}", .{core.typeName(arg)});
        acc = try numAdd(acc, arg, env.allocator);
    }
    return acc;
}

pub fn sub(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    if (!args.items[0].isNumeric()) return interp.fail(ElzError.InvalidArgument, "-: expected a number, got {s}", .{core.typeName(args.items[0])});
    if (args.items.len == 1) {
        return numNegate(args.items[0], env.allocator);
    }
    var acc = args.items[0];
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return interp.fail(ElzError.InvalidArgument, "-: expected a number, got {s}", .{core.typeName(arg)});
        acc = try numSub(acc, arg, env.allocator);
    }
    return acc;
}

pub fn mul(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .exact_integer = 1 };
    var acc = args.items[0];
    if (!acc.isNumeric()) return interp.fail(ElzError.InvalidArgument, "*: expected a number, got {s}", .{core.typeName(acc)});
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return interp.fail(ElzError.InvalidArgument, "*: expected a number, got {s}", .{core.typeName(arg)});
        acc = try numMul(acc, arg, env.allocator);
    }
    return acc;
}

pub fn div(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;
    if (!args.items[0].isNumeric()) return interp.fail(ElzError.InvalidArgument, "/: expected a number, got {s}", .{core.typeName(args.items[0])});
    if (args.items.len == 1) {
        // (/ x) = 1/x
        return numDiv(Value{ .exact_integer = 1 }, args.items[0], env.allocator);
    }
    var acc = args.items[0];
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return interp.fail(ElzError.InvalidArgument, "/: expected a number, got {s}", .{core.typeName(arg)});
        acc = try numDiv(acc, arg, env.allocator);
    }
    return acc;
}

fn cmp2(a: Value, b: Value) ElzError!std.math.Order {
    if (!a.isNumeric() or !b.isNumeric()) return ElzError.InvalidArgument;
    // Exact-exact comparison without float loss
    if (a == .bigint or b == .bigint) {
        if (bigint.isInteger(a) and bigint.isInteger(b)) return bigint.order(a, b);
        if (a == .complex or b == .complex) return ElzError.InvalidArgument;
        if (a == .rational) return if (b.bigint.positive) .lt else .gt; // |rational| < 2^63 <= |bigint|
        if (b == .rational) return if (a.bigint.positive) .gt else .lt;
        // Big integer against a float.
        const big_side = if (a == .bigint) a else b;
        const f = if (a == .bigint) b.number else a.number;
        const o = try cmpBigFloat(big_side, f);
        return if (a == .bigint) o else switch (o) {
            .lt => .gt,
            .gt => .lt,
            .eq => .eq,
        };
    }
    if (isExactKind(a) and isExactKind(b)) {
        const ap = ratParts(a);
        const bp = ratParts(b);
        // ap.n/ap.d vs bp.n/bp.d -> compare ap.n * bp.d vs bp.n * ap.d (both
        // denominators positive). The products can exceed an i64, so widen.
        const lhs = @as(i128, ap.n) * @as(i128, bp.d);
        const rhs = @as(i128, bp.n) * @as(i128, ap.d);
        if (lhs < rhs) return .lt;
        if (lhs > rhs) return .gt;
        return .eq;
    }
    if (a == .complex or b == .complex) return ElzError.InvalidArgument;
    if (a == .number and b == .number) {
        if (a.number < b.number) return .lt;
        if (a.number > b.number) return .gt;
        if (a.number == b.number) return .eq;
        return ElzError.InvalidArgument; // NaN involved: unordered
    }
    // One exact and one inexact operand: compare exactly instead of rounding
    // the exact side to a float, so `=` stays transitive.
    if (a == .number) return switch (try cmpExactFloat(b, a.number)) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
    return cmpExactFloat(a, b.number);
}

fn cmpBigFloat(big: Value, f: f64) ElzError!std.math.Order {
    if (std.math.isNan(f)) return ElzError.InvalidArgument;
    if (std.math.isInf(f)) return if (f > 0) .lt else .gt;
    const approx = toF64(big);
    if (approx < f) return .lt;
    if (approx > f) return .gt;
    // Equal as floats: the float is integral at this magnitude, so compare exactly.
    const exact_f = bigint.fromIntegralFloat(std.heap.page_allocator, f) catch return .eq;
    return bigint.order(big, exact_f);
}

/// Compares an exact number with a float without loss of precision.
fn cmpExactFloat(exact: Value, f: f64) ElzError!std.math.Order {
    if (std.math.isNan(f)) return ElzError.InvalidArgument;
    if (std.math.isInf(f)) return if (f > 0) .lt else .gt;
    const p = ratParts(exact);
    // The float is beyond any i64 magnitude: its sign decides.
    if (f >= 9.3e18 or f <= -9.3e18) return if (f > 0) .lt else .gt;
    // Compare p.n / p.d with f: scale f by the denominator first. The
    // product stays representable when |f * d| < 2^53; beyond that the
    // integer part alone decides, since |p.n| < 2^63 and d <= |p.n|.
    const scaled = f * @as(f64, @floatFromInt(p.d));
    if (@abs(scaled) < 9007199254740992.0) {
        const whole: i64 = @intFromFloat(@floor(scaled));
        const frac = scaled - @floor(scaled);
        if (p.n < whole) return .lt;
        if (p.n > whole) return .gt;
        return if (frac > 0) .lt else .eq;
    }
    const whole: i128 = @intFromFloat(@floor(scaled));
    const n: i128 = p.n;
    if (n < whole) return .lt;
    if (n > whole) return .gt;
    return .eq;
}

/// Chained n-ary comparison: true when every adjacent pair satisfies `ok`.
fn chainCompare(args: core.ValueList, comptime ok: fn (std.math.Order) bool) ElzError!Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;
    for (args.items[0 .. args.items.len - 1], args.items[1..]) |a, b| {
        // A NaN operand makes every ordering false.
        if ((a == .number and std.math.isNan(a.number)) or (b == .number and std.math.isNan(b.number))) {
            if (!a.isNumeric() or !b.isNumeric()) return ElzError.InvalidArgument;
            return Value{ .boolean = false };
        }
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
    if ((a == .number and std.math.isNan(a.number)) or (b == .number and std.math.isNan(b.number))) return false;
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
    if (v == .bigint and v.bigint.positive) {
        const sr = try bigint.sqrtRem(env.allocator, v);
        if (sr.r == .exact_integer and sr.r.exact_integer == 0) return sr.s;
    }
    if (v == .complex) {
        // Principal square root of a complex number, computed from the
        // modulus so that pure imaginary results have an exactly zero real part.
        const c = v.complex;
        const modulus = std.math.hypot(c.real, c.imag);
        const re = std.math.sqrt((modulus + c.real) / 2);
        var im = std.math.sqrt((modulus - c.real) / 2);
        if (c.imag < 0) im = -im;
        const out = env.allocator.create(core.Complex) catch return ElzError.OutOfMemory;
        out.* = .{ .real = re, .imag = im };
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

pub fn log(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    const z = args.items[0];
    if (!z.isNumeric()) return ElzError.InvalidArgument;
    if (args.items.len == 2) {
        const base = args.items[1];
        if (!base.isNumeric()) return ElzError.InvalidArgument;
        if (z == .complex or base == .complex) {
            const num = try complexLog(z, env.allocator);
            const den = try complexLog(base, env.allocator);
            return numDiv(num, den, env.allocator);
        }
        const zf = toF64(z);
        const bf = toF64(base);
        if (zf < 0 or bf < 0) return numDiv(try complexLog(z, env.allocator), try complexLog(base, env.allocator), env.allocator);
        return Value{ .number = @log(zf) / @log(bf) };
    }
    if (z == .complex) return complexLog(z, env.allocator);
    const f = toF64(z);
    if (f < 0) return complexLog(z, env.allocator);
    return Value{ .number = @log(f) };
}

/// Principal complex logarithm; a negative real yields `log|x| + pi i`.
fn complexLog(z: Value, alloc: std.mem.Allocator) ElzError!Value {
    const re: f64 = if (z == .complex) z.complex.real else toF64(z);
    const im: f64 = if (z == .complex) z.complex.imag else 0;
    const c = alloc.create(core.Complex) catch return ElzError.OutOfMemory;
    c.* = .{ .real = @log(std.math.hypot(re, im)), .imag = std.math.atan2(im, re) };
    return Value{ .complex = c };
}

/// Complex exponential.
fn complexExp(z: Value, alloc: std.mem.Allocator) ElzError!Value {
    const re: f64 = if (z == .complex) z.complex.real else toF64(z);
    const im: f64 = if (z == .complex) z.complex.imag else 0;
    const m = @exp(re);
    const c = alloc.create(core.Complex) catch return ElzError.OutOfMemory;
    c.* = .{ .real = m * @cos(im), .imag = m * @sin(im) };
    return Value{ .complex = c };
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
        if (isNanValue(arg) or isNanValue(best)) {
            best = Value{ .number = std.math.nan(f64) };
            continue;
        }
        const o = try cmp2(arg, best);
        if (o == .gt) best = arg;
    }
    return contaminate(best, saw_inexact);
}

fn isNanValue(v: Value) bool {
    return v == .number and std.math.isNan(v.number);
}

pub fn min(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    var best = args.items[0];
    if (!best.isNumeric()) return ElzError.InvalidArgument;
    var saw_inexact = best == .number;
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        if (arg == .number) saw_inexact = true;
        if (isNanValue(arg) or isNanValue(best)) {
            best = Value{ .number = std.math.nan(f64) };
            continue;
        }
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
        .exact_integer, .bigint => return v,
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
        .exact_integer, .bigint => return v,
        .rational => |r| return roundRational(r.numerator, r.denominator, .ceiling),
        .number => |n| return Value{ .number = @ceil(n) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn round_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer, .bigint => return v,
        .rational => |r| return roundRational(r.numerator, r.denominator, .round),
        .number => |n| return Value{ .number = roundHalfEven(n) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn truncate(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer, .bigint => return v,
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
    // Exact integer base and exact integer exponent: an exact result of any size.
    if (bigint.isInteger(a) and b == .exact_integer) {
        const e = b.exact_integer;
        if (e >= 0) {
            if (e > std.math.maxInt(u32)) {
                // Only bases of magnitude at most one have a representable power.
                if (a == .exact_integer and (a.exact_integer == 0 or a.exact_integer == 1)) return a;
                if (a == .exact_integer and a.exact_integer == -1) return Value{ .exact_integer = if (@rem(e, 2) == 0) 1 else -1 };
                return ElzError.Overflow;
            }
            return bigint.pow(env.allocator, a, @intCast(e));
        }
        // Negative exponent: 1 / base^|e|.
        if (a == .exact_integer and a.exact_integer == 0) return ElzError.DivisionByZero;
        const mag: u64 = if (e == std.math.minInt(i64)) @as(u64, 1) << 63 else @intCast(-e);
        if (mag > std.math.maxInt(u32)) return ElzError.Overflow;
        const denom = try bigint.pow(env.allocator, a, @intCast(mag));
        if (denom != .exact_integer) return ElzError.Overflow;
        return normalizeRational(1, denom.exact_integer, env.allocator);
    }
    if (b == .bigint) {
        if (a == .exact_integer and (a.exact_integer == 0 or a.exact_integer == 1)) return a;
        if (a == .exact_integer and a.exact_integer == -1) return Value{ .exact_integer = if (bigint.isOdd(b.bigint)) -1 else 1 };
        if (isExactKind(a)) return ElzError.Overflow;
    }
    if (a == .rational and b == .exact_integer) {
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
    if (a == .complex or b == .complex) {
        // z^w = exp(w * log z), with 0^w = 0 for a nonzero w.
        const ar: f64 = if (a == .complex) a.complex.real else toF64(a);
        const ai: f64 = if (a == .complex) a.complex.imag else 0;
        if (ar == 0 and ai == 0) return Value{ .number = 0.0 };
        const l = try complexLog(a, env.allocator);
        const prod = try numMul(b, l, env.allocator);
        return complexExp(prod, env.allocator);
    }
    const af = toF64(a);
    const bf = toF64(b);
    // A negative base with a non-integer exponent has a complex result.
    if (af < 0 and @floor(bf) != bf) {
        const l = try complexLog(a, env.allocator);
        const prod = try numMul(b, l, env.allocator);
        return complexExp(prod, env.allocator);
    }
    return Value{ .number = std.math.pow(f64, af, bf) };
}

pub fn exp_fn(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const z = args.items[0];
    if (z == .complex) return complexExp(z, env.allocator);
    const f = z.asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.exp(f) };
}

pub fn even_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => |i| return Value{ .boolean = @mod(i, 2) == 0 },
        .bigint => |b| return Value{ .boolean = !bigint.isOdd(b) },
        .number => |n| {
            if (@floor(n) != n) return Value{ .boolean = false };
            const max_safe: f64 = @floatFromInt(std.math.maxInt(i64));
            const min_safe: f64 = @floatFromInt(std.math.minInt(i64));
            // max_safe rounds up to 2^63, which itself does not fit.
            if (n >= max_safe or n < min_safe) return ElzError.InvalidArgument;
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
        .bigint => |b| return Value{ .boolean = bigint.isOdd(b) },
        .number => |n| {
            if (@floor(n) != n) return Value{ .boolean = false };
            const max_safe: f64 = @floatFromInt(std.math.maxInt(i64));
            const min_safe: f64 = @floatFromInt(std.math.minInt(i64));
            if (n >= max_safe or n < min_safe) return ElzError.InvalidArgument;
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
        .bigint => false,
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
        .bigint => |b| b.positive,
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
        .bigint => |b| !b.positive,
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
            if (i == std.math.minInt(i64)) break :blk try bigint.abs(env.allocator, v);
            break :blk Value{ .exact_integer = if (i < 0) -i else i };
        },
        .bigint => try bigint.abs(env.allocator, v),
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
        .bigint => |b| Value{ .number = bigint.toF64(b) },
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
        .exact_integer, .bigint, .rational => v,
        .number => |n| blk: {
            if (std.math.isNan(n) or std.math.isInf(n)) break :blk ElzError.InvalidArgument;
            // Integral floats of any magnitude become exact integers.
            if (@floor(n) == n) break :blk try bigint.fromIntegralFloat(env.allocator, n);
            const r = try dyadicFromFloat(n);
            break :blk try ratToValue(r, false, env.allocator);
        },
        else => ElzError.InvalidArgument,
    };
}

/// Arguments to the integer division operators: exact integers, or inexact
/// integers (R7RS allows both), never a zero divisor. Results are inexact
/// when either argument is.
const IntDiv = struct { a: i64, b: i64, inexact: bool };

fn integerDivArgs(args: core.ValueList) ElzError!IntDiv {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = try integralToI64(args.items[0]);
    const b = try integralToI64(args.items[1]);
    if (b == 0) return ElzError.DivisionByZero;
    return .{ .a = a, .b = b, .inexact = args.items[0] == .number or args.items[1] == .number };
}

fn integralToI64(v: Value) ElzError!i64 {
    return switch (v) {
        .exact_integer => |i| i,
        .number => |n| blk: {
            if (!std.math.isFinite(n) or @floor(n) != n) break :blk ElzError.InvalidArgument;
            if (n >= 9223372036854775808.0 or n < -9223372036854775808.0) break :blk ElzError.InvalidArgument;
            break :blk @intFromFloat(n);
        },
        else => ElzError.InvalidArgument,
    };
}

fn divResult(n: i64, inexact: bool) Value {
    return if (inexact) Value{ .number = @floatFromInt(n) } else Value{ .exact_integer = n };
}

/// True when an integer division needs the big integer path: an operand is
/// a big integer, or the one i64 case whose quotient does not fit.
fn needsBigDiv(args: core.ValueList) bool {
    if (args.items.len != 2) return false;
    const a = args.items[0];
    const b = args.items[1];
    if (a == .bigint or b == .bigint) return bigint.isInteger(a) and bigint.isInteger(b);
    return a == .exact_integer and b == .exact_integer and a.exact_integer == std.math.minInt(i64) and b.exact_integer == -1;
}

fn bigDiv(alloc: std.mem.Allocator, mode: bigint.DivMode, args: core.ValueList) ElzError!bigint.DivResult {
    return bigint.divide(alloc, mode, args.items[0], args.items[1]);
}

pub fn quotient(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (needsBigDiv(args)) return (try bigDiv(env.allocator, .trunc, args)).q;
    const p = try integerDivArgs(args);
    return divResult(@divTrunc(p.a, p.b), p.inexact);
}

pub fn remainder(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (needsBigDiv(args)) return (try bigDiv(env.allocator, .trunc, args)).r;
    const p = try integerDivArgs(args);
    return divResult(@rem(p.a, p.b), p.inexact);
}

pub fn modulo(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (needsBigDiv(args)) return (try bigDiv(env.allocator, .floor, args)).r;
    const p = try integerDivArgs(args);
    return divResult(@mod(p.a, p.b), p.inexact);
}

pub fn gcd_fn(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .exact_integer = 0 };
    var acc: Value = Value{ .exact_integer = 0 };
    var inexact = false;
    for (args.items) |arg| {
        if (arg == .number) inexact = true;
        const a: Value = if (arg == .bigint) arg else Value{ .exact_integer = try integralToI64(arg) };
        acc = try bigint.gcd(env.allocator, acc, a);
    }
    if (inexact) return Value{ .number = toF64(acc) };
    return acc;
}

pub fn lcm_fn(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .exact_integer = 1 };
    var acc: Value = Value{ .exact_integer = 1 };
    var inexact = false;
    for (args.items) |arg| {
        if (arg == .number) inexact = true;
        const raw: Value = if (arg == .bigint) arg else Value{ .exact_integer = try integralToI64(arg) };
        const a = try bigint.abs(env.allocator, raw);
        if (a == .exact_integer and a.exact_integer == 0) return divResult(0, inexact);
        const g = try bigint.gcd(env.allocator, acc, a);
        const reduced = (try bigint.divide(env.allocator, .trunc, a, g)).q;
        acc = try exactArith(.mul, acc, reduced, env.allocator);
    }
    if (inexact) return Value{ .number = toF64(acc) };
    return acc;
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
        .exact_integer, .bigint => v,
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
        .exact_integer, .bigint => Value{ .exact_integer = 1 },
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
    return Value{ .boolean = bigint.isInteger(args.items[0]) };
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
    if (v == .bigint) {
        if (!v.bigint.positive) return ElzError.InvalidArgument;
        const sr = try bigint.sqrtRem(env.allocator, v);
        return twoValues(sr.s, sr.r, env.allocator);
    }
    if (v != .exact_integer or v.exact_integer < 0) return ElzError.InvalidArgument;
    const n: u64 = @intCast(v.exact_integer);
    const s = isqrt(n);
    return twoValues(Value{ .exact_integer = @intCast(s) }, Value{ .exact_integer = @intCast(n - s * s) }, env.allocator);
}

pub fn finite_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return switch (args.items[0]) {
        .exact_integer, .bigint, .rational => Value{ .boolean = true },
        .number => |n| Value{ .boolean = std.math.isFinite(n) },
        .complex => |c| Value{ .boolean = std.math.isFinite(c.real) and std.math.isFinite(c.imag) },
        else => ElzError.InvalidArgument,
    };
}

pub fn infinite_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return switch (args.items[0]) {
        .exact_integer, .bigint, .rational => Value{ .boolean = false },
        .number => |n| Value{ .boolean = std.math.isInf(n) },
        .complex => |c| Value{ .boolean = std.math.isInf(c.real) or std.math.isInf(c.imag) },
        else => ElzError.InvalidArgument,
    };
}

pub fn nan_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return switch (args.items[0]) {
        .exact_integer, .bigint, .rational => Value{ .boolean = false },
        .number => |n| Value{ .boolean = std.math.isNan(n) },
        .complex => |c| Value{ .boolean = std.math.isNan(c.real) or std.math.isNan(c.imag) },
        else => ElzError.InvalidArgument,
    };
}

// --- Floor and truncate division families ---

fn intDivArgs(args: core.ValueList) ElzError!IntDiv {
    const p = try integerDivArgs(args);
    if (p.a == std.math.minInt(i64) and p.b == -1) return ElzError.Overflow;
    return p;
}

fn bigDivValues(alloc: std.mem.Allocator, mode: bigint.DivMode, args: core.ValueList) ElzError!Value {
    const d = try bigDiv(alloc, mode, args);
    return twoValues(d.q, d.r, alloc);
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
    if (needsBigDiv(args)) return bigDivValues(env.allocator, .floor, args);
    const p = try intDivArgs(args);
    return twoValues(divResult(@divFloor(p.a, p.b), p.inexact), divResult(@mod(p.a, p.b), p.inexact), env.allocator);
}

pub fn floor_quotient(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (needsBigDiv(args)) return (try bigDiv(env.allocator, .floor, args)).q;
    const p = try intDivArgs(args);
    return divResult(@divFloor(p.a, p.b), p.inexact);
}

pub fn floor_remainder(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (needsBigDiv(args)) return (try bigDiv(env.allocator, .floor, args)).r;
    const p = try intDivArgs(args);
    return divResult(@mod(p.a, p.b), p.inexact);
}

pub fn truncate_div(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (needsBigDiv(args)) return bigDivValues(env.allocator, .trunc, args);
    const p = try intDivArgs(args);
    return twoValues(divResult(@divTrunc(p.a, p.b), p.inexact), divResult(@rem(p.a, p.b), p.inexact), env.allocator);
}

pub fn truncate_quotient(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (needsBigDiv(args)) return (try bigDiv(env.allocator, .trunc, args)).q;
    const p = try intDivArgs(args);
    return divResult(@divTrunc(p.a, p.b), p.inexact);
}

pub fn truncate_remainder(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (needsBigDiv(args)) return (try bigDiv(env.allocator, .trunc, args)).r;
    const p = try intDivArgs(args);
    return divResult(@rem(p.a, p.b), p.inexact);
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
