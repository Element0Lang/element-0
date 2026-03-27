const std = @import("std");
const core = @import("../core.zig");
const eval = @import("../eval.zig");
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `apply` is the implementation of the `apply` primitive function in Elz.
/// It applies a procedure to a list of arguments. The last argument to `apply`
/// must be a list, which is then used as the arguments to the procedure.
///
/// For example: `(apply + '(1 2 3))` is equivalent to `(+ 1 2 3)`.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
/// - `env`: The environment in which to apply the procedure.
/// - `args`: The arguments to `apply`, where the first argument is the procedure
///           and the last argument is the list of arguments for that procedure.
/// - `fuel`: A pointer to the execution fuel counter.
///
/// Returns:
/// The result of applying the procedure, or an error if the application fails.
pub fn apply(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;

    const proc = args.items[0];
    const last_arg = args.items[args.items.len - 1];

    var final_args = core.ValueList.init(env.allocator);
    defer final_args.deinit();

    for (args.items[1 .. args.items.len - 1]) |item| {
        try final_args.append(item);
    }

    var current_node = last_arg;
    while (current_node != .nil) {
        const p = switch (current_node) {
            .pair => |pair_val| pair_val,
            else => return ElzError.InvalidArgument,
        };
        try final_args.append(p.car);
        current_node = p.cdr;
    }

    return eval.eval_proc(interp, proc, final_args, env, fuel);
}

/// `eval_proc` is the implementation of the `eval` primitive function.
/// It evaluates an expression in a given environment.
///
/// Syntax: (eval expr) or (eval expr env)
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
/// - `env`: The current environment.
/// - `args`: The arguments to `eval`, where the first argument is the expression
///           to evaluate. An optional second argument specifies the environment.
/// - `fuel`: A pointer to the execution fuel counter.
///
/// Returns:
/// The result of evaluating the expression.
pub fn eval_proc(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;

    const expr = args.items[0];

    // Use provided environment or current environment
    const eval_env = if (args.items.len == 2) blk: {
        const env_arg = args.items[1];
        // For now, we only support evaluating in the current environment
        // A full implementation would need first-class environments
        _ = env_arg;
        break :blk env;
    } else env;

    return eval.eval(interp, &expr, eval_env, fuel);
}

/// `call-with-escape-continuation` creates an escape continuation and passes it to the
/// given procedure. When the escape continuation is invoked with a value, it immediately
/// returns that value from the `call/ec` form. This is an upward-only (escape) continuation.
///
/// Syntax: (call/ec (lambda (k) ...))
///
/// Inside the lambda, calling (k value) immediately returns value from the call/ec form.
/// If the lambda returns normally, its return value is the result of call/ec.
pub fn call_with_escape_continuation(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const proc = args.items[0];
    if (proc != .closure) return ElzError.InvalidArgument;

    // The escape function: when called, stores its argument on the interpreter
    // and signals EscapeContinuationInvoked. Since there's only one interpreter,
    // and escape continuations unwind the stack, this is safe.
    const escape_fn = struct {
        pub fn invoke(i: *interpreter.Interpreter, _: *core.Environment, a: core.ValueList, _: *u64) ElzError!core.Value {
            if (a.items.len != 1) return ElzError.WrongArgumentCount;
            i.escape_value = a.items[0];
            return ElzError.EscapeContinuationInvoked;
        }
    }.invoke;

    // Build args for the procedure: pass the escape function
    var call_args = core.ValueList.init(env.allocator);
    try call_args.append(core.Value{ .procedure = escape_fn });

    // Call the procedure with the escape continuation
    const result = eval.eval_proc(interp, proc, call_args, env, fuel);

    if (result) |val| {
        return val;
    } else |err| {
        if (err == ElzError.EscapeContinuationInvoked) {
            const escaped_val = interp.escape_value orelse core.Value.unspecified;
            interp.escape_value = null;
            return escaped_val;
        }
        return err;
    }
}

test "control primitives" {
    const allocator = std.testing.allocator;
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 1000;

    // Test apply with basic lambda
    const source = "(lambda (x y) (+ x y))";
    const forms = try @import("../parser.zig").readAll(source, allocator);
    defer forms.deinit(allocator);
    const proc_val = try eval.eval(&interp, &forms.items[0], interp.root_env, &fuel);

    var args = core.ValueList.init(allocator);
    defer args.deinit();

    try args.append(proc_val);
    try args.append(core.Value{ .number = 1 });

    const p = try allocator.create(core.Pair);
    p.* = .{ .car = core.Value{ .number = 2 }, .cdr = .nil };
    try args.append(core.Value{ .pair = p });

    const result = try apply(&interp, interp.root_env, args, &fuel);
    try testing.expect(result.number == 3);
}

test "apply with empty list" {
    const allocator = std.testing.allocator;
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 1000;

    // Create a lambda that takes no arguments
    const source = "(lambda () 42)";
    const forms = try @import("../parser.zig").readAll(source, allocator);
    defer forms.deinit(allocator);
    const proc_val = try eval.eval(&interp, &forms.items[0], interp.root_env, &fuel);

    var args = core.ValueList.init(allocator);
    defer args.deinit();

    try args.append(proc_val);
    try args.append(core.Value.nil);

    const result = try apply(&interp, interp.root_env, args, &fuel);
    try testing.expect(result.number == 42);
}

test "apply memory leak regression" {
    const allocator = std.testing.allocator;
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;

    // Create a simple lambda
    const source = "(lambda (x) x)";
    const forms = try @import("../parser.zig").readAll(source, allocator);
    defer forms.deinit(allocator);
    const proc_val = try eval.eval(&interp, &forms.items[0], interp.root_env, &fuel);

    // Call apply many times to test for memory leaks
    // If the defer is missing, this would accumulate memory
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var args = core.ValueList.init(allocator);
        defer args.deinit();

        try args.append(proc_val);
        const p = try allocator.create(core.Pair);
        p.* = .{ .car = core.Value{ .number = @floatFromInt(i) }, .cdr = .nil };
        try args.append(core.Value{ .pair = p });

        const result = try apply(&interp, interp.root_env, args, &fuel);
        try testing.expect(result.number == @as(f64, @floatFromInt(i)));
    }
}
