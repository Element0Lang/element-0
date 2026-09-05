//! Arbitrary-precision exact integers.
//!
//! Exact integers that fit in an i64 are `Value.exact_integer`; anything
//! larger is `Value.bigint`, an immutable heap object. Every operation here
//! returns values in that normalized form, so the rest of the interpreter
//! only needs to handle `.bigint` where an i64 result can overflow.
const std = @import("std");
const core = @import("core.zig");
const Value = core.Value;
const ElzError = core.ElzError;

pub const Managed = std.math.big.int.Managed;
pub const Const = std.math.big.int.Const;
pub const Limb = std.math.big.Limb;

/// True for both exact integer representations.
pub fn isInteger(v: Value) bool {
    return v == .exact_integer or v == .bigint;
}

pub fn constOf(b: *const core.BigInt) Const {
    return .{ .limbs = b.limbs, .positive = b.positive };
}

/// Loads an exact integer value into a fresh big integer.
pub fn fromValue(alloc: std.mem.Allocator, v: Value) ElzError!Managed {
    switch (v) {
        .exact_integer => |i| return Managed.initSet(alloc, i) catch return ElzError.OutOfMemory,
        .bigint => |b| return constOf(b).toManaged(alloc) catch return ElzError.OutOfMemory,
        else => return ElzError.InvalidArgument,
    }
}

/// Converts a big integer to a value, as an `exact_integer` when it fits.
pub fn toValue(alloc: std.mem.Allocator, m: *const Managed) ElzError!Value {
    if (m.fits(i64)) return Value{ .exact_integer = m.toInt(i64) catch unreachable };
    const c = m.toConst();
    const limbs = alloc.dupe(Limb, c.limbs) catch return ElzError.OutOfMemory;
    const b = alloc.create(core.BigInt) catch return ElzError.OutOfMemory;
    b.* = .{ .limbs = limbs, .positive = c.positive };
    return Value{ .bigint = b };
}

pub const Op = enum { add, sub, mul };

/// Exact integer arithmetic on any mix of `exact_integer` and `bigint`.
pub fn arith(alloc: std.mem.Allocator, op: Op, a: Value, b: Value) ElzError!Value {
    const x = try fromValue(alloc, a);
    const y = try fromValue(alloc, b);
    var r = Managed.init(alloc) catch return ElzError.OutOfMemory;
    switch (op) {
        .add => r.add(&x, &y) catch return ElzError.OutOfMemory,
        .sub => r.sub(&x, &y) catch return ElzError.OutOfMemory,
        .mul => r.mul(&x, &y) catch return ElzError.OutOfMemory,
    }
    return toValue(alloc, &r);
}

pub const DivMode = enum { trunc, floor };
pub const DivResult = struct { q: Value, r: Value };

/// Integer division; `b` must not be zero. Returns quotient and remainder.
pub fn divide(alloc: std.mem.Allocator, mode: DivMode, a: Value, b: Value) ElzError!DivResult {
    const x = try fromValue(alloc, a);
    const y = try fromValue(alloc, b);
    if (y.eqlZero()) return ElzError.DivisionByZero;
    var q = Managed.init(alloc) catch return ElzError.OutOfMemory;
    var r = Managed.init(alloc) catch return ElzError.OutOfMemory;
    switch (mode) {
        .trunc => q.divTrunc(&r, &x, &y) catch return ElzError.OutOfMemory,
        .floor => q.divFloor(&r, &x, &y) catch return ElzError.OutOfMemory,
    }
    return .{ .q = try toValue(alloc, &q), .r = try toValue(alloc, &r) };
}

pub fn negate(alloc: std.mem.Allocator, a: Value) ElzError!Value {
    var x = try fromValue(alloc, a);
    x.negate();
    return toValue(alloc, &x);
}

pub fn abs(alloc: std.mem.Allocator, a: Value) ElzError!Value {
    var x = try fromValue(alloc, a);
    x.abs();
    return toValue(alloc, &x);
}

pub fn gcd(alloc: std.mem.Allocator, a: Value, b: Value) ElzError!Value {
    var x = try fromValue(alloc, a);
    var y = try fromValue(alloc, b);
    x.abs();
    y.abs();
    if (x.eqlZero()) return toValue(alloc, &y);
    if (y.eqlZero()) return toValue(alloc, &x);
    var r = Managed.init(alloc) catch return ElzError.OutOfMemory;
    r.gcd(&x, &y) catch return ElzError.OutOfMemory;
    return toValue(alloc, &r);
}

/// `base` to a non-negative integer power.
pub fn pow(alloc: std.mem.Allocator, base: Value, exponent: u32) ElzError!Value {
    const x = try fromValue(alloc, base);
    var r = Managed.init(alloc) catch return ElzError.OutOfMemory;
    r.pow(&x, exponent) catch return ElzError.OutOfMemory;
    return toValue(alloc, &r);
}

/// Floor of the square root of a non-negative integer, and the remainder.
pub fn sqrtRem(alloc: std.mem.Allocator, a: Value) ElzError!struct { s: Value, r: Value } {
    const x = try fromValue(alloc, a);
    if (!x.isPositive() and !x.eqlZero()) return ElzError.InvalidArgument;
    var s = Managed.init(alloc) catch return ElzError.OutOfMemory;
    s.sqrt(&x) catch return ElzError.OutOfMemory;
    var sq = Managed.init(alloc) catch return ElzError.OutOfMemory;
    sq.mul(&s, &s) catch return ElzError.OutOfMemory;
    var rem = Managed.init(alloc) catch return ElzError.OutOfMemory;
    rem.sub(&x, &sq) catch return ElzError.OutOfMemory;
    return .{ .s = try toValue(alloc, &s), .r = try toValue(alloc, &rem) };
}

pub fn order(a: Value, b: Value) std.math.Order {
    var abuf: [limbs_per_u64]Limb = undefined;
    var bbuf: [limbs_per_u64]Limb = undefined;
    return constFor(a, &abuf).order(constFor(b, &bbuf));
}

/// Limbs needed to hold an i64 magnitude: one on 64-bit targets, two on
/// 32-bit targets such as wasm32.
const limbs_per_u64 = @sizeOf(u64) / @sizeOf(Limb);

fn constFor(v: Value, buf: *[limbs_per_u64]Limb) Const {
    switch (v) {
        .bigint => |b| return constOf(b),
        .exact_integer => |i| {
            const mag: u64 = if (i < 0) @as(u64, @intCast(-@as(i128, i))) else @intCast(i);
            if (limbs_per_u64 == 1) {
                buf[0] = @intCast(mag);
                return .{ .limbs = buf[0..1], .positive = i >= 0 };
            }
            buf[0] = @truncate(mag);
            buf[1] = @truncate(mag >> 32);
            // `Const` expects no leading zero limb.
            const len: usize = if (buf[1] == 0) 1 else 2;
            return .{ .limbs = buf[0..len], .positive = i >= 0 };
        },
        else => unreachable,
    }
}

pub fn toF64(b: *const core.BigInt) f64 {
    return constOf(b).toFloat(f64, .nearest_even)[0];
}

pub fn isOdd(b: *const core.BigInt) bool {
    return constOf(b).isOdd();
}

/// Converts a finite integral float to an exact integer value.
pub fn fromIntegralFloat(alloc: std.mem.Allocator, f: f64) ElzError!Value {
    if (!std.math.isFinite(f) or @floor(f) != f) return ElzError.InvalidArgument;
    if (@abs(f) < 9.2e18) return Value{ .exact_integer = @intFromFloat(f) };
    // f = mantissa * 2^exponent with an integral 53-bit mantissa.
    const fr = std.math.frexp(@abs(f));
    const mantissa: u64 = @intFromFloat(fr.significand * 9007199254740992.0); // 2^53
    const exponent: i32 = fr.exponent - 53;
    var m = Managed.initSet(alloc, mantissa) catch return ElzError.OutOfMemory;
    if (exponent >= 0) {
        var shifted = Managed.init(alloc) catch return ElzError.OutOfMemory;
        shifted.shiftLeft(&m, @intCast(exponent)) catch return ElzError.OutOfMemory;
        m = shifted;
    } else {
        var shifted = Managed.init(alloc) catch return ElzError.OutOfMemory;
        shifted.shiftRight(&m, @intCast(-exponent)) catch return ElzError.OutOfMemory;
        m = shifted;
    }
    if (f < 0) m.negate();
    return toValue(alloc, &m);
}

/// Parses digits in `base` (with an optional sign) into an exact integer.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, base: u8) ElzError!Value {
    var m = Managed.init(alloc) catch return ElzError.OutOfMemory;
    m.setString(base, text) catch return ElzError.InvalidArgument;
    return toValue(alloc, &m);
}

pub fn toString(alloc: std.mem.Allocator, b: *const core.BigInt, base: u8) ElzError![]u8 {
    return constOf(b).toStringAlloc(alloc, base, .lower) catch return ElzError.OutOfMemory;
}

/// Decimal text of an exact integer of either representation.
pub fn format(alloc: std.mem.Allocator, v: Value) ElzError![]u8 {
    return switch (v) {
        .exact_integer => |i| std.fmt.allocPrint(alloc, "{d}", .{i}) catch return ElzError.OutOfMemory,
        .bigint => |b| toString(alloc, b, 10),
        else => ElzError.InvalidArgument,
    };
}

test "bigint normalizes and prints" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try pow(a, Value{ .exact_integer = 2 }, 70);
    try std.testing.expect(big == .bigint);
    const text = try format(a, big);
    try std.testing.expectEqualStrings("1180591620717411303424", text);
    const back = try divide(a, .trunc, big, Value{ .exact_integer = 4 });
    try std.testing.expect(back.q == .bigint); // 2^68 still exceeds i64
    const small = try divide(a, .trunc, big, big);
    try std.testing.expect(small.q == .exact_integer and small.q.exact_integer == 1);
    try std.testing.expectEqual(std.math.Order.gt, order(big, Value{ .exact_integer = -5 }));
    const f = try fromIntegralFloat(a, 1e20);
    try std.testing.expectEqualStrings("100000000000000000000", try format(a, f));
}
