const std = @import("std");
const core = @import("../core.zig");
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `exit` is the implementation of the `exit` primitive function.
/// It terminates the current process with the given exit code.
///
/// Parameters:
/// - `args`: A `ValueList` with at most one element. No argument or `#t`
///           exits with status 0, `#f` exits with status 1, and a number is
///           used as the status directly. It must be an integer in [0, 255].
pub fn exit(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len > 1) {
        return ElzError.WrongArgumentCount;
    }
    if (args.items.len == 0) std.process.exit(0);
    const code = args.items[0];
    if (code == .boolean) std.process.exit(if (code.boolean) 0 else 1);
    if (!code.isNumeric()) {
        return ElzError.InvalidArgument;
    }

    const num = code.asFloat() orelse return ElzError.InvalidArgument;

    // Check for NaN or Infinity
    if (std.math.isNan(num) or std.math.isInf(num)) {
        interp.last_error_message = "Exit code must be a finite number.";
        return ElzError.InvalidArgument;
    }

    // Check range [0, 255]
    if (num < 0 or num > 255) {
        interp.last_error_message = "Exit code must be in the range [0, 255].";
        return ElzError.InvalidArgument;
    }

    // Check for fractional part
    if (@floor(num) != num) {
        interp.last_error_message = "Exit code must be an integer.";
        return ElzError.InvalidArgument;
    }

    std.process.exit(@intFromFloat(num));
}

test "exit rejects negative code" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var args = core.ValueList.init(interp.allocator);
    try args.append(core.Value{ .number = -1 });

    const result = exit(&interp, interp.root_env, args, undefined);
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "exit rejects code > 255" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var args = core.ValueList.init(interp.allocator);
    try args.append(core.Value{ .number = 256 });

    const result = exit(&interp, interp.root_env, args, undefined);
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "exit rejects fractional code" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var args = core.ValueList.init(interp.allocator);
    try args.append(core.Value{ .number = 1.5 });

    const result = exit(&interp, interp.root_env, args, undefined);
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "exit rejects NaN" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var args = core.ValueList.init(interp.allocator);
    try args.append(core.Value{ .number = std.math.nan(f64) });

    const result = exit(&interp, interp.root_env, args, undefined);
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "exit rejects wrong argument count" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var args = core.ValueList.init(interp.allocator);
    try args.append(core.Value{ .exact_integer = 0 });
    try args.append(core.Value{ .exact_integer = 0 });

    const result = exit(&interp, interp.root_env, args, undefined);
    try std.testing.expectError(ElzError.WrongArgumentCount, result);
}

test "exit rejects a non-numeric, non-boolean status" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var args = core.ValueList.init(interp.allocator);
    try args.append(core.Value{ .symbol = "oops" });

    const result = exit(&interp, interp.root_env, args, undefined);
    try std.testing.expectError(ElzError.InvalidArgument, result);
}
