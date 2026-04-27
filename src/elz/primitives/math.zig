const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `add` is the implementation of the `+` primitive function.
/// It returns the sum of its arguments.
///
/// Parameters:
/// - `args`: A `ValueList` of numbers.
pub fn add(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    var sum: f64 = 0;
    for (args.items) |arg| {
        if (arg != .number) return ElzError.InvalidArgument;
        sum += arg.number;
    }
    return Value{ .number = sum };
}

/// `sub` is the implementation of the `-` primitive function.
/// If called with one argument, it returns the negation of that argument.
/// If called with multiple arguments, it subtracts the subsequent arguments from the first.
///
/// Parameters:
/// - `args`: A `ValueList` of numbers.
pub fn sub(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    var result = args.items[0].number;
    if (args.items.len == 1) {
        return Value{ .number = -result };
    }
    for (args.items[1..]) |arg| {
        if (arg != .number) return ElzError.InvalidArgument;
        result -= arg.number;
    }
    return Value{ .number = result };
}

/// `mul` is the implementation of the `*` primitive function.
/// It returns the product of its arguments.
///
/// Parameters:
/// - `args`: A `ValueList` of numbers.
pub fn mul(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    var product: f64 = 1;
    for (args.items) |arg| {
        if (arg != .number) return ElzError.InvalidArgument;
        product *= arg.number;
    }
    return Value{ .number = product };
}

/// `div` is the implementation of the `/` primitive function.
/// It returns the result of dividing the first argument by the second.
///
/// Parameters:
/// - `args`: A `ValueList` containing two numbers.
pub fn div(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number or args.items[1] != .number) return ElzError.InvalidArgument;
    if (args.items[1].number == 0) return ElzError.DivisionByZero;
    return Value{ .number = args.items[0].number / args.items[1].number };
}

/// `le` is the implementation of the `<=` primitive function.
/// It returns `#t` if the first argument is less than or equal to the second, and `#f` otherwise.
///
/// Parameters:
/// - `args`: A `ValueList` containing two numbers.
pub fn le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .number or b != .number) return ElzError.InvalidArgument;
    return Value{ .boolean = a.number <= b.number };
}

/// `lt` is the implementation of the `<` primitive function.
/// It returns `#t` if the first argument is less than the second, and `#f` otherwise.
///
/// Parameters:
/// - `args`: A `ValueList` containing two numbers.
pub fn lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .number or b != .number) return ElzError.InvalidArgument;
    return Value{ .boolean = a.number < b.number };
}

/// `ge` is the implementation of the `>=` primitive function.
/// It returns `#t` if the first argument is greater than or equal to the second, and `#f` otherwise.
///
/// Parameters:
/// - `args`: A `ValueList` containing two numbers.
pub fn ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .number or b != .number) return ElzError.InvalidArgument;
    return Value{ .boolean = a.number >= b.number };
}

/// `gt` is the implementation of the `>` primitive function.
/// It returns `#t` if the first argument is greater than the second, and `#f` otherwise.
///
/// Parameters:
/// - `args`: A `ValueList` containing two numbers.
pub fn gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .number or b != .number) return ElzError.InvalidArgument;
    return Value{ .boolean = a.number > b.number };
}

/// `eq_num` is the implementation of the `=` primitive function for numbers.
/// It returns `#t` if the two arguments are numerically equal, and `#f` otherwise.
///
/// Parameters:
/// - `args`: A `ValueList` containing two numbers.
pub fn eq_num(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .number or b != .number) return ElzError.InvalidArgument;
    return Value{ .boolean = a.number == b.number };
}

/// `sqrt` is the implementation of the `sqrt` primitive function.
/// It returns the square root of its argument.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single number.
pub fn sqrt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = std.math.sqrt(args.items[0].number) };
}

/// `sin` is the implementation of the `sin` primitive function.
/// It returns the sine of its argument.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single number.
pub fn sin(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = std.math.sin(args.items[0].number) };
}

/// `cos` is the implementation of the `cos` primitive function.
/// It returns the cosine of its argument.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single number.
pub fn cos(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = std.math.cos(args.items[0].number) };
}

/// `tan` is the implementation of the `tan` primitive function.
/// It returns the tangent of its argument.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single number.
pub fn tan(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = std.math.tan(args.items[0].number) };
}

/// `asin` returns the arc sine of its argument, in radians.
pub fn asin(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = std.math.asin(args.items[0].number) };
}

/// `acos` returns the arc cosine of its argument, in radians.
pub fn acos(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = std.math.acos(args.items[0].number) };
}

/// `atan` returns the arc tangent. With one argument it returns `atan(z)` in `[-pi/2, pi/2]`.
/// With two arguments `(atan y x)` it returns the angle of the point `(x, y)` in `[-pi, pi]`.
pub fn atan(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 1) {
        if (args.items[0] != .number) return ElzError.InvalidArgument;
        return Value{ .number = std.math.atan(args.items[0].number) };
    }
    if (args.items.len == 2) {
        if (args.items[0] != .number or args.items[1] != .number) return ElzError.InvalidArgument;
        return Value{ .number = std.math.atan2(args.items[0].number, args.items[1].number) };
    }
    return ElzError.WrongArgumentCount;
}

/// Validates that `n` is a finite, integer-valued `f64` and converts it to `i64`.
fn require_integer(n: f64) ElzError!i64 {
    if (!std.math.isFinite(n) or @floor(n) != n) return ElzError.InvalidArgument;
    const max_safe: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_safe: f64 = @floatFromInt(std.math.minInt(i64));
    if (n > max_safe or n < min_safe) return ElzError.InvalidArgument;
    return @intFromFloat(n);
}

/// `quotient` returns integer division of the first argument by the second, truncated toward zero.
pub fn quotient(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number or args.items[1] != .number) return ElzError.InvalidArgument;
    const a = try require_integer(args.items[0].number);
    const b = try require_integer(args.items[1].number);
    if (b == 0) return ElzError.DivisionByZero;
    if (a == std.math.minInt(i64) and b == -1) return ElzError.InvalidArgument;
    return Value{ .number = @floatFromInt(@divTrunc(a, b)) };
}

/// `remainder` returns the remainder of `a / b`, with the sign of `a` (R5RS).
pub fn remainder(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number or args.items[1] != .number) return ElzError.InvalidArgument;
    const a = try require_integer(args.items[0].number);
    const b = try require_integer(args.items[1].number);
    if (b == 0) return ElzError.DivisionByZero;
    if (a == std.math.minInt(i64) and b == -1) return Value{ .number = 0 };
    return Value{ .number = @floatFromInt(@rem(a, b)) };
}

/// `modulo` returns the remainder of `a / b`, with the sign of `b` (R5RS).
pub fn modulo(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number or args.items[1] != .number) return ElzError.InvalidArgument;
    const a = try require_integer(args.items[0].number);
    const b = try require_integer(args.items[1].number);
    if (b == 0) return ElzError.DivisionByZero;
    if (a == std.math.minInt(i64) and b == -1) return Value{ .number = 0 };
    return Value{ .number = @floatFromInt(@mod(a, b)) };
}

fn gcd_pair(a: i64, b: i64) i64 {
    var x: i64 = if (a < 0) -a else a;
    var y: i64 = if (b < 0) -b else b;
    while (y != 0) {
        const tmp = @mod(x, y);
        x = y;
        y = tmp;
    }
    return x;
}

/// `gcd` returns the greatest common divisor of its arguments. With no arguments it returns 0.
pub fn gcd(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    var acc: i64 = 0;
    for (args.items) |arg| {
        if (arg != .number) return ElzError.InvalidArgument;
        const n = try require_integer(arg.number);
        acc = gcd_pair(acc, n);
    }
    return Value{ .number = @floatFromInt(acc) };
}

/// `lcm` returns the least common multiple of its arguments. With no arguments it returns 1.
pub fn lcm(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return Value{ .number = 1 };
    var acc: i64 = 1;
    for (args.items) |arg| {
        if (arg != .number) return ElzError.InvalidArgument;
        const n = try require_integer(arg.number);
        if (n == 0) return Value{ .number = 0 };
        const g = gcd_pair(acc, n);
        const abs_n: i64 = if (n < 0) -n else n;
        acc = @divExact(acc, g) * abs_n;
    }
    return Value{ .number = @floatFromInt(if (acc < 0) -acc else acc) };
}

/// `log` is the implementation of the `log` primitive function.
/// It returns the natural logarithm of its argument.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single number.
pub fn log(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    const x = args.items[0].number;
    return Value{ .number = std.math.log(f64, std.math.e, x) };
}

/// `max` is the implementation of the `max` primitive function.
/// It returns the maximum value from its arguments.
///
/// Parameters:
/// - `args`: A `ValueList` of numbers.
pub fn max(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    var max_val: f64 = -std.math.inf(f64);
    if (args.items[0] == .number) {
        max_val = args.items[0].number;
    } else {
        return ElzError.InvalidArgument;
    }

    for (args.items[1..]) |arg| {
        if (arg != .number) return ElzError.InvalidArgument;
        if (arg.number > max_val) {
            max_val = arg.number;
        }
    }
    return Value{ .number = max_val };
}

/// `min` is the implementation of the `min` primitive function.
/// It returns the minimum value from its arguments.
///
/// Parameters:
/// - `args`: A `ValueList` of numbers.
pub fn min(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;
    var min_val: f64 = std.math.inf(f64);
    if (args.items[0] == .number) {
        min_val = args.items[0].number;
    } else {
        return ElzError.InvalidArgument;
    }

    for (args.items[1..]) |arg| {
        if (arg != .number) return ElzError.InvalidArgument;
        if (arg.number < min_val) {
            min_val = arg.number;
        }
    }
    return Value{ .number = min_val };
}

/// `mod` is the implementation of the `%` primitive function.
/// It returns the remainder of dividing the first argument by the second.
///
/// Parameters:
/// - `args`: A `ValueList` containing two numbers.
pub fn mod(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number or args.items[1] != .number) return ElzError.InvalidArgument;
    if (args.items[1].number == 0) return ElzError.DivisionByZero;
    return Value{ .number = @mod(args.items[0].number, args.items[1].number) };
}

/// `floor_fn` returns the largest integer not greater than the argument.
pub fn floor_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = @floor(args.items[0].number) };
}

/// `ceiling` returns the smallest integer not less than the argument.
pub fn ceiling(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = @ceil(args.items[0].number) };
}

/// `round_fn` returns the closest integer to the argument.
pub fn round_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = @round(args.items[0].number) };
}

/// `truncate` returns the integer part of the argument, truncating toward zero.
pub fn truncate(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = @trunc(args.items[0].number) };
}

/// `expt` returns the first argument raised to the power of the second.
pub fn expt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number or args.items[1] != .number) return ElzError.InvalidArgument;
    return Value{ .number = std.math.pow(f64, args.items[0].number, args.items[1].number) };
}

/// `exp_fn` returns e raised to the power of the argument.
pub fn exp_fn(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .number = std.math.exp(args.items[0].number) };
}

/// `even_p` returns #t if the argument is even.
pub fn even_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    const n = args.items[0].number;
    if (@floor(n) != n) return Value{ .boolean = false };
    // Check for overflow before converting to i64
    const max_safe: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_safe: f64 = @floatFromInt(std.math.minInt(i64));
    if (n > max_safe or n < min_safe) return ElzError.InvalidArgument;
    const i: i64 = @intFromFloat(n);
    return Value{ .boolean = @mod(i, 2) == 0 };
}

/// `odd_p` returns #t if the argument is odd.
pub fn odd_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    const n = args.items[0].number;
    if (@floor(n) != n) return Value{ .boolean = false };
    // Check for overflow before converting to i64
    const max_safe: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_safe: f64 = @floatFromInt(std.math.minInt(i64));
    if (n > max_safe or n < min_safe) return ElzError.InvalidArgument;
    const i: i64 = @intFromFloat(n);
    return Value{ .boolean = @mod(i, 2) != 0 };
}

/// `zero_p` returns #t if the argument is zero.
pub fn zero_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .boolean = args.items[0].number == 0 };
}

/// `positive_p` returns #t if the argument is positive.
pub fn positive_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .boolean = args.items[0].number > 0 };
}

/// `negative_p` returns #t if the argument is negative.
pub fn negative_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return Value{ .boolean = args.items[0].number < 0 };
}

/// `complex_p` reports whether the argument lies in the complex domain. Since Element 0
/// has only real numbers, this is equivalent to `number?`.
pub fn complex_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .number };
}

/// `real_p` reports whether the argument is a real number. Equivalent to `number?` here.
pub fn real_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .number };
}

/// `rational_p` reports whether the argument is rational. Element 0 represents numbers as
/// f64, so finite values are reported as rational and infinities and NaN are not.
pub fn rational_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (v != .number) return Value{ .boolean = false };
    return Value{ .boolean = std.math.isFinite(v.number) };
}

/// `exact_p` reports whether the argument is an exact number. Element 0 has only
/// inexact f64 values, so this always returns #f for numbers.
pub fn exact_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    _ = args.items[0];
    return Value{ .boolean = false };
}

/// `inexact_p` reports whether the argument is an inexact number.
pub fn inexact_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .number };
}

/// `exact_to_inexact` is the identity for f64 values. A non-number argument is rejected.
pub fn exact_to_inexact(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return args.items[0];
}

/// `inexact_to_exact` is the identity for f64 values. The result is still an f64 because
/// Element 0 has no exact integer or rational type.
pub fn inexact_to_exact(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .number) return ElzError.InvalidArgument;
    return args.items[0];
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
    var fuel: u64 = 1000;

    // Test add
    var args = core.ValueList.init(allocator);
    try args.append(Value{ .number = 1 });
    try args.append(Value{ .number = 2 });
    var result = try add(&interp_stub, env_stub, args, &fuel);
    try testing.expectEqual(@as(f64, 3), result.number);

    // Test sub
    args.clearRetainingCapacity();
    try args.append(Value{ .number = 5 });
    try args.append(Value{ .number = 2 });
    result = try sub(&interp_stub, env_stub, args, &fuel);
    try testing.expectEqual(@as(f64, 3), result.number);

    // Test mul
    args.clearRetainingCapacity();
    try args.append(Value{ .number = 2 });
    try args.append(Value{ .number = 3 });
    result = try mul(&interp_stub, env_stub, args, &fuel);
    try testing.expect(result == .number and result.number == 6);

    // Test div
    args.clearRetainingCapacity();
    try args.append(Value{ .number = 6 });
    try args.append(Value{ .number = 2 });
    result = try div(&interp_stub, env_stub, args, &fuel);
    try testing.expect(result == .number and result.number == 3);

    // Test div by zero
    args.clearRetainingCapacity();
    try args.append(Value{ .number = 6 });
    try args.append(Value{ .number = 0 });
    const err = div(&interp_stub, env_stub, args, &fuel);
    try testing.expectError(ElzError.DivisionByZero, err);
}

test "trig inverse" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    var args = core.ValueList.init(interp.allocator);
    try args.append(Value{ .number = 0 });
    try testing.expectApproxEqAbs(@as(f64, 0), (try asin(&interp, interp.root_env, args, &fuel)).number, 1e-9);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, (try acos(&interp, interp.root_env, args, &fuel)).number, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), (try atan(&interp, interp.root_env, args, &fuel)).number, 1e-9);

    args.clearRetainingCapacity();
    try args.append(Value{ .number = 1 });
    try args.append(Value{ .number = 1 });
    try testing.expectApproxEqAbs(std.math.pi / 4.0, (try atan(&interp, interp.root_env, args, &fuel)).number, 1e-9);
}

test "integer division operations" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    var args = core.ValueList.init(interp.allocator);
    try args.append(Value{ .number = 13 });
    try args.append(Value{ .number = 4 });
    try testing.expectEqual(@as(f64, 3), (try quotient(&interp, interp.root_env, args, &fuel)).number);
    try testing.expectEqual(@as(f64, 1), (try remainder(&interp, interp.root_env, args, &fuel)).number);
    try testing.expectEqual(@as(f64, 1), (try modulo(&interp, interp.root_env, args, &fuel)).number);

    // Negative dividend: remainder follows dividend sign, modulo follows divisor sign.
    args.clearRetainingCapacity();
    try args.append(Value{ .number = -13 });
    try args.append(Value{ .number = 4 });
    try testing.expectEqual(@as(f64, -1), (try remainder(&interp, interp.root_env, args, &fuel)).number);
    try testing.expectEqual(@as(f64, 3), (try modulo(&interp, interp.root_env, args, &fuel)).number);

    // Non-integer argument is rejected.
    args.clearRetainingCapacity();
    try args.append(Value{ .number = 1.5 });
    try args.append(Value{ .number = 2 });
    try testing.expectError(ElzError.InvalidArgument, quotient(&interp, interp.root_env, args, &fuel));

    // Division by zero.
    args.clearRetainingCapacity();
    try args.append(Value{ .number = 4 });
    try args.append(Value{ .number = 0 });
    try testing.expectError(ElzError.DivisionByZero, quotient(&interp, interp.root_env, args, &fuel));
}

test "gcd and lcm" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    var args = core.ValueList.init(interp.allocator);
    try testing.expectEqual(@as(f64, 0), (try gcd(&interp, interp.root_env, args, &fuel)).number);
    try testing.expectEqual(@as(f64, 1), (try lcm(&interp, interp.root_env, args, &fuel)).number);

    args.clearRetainingCapacity();
    try args.append(Value{ .number = 12 });
    try args.append(Value{ .number = 18 });
    try testing.expectEqual(@as(f64, 6), (try gcd(&interp, interp.root_env, args, &fuel)).number);
    try testing.expectEqual(@as(f64, 36), (try lcm(&interp, interp.root_env, args, &fuel)).number);

    // Variadic with negatives.
    args.clearRetainingCapacity();
    try args.append(Value{ .number = -12 });
    try args.append(Value{ .number = 18 });
    try args.append(Value{ .number = 30 });
    try testing.expectEqual(@as(f64, 6), (try gcd(&interp, interp.root_env, args, &fuel)).number);

    // lcm with a zero argument is 0.
    args.clearRetainingCapacity();
    try args.append(Value{ .number = 4 });
    try args.append(Value{ .number = 0 });
    try testing.expectEqual(@as(f64, 0), (try lcm(&interp, interp.root_env, args, &fuel)).number);
}
