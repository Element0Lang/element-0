const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `open_input_file` opens a file for reading.
/// Syntax: (open-input-file filename)
pub fn open_input_file(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const filename_val = args.items[0];
    if (filename_val != .string) return ElzError.InvalidArgument;

    const port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    port.* = core.Port.openInput(env.allocator, filename_val.string) catch return ElzError.FileNotFound;

    return Value{ .port = port };
}

/// `open_output_file` opens a file for writing.
/// Syntax: (open-output-file filename)
pub fn open_output_file(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const filename_val = args.items[0];
    if (filename_val != .string) return ElzError.InvalidArgument;

    const port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    port.* = core.Port.openOutput(env.allocator, filename_val.string) catch return ElzError.FileNotWritable;

    return Value{ .port = port };
}

/// `close_input_port` closes an input port.
/// Syntax: (close-input-port port)
pub fn close_input_port(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const port_val = args.items[0];
    if (port_val != .port) return ElzError.InvalidArgument;

    port_val.port.close();
    return Value.unspecified;
}

/// `close_output_port` closes an output port.
/// Syntax: (close-output-port port)
pub fn close_output_port(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const port_val = args.items[0];
    if (port_val != .port) return ElzError.InvalidArgument;

    port_val.port.close();
    return Value.unspecified;
}

/// `read_line` reads a line from an input port.
/// Syntax: (read-line port)
pub fn read_line(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const port_val = args.items[0];
    if (port_val != .port) return ElzError.InvalidArgument;

    const line = port_val.port.readLine(env.allocator) catch return ElzError.IOError;
    if (line) |l| {
        return Value{ .string = l };
    }
    // Return EOF symbol
    return Value{ .symbol = "eof" };
}

/// `read_char` reads a single character from an input port.
/// Syntax: (read-char port)
pub fn read_char(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const port_val = args.items[0];
    if (port_val != .port) return ElzError.InvalidArgument;

    const char = port_val.port.readChar() catch return ElzError.IOError;
    if (char) |c| {
        return Value{ .character = c };
    }
    // Return EOF symbol
    return Value{ .symbol = "eof" };
}

/// `write_string_to_port` writes a string to an output port.
/// Syntax: (write-port str port)
pub fn write_to_port(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const str_val = args.items[0];
    const port_val = args.items[1];

    if (str_val != .string) return ElzError.InvalidArgument;
    if (port_val != .port) return ElzError.InvalidArgument;

    port_val.port.writeString(str_val.string) catch return ElzError.IOError;
    return Value.unspecified;
}

/// `is_input_port` checks if a value is an input port.
/// Syntax: (input-port? obj)
pub fn is_input_port(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return Value{ .boolean = (v == .port and v.port.is_input) };
}

/// `is_output_port` checks if a value is an output port.
/// Syntax: (output-port? obj)
pub fn is_output_port(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    return Value{ .boolean = (v == .port and !v.port.is_input) };
}

/// `is_port` checks if a value is a port.
/// Syntax: (port? obj)
pub fn is_port(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .port };
}

/// `eof_object_p` checks if a value is the EOF object.
/// Syntax: (eof-object? obj)
pub fn eof_object_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (v == .symbol) {
        return Value{ .boolean = std.mem.eql(u8, v.symbol, "eof") };
    }
    return Value{ .boolean = false };
}

test "port primitives" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // Test is_port with non-port value
    var args = core.ValueList.init(interp.allocator);
    try args.append(interp.allocator, Value{ .number = 42 });

    const is_port_result = try is_port(&interp, interp.root_env, args, &fuel);
    try testing.expect(is_port_result == .boolean);
    try testing.expect(is_port_result.boolean == false);

    // Test eof_object_p with eof symbol
    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .symbol = "eof" });
    const eof_result = try eof_object_p(&interp, interp.root_env, args, &fuel);
    try testing.expect(eof_result == .boolean);
    try testing.expect(eof_result.boolean == true);

    // Test eof_object_p with non-eof symbol
    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .symbol = "other" });
    const not_eof_result = try eof_object_p(&interp, interp.root_env, args, &fuel);
    try testing.expect(not_eof_result == .boolean);
    try testing.expect(not_eof_result.boolean == false);

    // Test is_input_port with non-port
    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .string = "not a port" });
    const is_input_result = try is_input_port(&interp, interp.root_env, args, &fuel);
    try testing.expect(is_input_result == .boolean);
    try testing.expect(is_input_result.boolean == false);

    // Test is_output_port with non-port
    const is_output_result = try is_output_port(&interp, interp.root_env, args, &fuel);
    try testing.expect(is_output_result == .boolean);
    try testing.expect(is_output_result.boolean == false);
}
