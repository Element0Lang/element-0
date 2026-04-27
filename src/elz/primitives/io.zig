const std = @import("std");
const core = @import("../core.zig");
const writer = @import("../writer.zig");
const parser = @import("../parser.zig");
const eval = @import("../eval.zig");
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
/// Renders a value in display mode (strings unquoted, chars as raw codepoints).
fn render_display(value: Value, w: *std.Io.Writer) !void {
    switch (value) {
        .string => |s| try w.writeAll(s),
        .character => |c| {
            if (c > 0x10FFFF) return ElzError.InvalidArgument;
            const codepoint: u21 = @intCast(c);
            if (!std.unicode.utf8ValidCodepoint(codepoint)) return ElzError.InvalidArgument;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &buf) catch return ElzError.InvalidArgument;
            try w.writeAll(buf[0..@as(usize, @intCast(len))]);
        },
        else => try writer.write(value, w),
    }
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
    render_display(args.items[0], &aw.writer) catch |err| switch (err) {
        ElzError.InvalidArgument => return ElzError.InvalidArgument,
        else => return ElzError.ForeignFunctionError,
    };
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

    const filename = filename_val.string;
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
        last_result = try eval.eval(interp, &form, env, fuel);
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
pub fn read_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const str_val = args.items[0];
    if (str_val != .string) return ElzError.InvalidArgument;

    const source = str_val.string;
    return parser.read(source, env.allocator);
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
    try args.append(Value{ .string = filename });

    _ = try load(&interp, interp.root_env, args, &fuel);

    const x = try interp.root_env.get("x", &interp);
    try testing.expect(x == .number);
    try testing.expectEqual(@as(f64, 42), x.number);

    std.Io.Dir.cwd().deleteFile(interp.io, filename) catch {};
}
