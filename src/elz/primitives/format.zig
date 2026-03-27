const std = @import("std");
const core = @import("../core.zig");
const writer_mod = @import("../writer.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// Writes a value in display mode (strings without quotes, chars as raw characters).
fn writeDisplay(value: Value, w: anytype) !void {
    switch (value) {
        .string => |s| try w.writeAll(s),
        .character => |c| {
            if (c > 0x10FFFF) return;
            const codepoint: u21 = @intCast(c);
            if (!std.unicode.utf8ValidCodepoint(codepoint)) return;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &buf) catch return;
            try w.writeAll(buf[0..@as(usize, @intCast(len))]);
        },
        else => try writer_mod.write(value, w),
    }
}

/// `format` implements the `format` primitive function.
///
/// Syntax: (format template arg ...)
///
/// Directives:
///   ~a  - display mode (strings without quotes)
///   ~s  - write mode (machine-readable, strings with quotes)
///   ~%  - newline
///   ~~  - literal tilde
///
/// Returns the formatted string.
pub fn format(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;

    const template_val = args.items[0];
    if (template_val != .string) return ElzError.InvalidArgument;
    const template = template_val.string;

    var result = std.ArrayListUnmanaged(u8){};
    const allocator = env.allocator;
    errdefer result.deinit(allocator);

    var arg_idx: usize = 1;
    var i: usize = 0;

    while (i < template.len) {
        if (template[i] == '~' and i + 1 < template.len) {
            const directive = template[i + 1];
            switch (directive) {
                'a' => {
                    if (arg_idx >= args.items.len) return ElzError.WrongArgumentCount;
                    writeDisplay(args.items[arg_idx], result.writer(allocator)) catch return ElzError.OutOfMemory;
                    arg_idx += 1;
                },
                's' => {
                    if (arg_idx >= args.items.len) return ElzError.WrongArgumentCount;
                    writer_mod.write(args.items[arg_idx], result.writer(allocator)) catch return ElzError.OutOfMemory;
                    arg_idx += 1;
                },
                '%' => {
                    result.append(allocator, '\n') catch return ElzError.OutOfMemory;
                },
                '~' => {
                    result.append(allocator, '~') catch return ElzError.OutOfMemory;
                },
                else => {
                    // Unknown directive, output as-is
                    result.append(allocator, '~') catch return ElzError.OutOfMemory;
                    result.append(allocator, directive) catch return ElzError.OutOfMemory;
                },
            }
            i += 2;
        } else {
            result.append(allocator, template[i]) catch return ElzError.OutOfMemory;
            i += 1;
        }
    }

    return Value{ .string = result.toOwnedSlice(allocator) catch return ElzError.OutOfMemory };
}

/// `value->string` converts any value to its string representation (write mode).
///
/// Syntax: (value->string val)
///
/// Returns the string representation of the value.
pub fn value_to_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    var buf = std.ArrayListUnmanaged(u8){};
    const allocator = env.allocator;
    errdefer buf.deinit(allocator);

    writer_mod.write(args.items[0], buf.writer(allocator)) catch return ElzError.OutOfMemory;
    return Value{ .string = buf.toOwnedSlice(allocator) catch return ElzError.OutOfMemory };
}

test "format basic substitution" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;

    // ~a with string (no quotes)
    const r1 = try interp.evalString("(format \"hello ~a\" \"world\")", &fuel);
    try testing.expect(r1 == .string);
    try testing.expectEqualStrings("hello world", r1.string);

    // ~s with string (with quotes)
    fuel = 10000;
    const r2 = try interp.evalString("(format \"hello ~s\" \"world\")", &fuel);
    try testing.expect(r2 == .string);
    try testing.expectEqualStrings("hello \"world\"", r2.string);

    // ~% newline
    fuel = 10000;
    const r3 = try interp.evalString("(format \"line1~%line2\")", &fuel);
    try testing.expect(r3 == .string);
    try testing.expectEqualStrings("line1\nline2", r3.string);

    // ~~ literal tilde
    fuel = 10000;
    const r4 = try interp.evalString("(format \"cost: ~~100\")", &fuel);
    try testing.expect(r4 == .string);
    try testing.expectEqualStrings("cost: ~100", r4.string);
}

test "format with numbers" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r1 = try interp.evalString("(format \"x = ~a\" 42)", &fuel);
    try testing.expect(r1 == .string);
    try testing.expectEqualStrings("x = 42", r1.string);
}

test "format with multiple args" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r1 = try interp.evalString("(format \"~a + ~a = ~a\" 1 2 3)", &fuel);
    try testing.expect(r1 == .string);
    try testing.expectEqualStrings("1 + 2 = 3", r1.string);
}

test "format with no template args" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r1 = try interp.evalString("(format \"plain text\")", &fuel);
    try testing.expect(r1 == .string);
    try testing.expectEqualStrings("plain text", r1.string);
}

test "format error on too few args" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    try testing.expectError(ElzError.WrongArgumentCount, interp.evalString("(format \"~a ~a\" 1)", &fuel));
}

test "format error on non-string template" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    try testing.expectError(ElzError.InvalidArgument, interp.evalString("(format 42)", &fuel));
}
