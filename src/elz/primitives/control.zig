const std = @import("std");
const core = @import("../core.zig");
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");
const vm_mod = @import("../vm.zig");
const writer_mod = @import("../writer.zig");

/// Formats a raised value into a human-readable message for uncaught display.
fn describeValue(allocator: std.mem.Allocator, v: core.Value) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    if (v == .string) {
        aw.writer.writeAll(v.string.bytes) catch return null;
    } else {
        writer_mod.write(v, &aw.writer) catch return null;
    }
    return aw.toOwnedSlice() catch null;
}

/// Builds an error-object record: fields are (kind message irritants).
fn makeErrorObject(interp: *interpreter.Interpreter, allocator: std.mem.Allocator, kind: core.Value, message: core.Value, irritants: core.Value) ElzError!core.Value {
    const rtd = interp.error_rtd orelse return ElzError.InvalidArgument;
    const fields = allocator.alloc(core.Value, 3) catch return ElzError.OutOfMemory;
    fields[0] = kind;
    fields[1] = message;
    fields[2] = irritants;
    const rec = allocator.create(core.Record) catch return ElzError.OutOfMemory;
    rec.* = .{ .rtd = rtd, .fields = fields };
    return core.Value{ .record = rec };
}

/// Raises `obj` through the Zig error channel, recording it for catch sites.
fn raiseValue(interp: *interpreter.Interpreter, allocator: std.mem.Allocator, obj: core.Value) ElzError {
    interp.current_exception = obj;
    if (obj == .record and interp.error_rtd != null and obj.record.rtd == interp.error_rtd.?) {
        interp.last_error_message = describeValue(allocator, obj.record.fields[1]);
    } else {
        interp.last_error_message = describeValue(allocator, obj);
    }
    return ElzError.UserError;
}

/// `error` raises an error object with a message and irritants.
/// Syntax: (error message irritant ...)
pub fn error_fn(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len == 0) return ElzError.WrongArgumentCount;

    var irritants: core.Value = .nil;
    var i = args.items.len;
    while (i > 1) {
        i -= 1;
        const p = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
        p.* = .{ .car = args.items[i], .cdr = irritants };
        irritants = core.Value{ .pair = p };
    }
    const obj = try makeErrorObject(interp, env.allocator, core.Value{ .symbol = "user" }, args.items[0], irritants);
    return raise_common(interp, env, obj, fuel, false);
}

/// `raise` raises an object. If an exception handler is installed, it is
/// called on the object; the handler returning is itself an error.
/// Syntax: (raise obj)
pub fn raise_fn(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return raise_common(interp, env, args.items[0], fuel, false);
}

/// `raise-continuable` raises an object; the installed handler's return value
/// becomes the value of the raise expression.
/// Syntax: (raise-continuable obj)
pub fn raise_continuable_fn(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return raise_common(interp, env, args.items[0], fuel, true);
}

/// Pushed onto `interp.exception_handlers` for the extent of a `try` body. It
/// marks a handler boundary that is nearer than any installed
/// `with-exception-handler` handler, so a `raise` inside the body reaches the
/// `try` (and therefore `guard`) instead of jumping to an outer handler.
const try_boundary: core.Value = .unspecified;

fn isTryBoundary(v: core.Value) bool {
    return v == .unspecified;
}

fn raise_common(interp: *interpreter.Interpreter, env: *core.Environment, obj: core.Value, fuel: *u64, continuable: bool) ElzError!core.Value {
    const handlers = interp.exception_handlers.items;
    if (handlers.len > 0 and !isTryBoundary(handlers[handlers.len - 1])) {
        // Call the innermost handler with it uninstalled, per R7RS.
        const handler = interp.exception_handlers.pop().?;
        var handler_args = core.ValueList.init(env.allocator);
        defer handler_args.deinit();
        try handler_args.append(obj);
        const result = vm_mod.callProc(interp, handler, handler_args, fuel);
        interp.exception_handlers.append(interp.allocator, handler) catch return ElzError.OutOfMemory;
        const value = try result;
        if (continuable) return value;
        interp.last_error_message = "exception handler returned from non-continuable raise";
        interp.current_exception = obj;
        return ElzError.UserError;
    }
    return raiseValue(interp, env.allocator, obj);
}

/// `with-exception-handler` installs `handler` for the dynamic extent of `thunk`.
/// Syntax: (with-exception-handler handler thunk)
pub fn with_exception_handler(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    interp.exception_handlers.append(interp.allocator, args.items[0]) catch return ElzError.OutOfMemory;
    defer _ = interp.exception_handlers.pop();
    var no_args = core.ValueList.init(env.allocator);
    defer no_args.deinit();
    return vm_mod.callProc(interp, args.items[1], no_args, fuel);
}

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
    // Reject circular argument lists instead of looping forever.
    var probe = last_arg;
    var steps: usize = 0;
    while (probe == .pair) : (probe = probe.pair.cdr) {
        steps += 1;
        if (steps > 10_000_000) return ElzError.InvalidArgument;
    }
    while (current_node != .nil) {
        const p = switch (current_node) {
            .pair => |pair_val| pair_val,
            else => return ElzError.InvalidArgument,
        };
        try final_args.append(p.car);
        current_node = p.cdr;
    }

    return vm_mod.callProc(interp, proc, final_args, fuel);
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
    const produced = try vm_mod.callProc(interp, producer, producer_args, fuel);

    var consumer_args = core.ValueList.init(env.allocator);
    defer consumer_args.deinit();
    if (produced == .multi_values) {
        for (produced.multi_values.items) |v| {
            try consumer_args.append(v);
        }
    } else {
        try consumer_args.append(produced);
    }
    return vm_mod.callProc(interp, consumer, consumer_args, fuel);
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
    new_port.* = core.Port.openInput(env.allocator, interp.io, path_val.string.bytes) catch return ElzError.FileNotFound;

    const saved = interp.stdin_port;
    interp.stdin_port = new_port;
    defer {
        interp.stdin_port = saved;
        new_port.close();
    }

    var thunk_args = core.ValueList.init(env.allocator);
    defer thunk_args.deinit();
    return vm_mod.callProc(interp, thunk, thunk_args, fuel);
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
    new_port.* = core.Port.openOutput(env.allocator, interp.io, path_val.string.bytes) catch return ElzError.FileNotWritable;

    const saved = interp.stdout_port;
    interp.stdout_port = new_port;
    defer {
        interp.stdout_port = saved;
        new_port.close();
    }

    var thunk_args = core.ValueList.init(env.allocator);
    defer thunk_args.deinit();
    return vm_mod.callProc(interp, thunk, thunk_args, fuel);
}

/// `force` evaluates a delayed promise and memoizes the result. Subsequent calls return
/// the cached value. A non-promise argument is returned unchanged.
/// Syntax: (force promise)
/// `make-promise` wraps a no-argument thunk (produced by `delay`) in a Promise.
pub fn make_promise(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    // A promise is returned unchanged; any other value becomes a forced promise.
    if (v == .promise) return v;
    const pr = try env.allocator.create(core.Promise);
    pr.* = .{ .expr = .unspecified, .env = interp.root_env, .forced = true, .result = v };
    return core.Value{ .promise = pr };
}

/// Internal primitive backing `delay`: wraps a zero-argument thunk in an
/// unforced promise. `make-promise` cannot serve this role, because R7RS
/// requires it to treat its argument as an already-computed value.
/// Called by the compiler as: (%%make-delayed%% (lambda () expr))
pub fn make_delayed(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    // (%%make-delayed%% thunk) for `delay`; (%%make-delayed%% thunk #t) for
    // `delay-force`, whose promise-valued result is forced in turn.
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    const thunk = args.items[0];
    switch (thunk) {
        .vm_closure, .procedure, .foreign_procedure => {},
        else => return ElzError.InvalidArgument,
    }
    const pr = try env.allocator.create(core.Promise);
    pr.* = .{ .expr = thunk, .env = interp.root_env, .forced = false, .result = .unspecified, .is_delay_force = args.items.len == 2 };
    return core.Value{ .promise = pr };
}

pub fn force(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const arg = args.items[0];
    if (arg != .promise) return arg;

    var pr = arg.promise;
    while (pr.forward) |f| pr = f;
    // Iterative forcing: a `delay-force` promise whose thunk yields another
    // promise adopts that promise's thunk and loops, so a chain of any length
    // runs in constant native stack space (R7RS 7.3 "space-safe").
    while (!pr.forced) {
        var no_args = core.ValueList.init(env.allocator);
        defer no_args.deinit();
        const result = if (pr.expr == .vm_closure or pr.expr == .procedure or pr.expr == .foreign_procedure)
            try vm_mod.callProc(interp, pr.expr, no_args, fuel)
        else
            try interp.evalForm(&pr.expr, fuel);
        // The thunk may have forced this promise re-entrantly.
        if (pr.forced) break;
        if (pr.is_delay_force and result == .promise) {
            const inner = result.promise;
            if (inner.forced) {
                pr.result = inner.result;
                pr.forced = true;
            } else {
                pr.expr = inner.expr;
                pr.is_delay_force = inner.is_delay_force;
                // Let the inner promise share the outcome.
                inner.forward = pr;
            }
            continue;
        }
        pr.result = result;
        pr.forced = true;
    }
    return pr.result;
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

    _ = env;
    const expr = args.items[0];

    // An optional second argument specifies the environment; we evaluate in the
    // interpreter root environment regardless (first-class environments are not supported).
    if (args.items.len == 2) _ = args.items[1];

    return interp.evalForm(&expr, fuel);
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
    switch (proc) {
        .vm_closure, .procedure, .foreign_procedure => {},
        else => return ElzError.InvalidArgument,
    }

    // Each escape continuation carries its own identity, so a jump aimed at an
    // outer call/ec passes through the inner ones instead of being consumed by
    // the first frame that sees it.
    interp.cps.escape_counter += 1;
    const escape = env.allocator.create(core.Escape) catch return ElzError.OutOfMemory;
    escape.* = .{ .id = interp.cps.escape_counter };
    // Invoking it after this frame returns is an error, not a jump.
    defer escape.active = false;

    var call_args = core.ValueList.init(env.allocator);
    defer call_args.deinit();
    try call_args.append(core.Value{ .escape = escape });

    const result = vm_mod.callProc(interp, proc, call_args, fuel);

    if (result) |val| {
        return val;
    } else |err| {
        if (err == ElzError.EscapeContinuationInvoked and interp.cps.escape_id == escape.id) {
            const escaped_val = interp.cps.escape_value orelse core.Value.unspecified;
            interp.cps.escape_value = null;
            interp.cps.escape_id = 0;
            return escaped_val;
        }
        return err;
    }
}

/// Internal primitive backing the `(try body... (catch err handler...))` special form.
/// Called by the compiler as: (%%try%% body-thunk handler-thunk)
/// Runs body-thunk(); on error, runs handler-thunk(error-message).
pub fn prim_try(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!core.Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const body_thunk = args.items[0];
    const handler_thunk = args.items[1];

    // Run the body thunk with zero arguments.
    var no_args = core.ValueList.init(env.allocator);
    defer no_args.deinit();

    // Mark this `try` as the innermost handler for the body's extent.
    interp.exception_handlers.append(interp.allocator, try_boundary) catch return ElzError.OutOfMemory;
    const body_result = vm_mod.callProc(interp, body_thunk, no_args, fuel);
    _ = interp.exception_handlers.pop();

    if (body_result) |val| {
        return val;
    } else |err| {
        // An escape continuation jumping past this `try` is not an error the
        // handler should see: let it reach its own call/ec frame.
        if (err == ElzError.EscapeContinuationInvoked) return err;
        // A raised value takes precedence; otherwise wrap the runtime error in
        // an error object so `error-object?`, `file-error?`, and
        // `read-error?` classify it.
        const err_val: core.Value = if (interp.current_exception) |exc| blk: {
            interp.current_exception = null;
            break :blk exc;
        } else blk: {
            const msg = interp.last_error_message orelse @errorName(err);
            const msg_val = core.Value.from(env.allocator, msg) catch return ElzError.OutOfMemory;
            const kind: core.Value = switch (err) {
                ElzError.FileNotFound, ElzError.FileNotWritable, ElzError.IOError => .{ .symbol = "file" },
                ElzError.UnterminatedString, ElzError.UnexpectedEndOfInput, ElzError.UnmatchedOpenParen, ElzError.UnexpectedCloseParen, ElzError.InvalidCharacterLiteral, ElzError.InvalidDottedPair => .{ .symbol = "read" },
                else => .{ .symbol = "runtime" },
            };
            break :blk makeErrorObject(interp, env.allocator, kind, msg_val, .nil) catch msg_val;
        };
        interp.last_error_message = null;
        interp.last_error_line = null;
        interp.last_error_file = null;

        var handler_args = core.ValueList.init(env.allocator);
        defer handler_args.deinit();
        try handler_args.append(err_val);

        return vm_mod.callProc(interp, handler_thunk, handler_args, fuel);
    }
}

/// `call-with-current-continuation` (call/cc): for upward-only (escape) uses this
/// is equivalent to `call/ec`. Full first-class continuations are not supported.
pub fn call_with_current_continuation(
    interp: *interpreter.Interpreter,
    env: *core.Environment,
    args: core.ValueList,
    fuel: *u64,
) ElzError!core.Value {
    return call_with_escape_continuation(interp, env, args, fuel);
}

/// `dynamic-wind`: (dynamic-wind before thunk after)
/// Calls `before`, then `thunk` (returning its value), then `after`.
/// The `after` thunk is called even if the body exits via an escape continuation.
pub fn dynamic_wind(
    interp: *interpreter.Interpreter,
    env: *core.Environment,
    args: core.ValueList,
    fuel: *u64,
) ElzError!core.Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;
    const before = args.items[0];
    const thunk = args.items[1];
    const after_proc = args.items[2];

    var no_args = core.ValueList.init(env.allocator);
    defer no_args.deinit();

    // Register winder so call/ec escape can find it.
    const winder = try env.allocator.create(core.Winder);
    winder.* = .{ .before = before, .after = after_proc, .next = interp.cps.winders };
    const saved_winders = interp.cps.winders;

    _ = try vm_mod.callProc(interp, before, no_args, fuel);

    interp.cps.winders = winder;
    const thunk_result = vm_mod.callProc(interp, thunk, no_args, fuel);
    interp.cps.winders = saved_winders;

    // Always call after, even if thunk errored (e.g. escape continuation).
    _ = vm_mod.callProc(interp, after_proc, no_args, fuel) catch {};

    return thunk_result;
}

test "control primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 1000;

    // Test apply with basic lambda
    const proc_val = try interp.evalString("(lambda (x y) (+ x y))", &fuel);

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 1000;

    // Create a lambda that takes no arguments
    const proc_val = try interp.evalString("(lambda () 42)", &fuel);

    var args = core.ValueList.init(allocator);
    defer args.deinit();

    try args.append(proc_val);
    try args.append(core.Value.nil);

    const result = try apply(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == .exact_integer and result.exact_integer == 42);
}

test "apply memory leak regression" {
    // The original purpose of this test is to confirm `apply` does not leak memory under
    // its caller's allocator across many invocations. We use an arena so the test owns a
    // clean lifetime boundary; the regression is detected because, before the fix this
    // test guards, internal apply allocations escaped the arena and were caught by
    // `std.testing.allocator` instead.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;

    // Create a simple lambda
    const proc_val = try interp.evalString("(lambda (x) x)", &fuel);

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
