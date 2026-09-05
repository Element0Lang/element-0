const std = @import("std");
const core = @import("../core.zig");
const writer = @import("../writer.zig");
const parser = @import("../parser.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `display` is the implementation of the `display` primitive function.
/// It writes the given value to standard output. For strings and characters,
/// it writes the raw value. For other types, it uses the `writer.write` function.
///
/// Parameters:
/// - `args`: A `ValueList` containing the single value to display.
///
/// Returns:
/// An unspecified value, or an error if writing to stdout fails.
/// Renders a value in display mode (strings unquoted, chars as raw codepoints),
/// with datum labels for cycles so a circular list terminates.
fn render_display(allocator: std.mem.Allocator, value: Value, w: *std.Io.Writer) !void {
    try writer.writeLabeled(allocator, value, w, .cycles, .display);
}

/// Writes the rendered bytes from `aw` to the supplied port, or to the interpreter's
/// current output port when none is given. Routing through the current output port lets
/// `with-output-to-file` redirect display, write, and newline.
fn flush_to_destination(interp: *interpreter.Interpreter, aw: *std.Io.Writer.Allocating, port_opt: ?Value) ElzError!void {
    const bytes = aw.written();
    const target_port: *core.Port = if (port_opt) |port_val| blk: {
        if (port_val != .port) return ElzError.InvalidArgument;
        break :blk port_val.port;
    } else interp.currentOutputPort() catch return ElzError.OutOfMemory;
    target_port.writeString(bytes) catch return ElzError.ForeignFunctionError;
}

pub fn display(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    var aw: std.Io.Writer.Allocating = .init(env.allocator);
    defer aw.deinit();
    render_display(env.allocator, args.items[0], &aw.writer) catch return ElzError.ForeignFunctionError;
    const port_opt: ?Value = if (args.items.len == 2) args.items[1] else null;
    try flush_to_destination(interp, &aw, port_opt);
    return Value.unspecified;
}

/// `write_proc` is the implementation of the `write` primitive function.
/// It writes the given value to standard output in a machine-readable format.
///
/// Parameters:
/// - `args`: A `ValueList` containing the single value to write.
///
/// Returns:
/// An unspecified value, or an error if writing to stdout fails.
pub fn write_proc(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    var aw: std.Io.Writer.Allocating = .init(env.allocator);
    defer aw.deinit();
    writer.writeLabeled(env.allocator, args.items[0], &aw.writer, .cycles, .write) catch return ElzError.ForeignFunctionError;
    const port_opt: ?Value = if (args.items.len == 2) args.items[1] else null;
    try flush_to_destination(interp, &aw, port_opt);
    return Value.unspecified;
}

/// `write_shared_proc` is `write` with datum labels on all shared structure.
/// Syntax: (write-shared obj) or (write-shared obj port)
pub fn write_shared_proc(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    var aw: std.Io.Writer.Allocating = .init(env.allocator);
    defer aw.deinit();
    writer.writeLabeled(env.allocator, args.items[0], &aw.writer, .shared, .write) catch return ElzError.ForeignFunctionError;
    const port_opt: ?Value = if (args.items.len == 2) args.items[1] else null;
    try flush_to_destination(interp, &aw, port_opt);
    return Value.unspecified;
}

/// `write_simple_proc` is `write` without datum labels; it may not terminate
/// beyond the depth guard on cyclic data.
/// Syntax: (write-simple obj) or (write-simple obj port)
pub fn write_simple_proc(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    var aw: std.Io.Writer.Allocating = .init(env.allocator);
    defer aw.deinit();
    writer.write(args.items[0], &aw.writer) catch return ElzError.ForeignFunctionError;
    const port_opt: ?Value = if (args.items.len == 2) args.items[1] else null;
    try flush_to_destination(interp, &aw, port_opt);
    return Value.unspecified;
}

/// `newline` is the implementation of the `newline` primitive function.
/// It writes a newline character to standard output.
///
/// Parameters:
/// - `args`: An empty `ValueList`.
///
/// Returns:
/// An unspecified value, or an error if writing to stdout fails.
pub fn newline(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len > 1) return ElzError.WrongArgumentCount;
    var aw: std.Io.Writer.Allocating = .init(env.allocator);
    defer aw.deinit();
    aw.writer.writeAll("\n") catch return ElzError.ForeignFunctionError;
    const port_opt: ?Value = if (args.items.len == 1) args.items[0] else null;
    try flush_to_destination(interp, &aw, port_opt);
    return Value.unspecified;
}

/// `load` is the implementation of the `load` primitive function.
/// It reads and evaluates the Elz code from the specified file.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
/// - `env`: The environment in which to evaluate the loaded code.
/// - `args`: A `ValueList` containing the filename (a string) to load.
/// - `fuel`: A pointer to the execution fuel counter.
///
/// Returns:
/// The result of the last evaluated expression in the file, or an error if loading or evaluation fails.
pub fn load(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const filename_val = args.items[0];
    if (filename_val != .string) return ElzError.InvalidArgument;

    const filename = filename_val.string.bytes;
    if (!interp.beginLoading(filename)) {
        interp.last_error_message = std.fmt.allocPrint(interp.allocator, "load: '{s}' loads itself", .{filename}) catch null;
        return ElzError.InvalidArgument;
    }
    defer interp.endLoading(filename);
    const source = std.Io.Dir.cwd().readFileAlloc(interp.io, filename, env.allocator, .limited(1 * 1024 * 1024)) catch |err| {
        interp.last_error_message = std.fmt.allocPrint(interp.allocator, "Failed to load file '{s}': {s}", .{ filename, @errorName(err) }) catch null;
        return ElzError.ForeignFunctionError;
    };
    defer env.allocator.free(source);

    var forms = parser.readAll(source, env.allocator) catch |e| return e;
    defer forms.deinit(env.allocator);
    if (forms.items.len == 0) return Value.unspecified;

    var last_result: Value = .unspecified;
    for (forms.items) |form| {
        last_result = try interp.evalForm(&form, fuel);
    }

    return if (last_result == .unspecified) Value.unspecified else last_result;
}

/// `read_string` parses a single S-expression from a string.
/// This is similar to R5RS `read`, but operates on strings.
///
/// Syntax: (read-string str)
///
/// Parameters:
/// - `args`: A `ValueList` containing a string to parse.
///
/// Returns:
/// The parsed S-expression as a Value, or an error if parsing fails.
pub fn read_string(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    // R7RS form: (read-string k [port]) reads up to k characters.
    if (args.items.len >= 1 and args.items[0] == .exact_integer) {
        return @import("ports.zig").read_string_k(interp, env, args, fuel);
    }
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const str_val = args.items[0];
    if (str_val != .string) return ElzError.InvalidArgument;

    const source = str_val.string.bytes;
    return parser.read(source, env.allocator) catch |err| switch (err) {
        // Match the port-based `read` and produce the eof object for empty input rather
        // than surfacing a parser-internal error.
        ElzError.EmptyInput => return Value.eof,
        else => return err,
    };
}

test "io primitives" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 1000;

    // Test load
    const filename = "test_load.elz";
    var file = std.Io.Dir.cwd().createFile(interp.io, filename, .{}) catch unreachable;
    defer file.close(interp.io);
    file.writeStreamingAll(interp.io, "(define x 42)") catch unreachable;

    var args = core.ValueList.init(interp.allocator);
    try args.append((try core.makeString(interp.allocator, filename)));

    _ = try load(&interp, interp.root_env, args, &fuel);

    const x = try interp.root_env.get("x", &interp);
    try testing.expect(x == .exact_integer);
    try testing.expectEqual(@as(i64, 42), x.exact_integer);

    std.Io.Dir.cwd().deleteFile(interp.io, filename) catch {};
}
