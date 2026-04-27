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

/// `values` packages its arguments as a multi-values envelope. With one argument it
/// returns the argument itself. With zero or more than one argument it returns a
/// `MultiValues` value that only `call-with-values` will unpack.
/// Syntax: (values obj ...)
pub fn values(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len == 1) return args.items[0];

    const items = env.allocator.alloc(core.Value, args.items.len) catch return ElzError.OutOfMemory;
    for (args.items, 0..) |v, i| {
        items[i] = v;
    }
    const mv = env.allocator.create(core.MultiValues) catch return ElzError.OutOfMemory;
    mv.* = .{ .items = items };
    return core.Value{ .multi_values = mv };
}

/// `call_with_values` calls `producer` with no arguments and applies `consumer` to
/// the values produced. If the producer returns a `MultiValues`, its items become the
/// consumer arguments; any other value is passed as a single argument.
/// Syntax: (call-with-values producer consumer)
pub fn call_with_values(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const producer = args.items[0];
    const consumer = args.items[1];

    var producer_args = core.ValueList.init(env.allocator);
    defer producer_args.deinit();
    const produced = try eval.eval_proc(interp, producer, producer_args, env, fuel);

    var consumer_args = core.ValueList.init(env.allocator);
    defer consumer_args.deinit();
    if (produced == .multi_values) {
        for (produced.multi_values.items) |v| {
            try consumer_args.append(v);
        }
    } else {
        try consumer_args.append(produced);
    }
    return eval.eval_proc(interp, consumer, consumer_args, env, fuel);
}

/// `with_input_from_file` opens `path` for reading, redirects the interpreter's current
/// input port to the resulting port, calls `thunk`, then restores the previous current
/// input port and closes the file. Returns the value the thunk produced.
/// Syntax: (with-input-from-file path thunk)
pub fn with_input_from_file(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const path_val = args.items[0];
    const thunk = args.items[1];
    if (path_val != .string) return ElzError.InvalidArgument;

    const new_port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    new_port.* = core.Port.openInput(env.allocator, interp.io, path_val.string) catch return ElzError.FileNotFound;

    const saved = interp.stdin_port;
    interp.stdin_port = new_port;

    var thunk_args = core.ValueList.init(env.allocator);
    defer thunk_args.deinit();
    const result = eval.eval_proc(interp, thunk, thunk_args, env, fuel);

    interp.stdin_port = saved;
    new_port.close();
    return result;
}

/// `with_output_to_file` is the output counterpart to `with_input_from_file`. Display,
/// write, and newline calls inside `thunk` go to the file instead of standard output.
/// Syntax: (with-output-to-file path thunk)
pub fn with_output_to_file(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const path_val = args.items[0];
    const thunk = args.items[1];
    if (path_val != .string) return ElzError.InvalidArgument;

    const new_port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    new_port.* = core.Port.openOutput(env.allocator, interp.io, path_val.string) catch return ElzError.FileNotWritable;

    const saved = interp.stdout_port;
    interp.stdout_port = new_port;

    var thunk_args = core.ValueList.init(env.allocator);
    defer thunk_args.deinit();
    const result = eval.eval_proc(interp, thunk, thunk_args, env, fuel);

    interp.stdout_port = saved;
    new_port.close();
    return result;
}

/// `force` evaluates a delayed promise and memoizes the result. Subsequent calls return
/// the cached value. A non-promise argument is returned unchanged.
/// Syntax: (force promise)
pub fn force(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const arg = args.items[0];
    if (arg != .promise) return arg;

    const pr = arg.promise;
    if (pr.forced) return pr.result;

    var expr = pr.expr;
    const result = try eval.eval(interp, &expr, pr.env, fuel);
    pr.result = result;
    pr.forced = true;
    return result;
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
    var forms = try @import("../parser.zig").readAll(source, allocator);
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
    var forms = try @import("../parser.zig").readAll(source, allocator);
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
    var forms = try @import("../parser.zig").readAll(source, allocator);
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
