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

/// Resolves the port argument for a read primitive: an explicit port when one
/// is given, the interpreter's current input port when the argument is omitted.
fn inputPortArg(interp: *interpreter.Interpreter, args: core.ValueList) ElzError!*core.Port {
    if (args.items.len == 0) {
        return interp.currentInputPort() catch return ElzError.OutOfMemory;
    }
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const port_val = args.items[0];
    if (port_val != .port) return ElzError.InvalidArgument;
    return port_val.port;
}

/// `read_line` reads a line from an input port.
/// Syntax: (read-line) or (read-line port)
pub fn read_line(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const port = try inputPortArg(interp, args);
    const line = port.readLine(env.allocator) catch return ElzError.IOError;
    if (line) |l| {
        return Value{ .string = l };
    }
    return EOF_VALUE;
}

/// `read_char` reads a single character from an input port.
/// Syntax: (read-char) or (read-char port)
pub fn read_char(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const port = try inputPortArg(interp, args);
    const char = port.readCodepoint() catch return ElzError.IOError;
    if (char) |c| {
        return Value{ .character = c };
    }
    return EOF_VALUE;
}

/// `peek_char` returns the next character on an input port without consuming it.
/// Syntax: (peek-char) or (peek-char port)
pub fn peek_char(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const port = try inputPortArg(interp, args);
    const char = port.peekCodepoint() catch return ElzError.IOError;
    if (char) |c| {
        return Value{ .character = c };
    }
    return EOF_VALUE;
}

/// `read_string` reads up to k characters from a textual input port.
/// Syntax: (read-string k) or (read-string k port)
pub fn read_string_k(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .exact_integer or args.items[0].exact_integer < 0) return ElzError.InvalidArgument;
    const k: usize = @intCast(args.items[0].exact_integer);
    var port_args = args;
    port_args.items = args.items[1..];
    const port = try inputPortArg(interp, port_args);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(env.allocator);
    var count: usize = 0;
    while (count < k) : (count += 1) {
        const cp = (port.readCodepoint() catch return ElzError.IOError) orelse break;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch return ElzError.IOError;
        out.appendSlice(env.allocator, buf[0..len]) catch return ElzError.OutOfMemory;
    }
    if (count == 0 and k > 0) return EOF_VALUE;
    return Value{ .string = out.toOwnedSlice(env.allocator) catch return ElzError.OutOfMemory };
}

/// `char_ready_p` reports whether a character is available on an input port.
/// File-backed ports always have a character available until end-of-file, so this
/// simply returns `#t` for any open input port.
/// Syntax: (char-ready?) or (char-ready? port)
pub fn char_ready_p(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const port = try inputPortArg(interp, args);
    return Value{ .boolean = port.is_input and port.is_open };
}

/// `write_char` writes a single character to an output port as UTF-8.
/// Syntax: (write-char char) or (write-char char port)
pub fn write_char(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;

    const char_val = args.items[0];
    if (char_val != .character) return ElzError.InvalidArgument;

    const port_val: Value = if (args.items.len == 2)
        args.items[1]
    else
        Value{ .port = interp.currentOutputPort() catch return ElzError.OutOfMemory };
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

        // A comment inside a datum runs to the end of the line.
        if (c == ';') {
            while (true) {
                const cc = port.readChar() catch null;
                if (cc == null or cc.? == '\n') break;
            }
            if (depth == 0 and seen_content) break;
            continue;
        }

        try buf.append(allocator, c);
        seen_content = true;

        if (c == '#') {
            const nx = port.peekChar() catch null;
            if (nx != null and nx.? == '\\') {
                // Character literal: the byte after the backslash is part of
                // the literal even when it is a delimiter such as `)`.
                _ = port.readChar() catch null;
                try buf.append(allocator, '\\');
                if (port.readChar() catch null) |lit| try buf.append(allocator, lit);
                if (depth == 0) break;
                continue;
            }
            if (nx != null and nx.? == '|') {
                // Block comment: copy it through and let the parser drop it.
                _ = port.readChar() catch null;
                try buf.append(allocator, '|');
                var nesting: usize = 1;
                var prev: u8 = 0;
                while (nesting > 0) {
                    const cc = (port.readChar() catch null) orelse break;
                    try buf.append(allocator, cc);
                    if (prev == '|' and cc == '#') {
                        nesting -= 1;
                        prev = 0;
                    } else if (prev == '#' and cc == '|') {
                        nesting += 1;
                        prev = 0;
                    } else prev = cc;
                }
                continue;
            }
        }

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

    // String-input ports use the full parser directly, advancing the port by
    // the bytes the datum consumed.
    switch (port.kind) {
        .string_input => |*sk| {
            // Bytes held by a pending peek were already consumed from the
            // stream; rewind over them.
            const pending = port.pendingBytes();
            port.clearPushback();
            const start = sk.pos - @min(pending, sk.pos);
            if (start >= sk.source.len) return EOF_VALUE;
            const one = parser.readOne(sk.source[start..], env.allocator) catch |err| return err;
            if (one == null) {
                sk.pos = sk.source.len;
                return EOF_VALUE;
            }
            sk.pos = start + one.?.consumed;
            return one.?.value;
        },
        else => {},
    }

    const slurped = slurp_one_datum(port, env.allocator) catch return ElzError.IOError;
    if (slurped == null) return EOF_VALUE;
    defer env.allocator.free(slurped.?);

    return parser.read(slurped.?, env.allocator) catch |err| switch (err) {
        ElzError.EmptyInput => return EOF_VALUE,
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

/// `set_current_output_port_bang` replaces the interpreter's current output port.
/// Syntax: (set-current-output-port! port)
pub fn set_current_output_port_bang(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (v != .port) return ElzError.InvalidArgument;
    interp.stdout_port = v.port;
    return Value.unspecified;
}

/// `open_input_string` creates an input port that reads from a string.
/// Syntax: (open-input-string str)
pub fn open_input_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const str_val = args.items[0];
    if (str_val != .string) return ElzError.InvalidArgument;
    const source = env.allocator.dupe(u8, str_val.string) catch return ElzError.OutOfMemory;
    const port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    port.* = core.Port.fromString(env.allocator, source) catch return ElzError.OutOfMemory;
    return Value{ .port = port };
}

/// `open_output_string` creates an output port that accumulates characters into a string.
/// Syntax: (open-output-string)
pub fn open_output_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;
    const port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    port.* = core.Port.openStringOutput(env.allocator) catch return ElzError.OutOfMemory;
    return Value{ .port = port };
}

/// `get_output_string` returns the string accumulated in a string output port.
/// Syntax: (get-output-string port)
pub fn get_output_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const port_val = args.items[0];
    if (port_val != .port) return ElzError.InvalidArgument;
    const s = port_val.port.getString(env.allocator) catch return ElzError.InvalidArgument;
    return Value{ .string = s };
}

/// `set_current_input_port_bang` replaces the interpreter's current input port.
/// Syntax: (set-current-input-port! port)
pub fn set_current_input_port_bang(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const v = args.items[0];
    if (v != .port) return ElzError.InvalidArgument;
    interp.stdin_port = v.port;
    return Value.unspecified;
}

/// `eof_object_p` checks if a value is the EOF object.
/// Syntax: (eof-object? obj)
pub fn eof_object_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .eof };
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
    try args.append(Value.eof);
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

test "string port primitives" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 10_000;

    // open-input-string / read-char
    var args = core.ValueList.init(interp.allocator);
    try args.append(Value{ .string = "hi" });
    const in_port_val = try open_input_string(&interp, interp.root_env, args, &fuel);
    try testing.expect(in_port_val == .port);
    try testing.expect(in_port_val.port.is_input);

    args.clearRetainingCapacity();
    try args.append(in_port_val);
    const c1 = try read_char(&interp, interp.root_env, args, &fuel);
    try testing.expect(c1 == .character);
    try testing.expectEqual(@as(u32, 'h'), c1.character);

    const c2 = try read_char(&interp, interp.root_env, args, &fuel);
    try testing.expectEqual(@as(u32, 'i'), c2.character);

    const eof_val = try read_char(&interp, interp.root_env, args, &fuel);
    try testing.expect(eof_val == .eof);

    // open-output-string / get-output-string
    args.clearRetainingCapacity();
    const out_port_val = try open_output_string(&interp, interp.root_env, args, &fuel);
    try testing.expect(out_port_val == .port);
    try testing.expect(!out_port_val.port.is_input);

    out_port_val.port.writeString("hello") catch unreachable;
    out_port_val.port.writeString(" world") catch unreachable;

    args.clearRetainingCapacity();
    try args.append(out_port_val);
    const str_val = try get_output_string(&interp, interp.root_env, args, &fuel);
    try testing.expect(str_val == .string);
    try testing.expectEqualStrings("hello world", str_val.string);
}

// ---------------------------------------------------------------------------
// Binary ports and port plumbing (R7RS)
// ---------------------------------------------------------------------------

pub const EOF_VALUE: Value = .eof;

/// Resolves the port argument for an output primitive at args[index]: explicit
/// when given, the current output port when omitted.
fn outputPortArg(interp: *interpreter.Interpreter, args: core.ValueList, index: usize) ElzError!*core.Port {
    if (args.items.len == index) {
        return interp.currentOutputPort() catch return ElzError.OutOfMemory;
    }
    if (args.items[index] != .port) return ElzError.InvalidArgument;
    return args.items[index].port;
}

/// Syntax: (eof-object)
pub fn eof_object(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;
    return EOF_VALUE;
}

/// Syntax: (open-input-bytevector bv)
pub fn open_input_bytevector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector) return ElzError.InvalidArgument;
    const copy = env.allocator.dupe(u8, args.items[0].bytevector.items) catch return ElzError.OutOfMemory;
    const port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    port.* = core.Port.fromString(env.allocator, copy) catch return ElzError.OutOfMemory;
    port.binary = true;
    return Value{ .port = port };
}

/// Syntax: (open-output-bytevector)
pub fn open_output_bytevector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;
    const port = env.allocator.create(core.Port) catch return ElzError.OutOfMemory;
    port.* = core.Port.openStringOutput(env.allocator) catch return ElzError.OutOfMemory;
    port.binary = true;
    return Value{ .port = port };
}

/// Syntax: (get-output-bytevector port)
pub fn get_output_bytevector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .port) return ElzError.InvalidArgument;
    const bytes = args.items[0].port.getString(env.allocator) catch return ElzError.InvalidArgument;
    const bv = env.allocator.create(core.Bytevector) catch return ElzError.OutOfMemory;
    bv.* = .{ .items = @constCast(bytes) };
    return Value{ .bytevector = bv };
}

/// Syntax: (open-binary-input-file path)
pub fn open_binary_input_file(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    const result = try open_input_file(interp, env, args, fuel);
    result.port.binary = true;
    return result;
}

/// Syntax: (open-binary-output-file path)
pub fn open_binary_output_file(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    const result = try open_output_file(interp, env, args, fuel);
    result.port.binary = true;
    return result;
}

/// Syntax: (read-u8) or (read-u8 port)
pub fn read_u8(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const port = try inputPortArg(interp, args);
    const byte = port.readChar() catch return ElzError.IOError;
    if (byte) |b| return Value{ .exact_integer = b };
    return EOF_VALUE;
}

/// Syntax: (peek-u8) or (peek-u8 port)
pub fn peek_u8(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const port = try inputPortArg(interp, args);
    const byte = port.peekChar() catch return ElzError.IOError;
    if (byte) |b| return Value{ .exact_integer = b };
    return EOF_VALUE;
}

/// Syntax: (u8-ready?) or (u8-ready? port)
pub fn u8_ready_p(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const port = try inputPortArg(interp, args);
    return Value{ .boolean = port.is_input and port.is_open };
}

/// Syntax: (write-u8 byte) or (write-u8 byte port)
pub fn write_u8(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .exact_integer or args.items[0].exact_integer < 0 or args.items[0].exact_integer > 255) return ElzError.InvalidArgument;
    const port = try outputPortArg(interp, args, 1);
    const byte = [1]u8{@intCast(args.items[0].exact_integer)};
    port.writeString(&byte) catch return ElzError.IOError;
    return Value.unspecified;
}

/// Syntax: (read-bytevector k) or (read-bytevector k port)
pub fn read_bytevector(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .exact_integer or args.items[0].exact_integer < 0) return ElzError.InvalidArgument;
    const k: usize = @intCast(args.items[0].exact_integer);
    var port_args = args;
    port_args.items = args.items[1..];
    const port = try inputPortArg(interp, port_args);

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(env.allocator);
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const byte = port.readChar() catch return ElzError.IOError;
        if (byte) |b| {
            try bytes.append(env.allocator, b);
        } else break;
    }
    if (bytes.items.len == 0 and k > 0) return EOF_VALUE;
    const bv = env.allocator.create(core.Bytevector) catch return ElzError.OutOfMemory;
    bv.* = .{ .items = try bytes.toOwnedSlice(env.allocator) };
    return Value{ .bytevector = bv };
}

/// Syntax: (read-bytevector! bv) or (read-bytevector! bv port [start [end]])
pub fn read_bytevector_bang(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 4) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector) return ElzError.InvalidArgument;
    const items = args.items[0].bytevector.items;
    const port = if (args.items.len >= 2) blk: {
        if (args.items[1] != .port) return ElzError.InvalidArgument;
        break :blk args.items[1].port;
    } else interp.currentInputPort() catch return ElzError.OutOfMemory;
    var start: usize = 0;
    var end: usize = items.len;
    if (args.items.len >= 3) {
        if (args.items[2] != .exact_integer or args.items[2].exact_integer < 0) return ElzError.InvalidArgument;
        start = @intCast(args.items[2].exact_integer);
    }
    if (args.items.len == 4) {
        if (args.items[3] != .exact_integer or args.items[3].exact_integer < 0) return ElzError.InvalidArgument;
        end = @intCast(args.items[3].exact_integer);
    }
    if (start > end or end > items.len) return ElzError.InvalidArgument;

    var count: usize = 0;
    while (start + count < end) {
        const byte = port.readChar() catch return ElzError.IOError;
        if (byte) |b| {
            items[start + count] = b;
            count += 1;
        } else break;
    }
    if (count == 0 and start < end) return EOF_VALUE;
    return Value{ .exact_integer = @intCast(count) };
}

/// Syntax: (write-bytevector bv) or (write-bytevector bv port [start [end]])
pub fn write_bytevector(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 4) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector) return ElzError.InvalidArgument;
    const items = args.items[0].bytevector.items;
    const port = try outputPortArg(interp, args, if (args.items.len >= 2) 1 else args.items.len);
    var start: usize = 0;
    var end: usize = items.len;
    if (args.items.len >= 3) {
        if (args.items[2] != .exact_integer or args.items[2].exact_integer < 0) return ElzError.InvalidArgument;
        start = @intCast(args.items[2].exact_integer);
    }
    if (args.items.len == 4) {
        if (args.items[3] != .exact_integer or args.items[3].exact_integer < 0) return ElzError.InvalidArgument;
        end = @intCast(args.items[3].exact_integer);
    }
    if (start > end or end > items.len) return ElzError.InvalidArgument;
    port.writeString(items[start..end]) catch return ElzError.IOError;
    return Value.unspecified;
}

/// Syntax: (binary-port? obj)
pub fn binary_port_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .port and args.items[0].port.binary };
}

/// Syntax: (textual-port? obj)
pub fn textual_port_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .port and !args.items[0].port.binary };
}

/// Syntax: (close-port port)
pub fn close_port(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .port) return ElzError.InvalidArgument;
    args.items[0].port.close();
    return Value.unspecified;
}

/// Syntax: (input-port-open? port)
pub fn input_port_open_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .port) return ElzError.InvalidArgument;
    const port = args.items[0].port;
    return Value{ .boolean = port.is_input and port.is_open };
}

/// Syntax: (output-port-open? port)
pub fn output_port_open_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .port) return ElzError.InvalidArgument;
    const port = args.items[0].port;
    return Value{ .boolean = !port.is_input and port.is_open };
}

/// Syntax: (flush-output-port) or (flush-output-port port)
/// Ports write through unbuffered, so this only validates its argument.
pub fn flush_output_port(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const port = try outputPortArg(interp, args, 0);
    if (port.is_input) return ElzError.InvalidArgument;
    return Value.unspecified;
}

/// Syntax: (current-error-port)
pub fn current_error_port(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;
    const port = interp.currentErrorPort() catch return ElzError.OutOfMemory;
    return Value{ .port = port };
}
