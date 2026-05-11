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

pub fn le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const o = try cmp2(args.items[0], args.items[1]);
    return Value{ .boolean = o != .gt };
}

pub fn lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const o = try cmp2(args.items[0], args.items[1]);
    return Value{ .boolean = o == .lt };
}

pub fn ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const o = try cmp2(args.items[0], args.items[1]);
    return Value{ .boolean = o != .lt };
}

pub fn gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const o = try cmp2(args.items[0], args.items[1]);
    return Value{ .boolean = o == .gt };
}

pub fn eq_num(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (!a.isNumeric() or !b.isNumeric()) return ElzError.InvalidArgument;
    if (a == .complex or b == .complex) {
        const ar: f64 = if (a == .complex) a.complex.real else toF64(a);
        const ai: f64 = if (a == .complex) a.complex.imag else 0;
        const br: f64 = if (b == .complex) b.complex.real else toF64(b);
        const bi: f64 = if (b == .complex) b.complex.imag else 0;
        return Value{ .boolean = ar == br and ai == bi };
    }
    const o = try cmp2(a, b);
    return Value{ .boolean = o == .eq };
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

pub fn sqrt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (!v.isNumeric()) return ElzError.InvalidArgument;
    if (v == .exact_integer and v.exact_integer >= 0) {
        const n: u64 = @intCast(v.exact_integer);
        const r = isqrt(n);
        if (r * r == n) return Value{ .exact_integer = @intCast(r) };
    }
    const f = v.asFloat() orelse return ElzError.InvalidArgument;
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

pub fn log(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const f = args.items[0].asFloat() orelse return ElzError.InvalidArgument;
    return Value{ .number = std.math.log(f64, std.math.e, f) };
}

pub fn max(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    var best = args.items[0];
    if (!best.isNumeric()) return ElzError.InvalidArgument;
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        const o = try cmp2(arg, best);
        if (o == .gt) best = arg;
    }
    return best;
}

pub fn min(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    var best = args.items[0];
    if (!best.isNumeric()) return ElzError.InvalidArgument;
    for (args.items[1..]) |arg| {
        if (!arg.isNumeric()) return ElzError.InvalidArgument;
        const o = try cmp2(arg, best);
        if (o == .lt) best = arg;
    }
    return best;
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

pub fn floor_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => return v,
        .rational => |r| {
            const q = @divTrunc(r.numerator, r.denominator);
            const rem = @mod(r.numerator, r.denominator); // r.denominator > 0
            const adj: i64 = if (rem < 0) -1 else 0;
            return Value{ .exact_integer = q + adj };
        },
        .number => |n| return Value{ .exact_integer = @intFromFloat(@floor(n)) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn ceiling(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => return v,
        .rational => |r| {
            const q = @divTrunc(r.numerator, r.denominator);
            const rem = @mod(r.numerator, r.denominator);
            const adj: i64 = if (rem > 0) 1 else 0;
            return Value{ .exact_integer = q + adj };
        },
        .number => |n| return Value{ .exact_integer = @intFromFloat(@ceil(n)) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn round_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => return v,
        .rational => |r| {
            // round half-to-even toward nearest integer
            const f = @as(f64, @floatFromInt(r.numerator)) / @as(f64, @floatFromInt(r.denominator));
            return Value{ .exact_integer = @intFromFloat(@round(f)) };
        },
        .number => |n| return Value{ .exact_integer = @intFromFloat(@round(n)) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn truncate(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    switch (v) {
        .exact_integer => return v,
        .rational => |r| return Value{ .exact_integer = @divTrunc(r.numerator, r.denominator) },
        .number => |n| return Value{ .exact_integer = @intFromFloat(@trunc(n)) },
        else => return ElzError.InvalidArgument,
    }
}

pub fn expt(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (!a.isNumeric() or !b.isNumeric()) return ElzError.InvalidArgument;
    // Exact integer base, non-negative exact integer exponent: exact result
    if (a == .exact_integer and b == .exact_integer and b.exact_integer >= 0) {
        var result: i64 = 1;
        var base = a.exact_integer;
        var exp: u64 = @intCast(b.exact_integer);
        while (exp > 0) : (exp >>= 1) {
            if ((exp & 1) == 1) {
                result = try mulOv(result, base);
            }
            if (exp > 1) base = try mulOv(base, base);
        }
        return Value{ .exact_integer = result };
    }
    _ = env;
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

pub fn inexact_to_exact(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return switch (v) {
        .exact_integer, .rational => v,
        .number => |n| blk: {
            if (std.math.isNan(n) or std.math.isInf(n)) break :blk ElzError.InvalidArgument;
            if (@floor(n) == n) {
                const max_safe: f64 = @floatFromInt(std.math.maxInt(i64));
                const min_safe: f64 = @floatFromInt(std.math.minInt(i64));
                if (n <= max_safe and n >= min_safe) {
                    break :blk Value{ .exact_integer = @intFromFloat(n) };
                }
            }
            break :blk v; // lossy: keep as inexact
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
