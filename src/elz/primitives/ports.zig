const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");
const parser = @import("../parser.zig");

/// `open_input_file` opens a file for reading.
/// Syntax: (open-input-file filename)
pub fn open_input_file(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const filename_val = args.items[0];
    if (filename_val != .string) return ElzError.InvalidArgument;

    const port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    port.* = core.Port.openInput(env.allocator, interp.io, filename_val.string) catch return ElzError.FileNotFound;

    return Value{ .port = port };
}

/// `open_output_file` opens a file for writing.
/// Syntax: (open-output-file filename)
pub fn open_output_file(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const filename_val = args.items[0];
    if (filename_val != .string) return ElzError.InvalidArgument;

    const port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    port.* = core.Port.openOutput(env.allocator, interp.io, filename_val.string) catch return ElzError.FileNotWritable;

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

/// `peek_char` returns the next character on an input port without consuming it.
/// Syntax: (peek-char port)
pub fn peek_char(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const port_val = args.items[0];
    if (port_val != .port) return ElzError.InvalidArgument;

    const char = port_val.port.peekChar() catch return ElzError.IOError;
    if (char) |c| {
        return Value{ .character = c };
    }
    return Value{ .symbol = "eof" };
}

/// `char_ready_p` reports whether a character is available on an input port.
/// File-backed ports always have a character available until end-of-file, so this
/// simply returns `#t` for any open input port.
/// Syntax: (char-ready? port)
pub fn char_ready_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const port_val = args.items[0];
    if (port_val != .port) return ElzError.InvalidArgument;
    return Value{ .boolean = port_val.port.is_input and port_val.port.is_open };
}

/// `write_char` writes a single character to an output port as UTF-8.
/// Syntax: (write-char char port)
pub fn write_char(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const char_val = args.items[0];
    const port_val = args.items[1];
    if (char_val != .character) return ElzError.InvalidArgument;
    if (port_val != .port) return ElzError.InvalidArgument;

    const cp = char_val.character;
    if (cp > 0x10FFFF) return ElzError.InvalidArgument;
    const codepoint: u21 = @intCast(cp);
    if (!std.unicode.utf8ValidCodepoint(codepoint)) return ElzError.InvalidArgument;

    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return ElzError.InvalidArgument;
    port_val.port.writeString(buf[0..@as(usize, @intCast(len))]) catch return ElzError.IOError;
    return Value.unspecified;
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

/// Returns true for ASCII whitespace.
fn is_whitespace_byte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Returns true for characters that terminate an atom token.
fn is_atom_delimiter(c: u8) bool {
    return is_whitespace_byte(c) or c == '(' or c == ')' or c == ';' or c == '"' or c == '\'';
}

/// Reads characters from the port until a single complete S-expression has been
/// accumulated, then returns its bytes (allocator-owned). Returns null on EOF before any
/// non-whitespace was seen.
fn slurp_one_datum(port: *core.Port, allocator: std.mem.Allocator) !?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var depth: i32 = 0;
    var seen_content = false;
    var in_string = false;

    while (true) {
        const c_opt = port.readChar() catch null;
        if (c_opt == null) {
            if (!seen_content) {
                buf.deinit(allocator);
                return null;
            }
            break;
        }
        const c = c_opt.?;

        if (in_string) {
            try buf.append(allocator, c);
            if (c == '\\') {
                const esc_opt = port.readChar() catch null;
                if (esc_opt) |esc| try buf.append(allocator, esc);
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }

        if (!seen_content) {
            if (is_whitespace_byte(c)) continue;
            if (c == ';') {
                while (true) {
                    const cc = port.readChar() catch null;
                    if (cc == null or cc.? == '\n') break;
                }
                continue;
            }
        }

        try buf.append(allocator, c);
        seen_content = true;

        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            depth -= 1;
            if (depth <= 0) break;
            continue;
        }
        if (c == '\'') continue;

        if (depth == 0) {
            const peek_opt = port.peekChar() catch null;
            if (peek_opt == null) break;
            if (is_atom_delimiter(peek_opt.?)) break;
        }
    }

    return try buf.toOwnedSlice(allocator);
}

/// `read` reads one S-expression from a port and returns it as a `Value`. On EOF, returns
/// the eof object.
/// Syntax: (read [port])
pub fn read(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len > 1) return ElzError.WrongArgumentCount;
    const port: *core.Port = blk: {
        if (args.items.len == 1) {
            const arg = args.items[0];
            if (arg != .port) return ElzError.InvalidArgument;
            break :blk arg.port;
        }
        break :blk interp.currentInputPort() catch return ElzError.OutOfMemory;
    };

    const slurped = slurp_one_datum(port, env.allocator) catch return ElzError.IOError;
    if (slurped == null) return Value{ .symbol = "eof" };
    defer env.allocator.free(slurped.?);

    return parser.read(slurped.?, env.allocator) catch |err| switch (err) {
        ElzError.EmptyInput => return Value{ .symbol = "eof" },
        else => return err,
    };
}

/// `current_input_port` returns the port wrapping the host's standard input.
/// Syntax: (current-input-port)
pub fn current_input_port(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;
    const port = interp.currentInputPort() catch return ElzError.OutOfMemory;
    return Value{ .port = port };
}

/// `current_output_port` returns the port wrapping the host's standard output.
/// Syntax: (current-output-port)
pub fn current_output_port(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;
    const port = interp.currentOutputPort() catch return ElzError.OutOfMemory;
    return Value{ .port = port };
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
    try args.append(Value{ .number = 42 });

    const is_port_result = try is_port(&interp, interp.root_env, args, &fuel);
    try testing.expect(is_port_result == .boolean);
    try testing.expect(is_port_result.boolean == false);

    // Test eof_object_p with eof symbol
    args.clearRetainingCapacity();
    try args.append(Value{ .symbol = "eof" });
    const eof_result = try eof_object_p(&interp, interp.root_env, args, &fuel);
    try testing.expect(eof_result == .boolean);
    try testing.expect(eof_result.boolean == true);

    // Test eof_object_p with non-eof symbol
    args.clearRetainingCapacity();
    try args.append(Value{ .symbol = "other" });
    const not_eof_result = try eof_object_p(&interp, interp.root_env, args, &fuel);
    try testing.expect(not_eof_result == .boolean);
    try testing.expect(not_eof_result.boolean == false);

    // Test is_input_port with non-port
    args.clearRetainingCapacity();
    try args.append(Value{ .string = "not a port" });
    const is_input_result = try is_input_port(&interp, interp.root_env, args, &fuel);
    try testing.expect(is_input_result == .boolean);
    try testing.expect(is_input_result.boolean == false);

    // Test is_output_port with non-port
    const is_output_result = try is_output_port(&interp, interp.root_env, args, &fuel);
    try testing.expect(is_output_result == .boolean);
    try testing.expect(is_output_result.boolean == false);
}
