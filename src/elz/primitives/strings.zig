const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `symbol_to_string` converts a symbol to a string.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single symbol.
pub fn symbol_to_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const sym = args.items[0];
    if (sym != .symbol) return ElzError.InvalidArgument;
    const str = try env.allocator.dupe(u8, sym.symbol);
    return Value{ .string = str };
}

/// `string_to_symbol` converts a string to a symbol.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single string.
pub fn string_to_symbol(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const str = args.items[0];
    if (str != .string) return ElzError.InvalidArgument;
    const sym = try env.allocator.dupe(u8, str.string);
    return Value{ .symbol = sym };
}

/// `string_length` returns the number of characters in a string.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single string.
pub fn string_length(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const str = args.items[0];
    if (str != .string) return ElzError.InvalidArgument;
    const len = std.unicode.utf8CountCodepoints(str.string) catch return ElzError.InvalidArgument;
    return Value{ .number = @floatFromInt(len) };
}

/// `string_append` concatenates multiple strings into a single string.
///
/// Parameters:
/// - `args`: A `ValueList` of strings to be appended.
pub fn string_append(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(env.allocator);

    for (args.items) |arg| {
        switch (arg) {
            .string => |s| try buffer.appendSlice(env.allocator, s),
            else => return ElzError.InvalidArgument,
        }
    }

    return Value{ .string = try buffer.toOwnedSlice(env.allocator) };
}

/// `char_eq` checks if two characters are equal.
///
/// Parameters:
/// - `args`: A `ValueList` containing two characters.
pub fn char_eq(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .character or b != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = a.character == b.character };
}

/// `char_lt` checks if the first character is less than the second.
pub fn char_lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .character or b != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = a.character < b.character };
}

/// `char_gt` checks if the first character is greater than the second.
pub fn char_gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .character or b != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = a.character > b.character };
}

/// `char_le` checks if the first character is less than or equal to the second.
pub fn char_le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .character or b != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = a.character <= b.character };
}

/// `char_ge` checks if the first character is greater than or equal to the second.
pub fn char_ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .character or b != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = a.character >= b.character };
}

/// Folds an ASCII letter to lowercase. Non-ASCII code points pass through unchanged.
fn ascii_fold_lower(c: u32) u32 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn char_ci_compare(args: core.ValueList) ElzError!struct { a: u32, b: u32 } {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .character or b != .character) return ElzError.InvalidArgument;
    return .{ .a = ascii_fold_lower(a.character), .b = ascii_fold_lower(b.character) };
}

/// `char_ci_eq` checks two characters for equality, case-insensitive over ASCII.
pub fn char_ci_eq(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const pair = try char_ci_compare(args);
    return Value{ .boolean = pair.a == pair.b };
}

/// `char_ci_lt` is the case-insensitive less-than comparison.
pub fn char_ci_lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const pair = try char_ci_compare(args);
    return Value{ .boolean = pair.a < pair.b };
}

/// `char_ci_gt` is the case-insensitive greater-than comparison.
pub fn char_ci_gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const pair = try char_ci_compare(args);
    return Value{ .boolean = pair.a > pair.b };
}

/// `char_ci_le` is the case-insensitive less-than-or-equal comparison.
pub fn char_ci_le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const pair = try char_ci_compare(args);
    return Value{ .boolean = pair.a <= pair.b };
}

/// `char_ci_ge` is the case-insensitive greater-than-or-equal comparison.
pub fn char_ci_ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const pair = try char_ci_compare(args);
    return Value{ .boolean = pair.a >= pair.b };
}

fn char_arg(args: core.ValueList) ElzError!u32 {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const c = args.items[0];
    if (c != .character) return ElzError.InvalidArgument;
    return c.character;
}

/// `char_alphabetic_p` returns `#t` for ASCII letters.
pub fn char_alphabetic_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const cp = try char_arg(args);
    const is_alpha = (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z');
    return Value{ .boolean = is_alpha };
}

/// `char_numeric_p` returns `#t` for ASCII decimal digits.
pub fn char_numeric_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const cp = try char_arg(args);
    return Value{ .boolean = cp >= '0' and cp <= '9' };
}

/// `char_whitespace_p` returns `#t` for ASCII whitespace.
pub fn char_whitespace_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const cp = try char_arg(args);
    const is_ws = cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0B or cp == 0x0C;
    return Value{ .boolean = is_ws };
}

/// `char_upper_case_p` returns `#t` for ASCII uppercase letters.
pub fn char_upper_case_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const cp = try char_arg(args);
    return Value{ .boolean = cp >= 'A' and cp <= 'Z' };
}

/// `char_lower_case_p` returns `#t` for ASCII lowercase letters.
pub fn char_lower_case_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const cp = try char_arg(args);
    return Value{ .boolean = cp >= 'a' and cp <= 'z' };
}

/// `char_upcase` returns the ASCII uppercase form of a character. Non-letters pass through.
pub fn char_upcase(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const cp = try char_arg(args);
    const folded: u32 = if (cp >= 'a' and cp <= 'z') cp - 32 else cp;
    return Value{ .character = folded };
}

/// `char_downcase` returns the ASCII lowercase form of a character. Non-letters pass through.
pub fn char_downcase(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const cp = try char_arg(args);
    return Value{ .character = ascii_fold_lower(cp) };
}

/// `char_to_integer` converts a character to its Unicode code point.
pub fn char_to_integer(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const c = args.items[0];
    if (c != .character) return ElzError.InvalidArgument;
    return Value{ .number = @floatFromInt(c.character) };
}

/// `integer_to_char` converts a Unicode code point to a character.
pub fn integer_to_char(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const n = args.items[0];
    if (n != .number) return ElzError.InvalidArgument;
    const num = n.number;
    if (num < 0 or @floor(num) != num or num > 0x10FFFF) return ElzError.InvalidArgument;
    return Value{ .character = @intFromFloat(num) };
}

/// `string_ref` returns the character at a given index in a string.
/// Index is 0-based.
///
/// Parameters:
/// - `args`: A `ValueList` containing a string and an index.
pub fn string_ref(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const str = args.items[0];
    const idx = args.items[1];
    if (str != .string) return ElzError.InvalidArgument;
    if (idx != .number) return ElzError.InvalidArgument;

    const index = idx.number;
    if (index < 0 or @floor(index) != index) return ElzError.InvalidArgument;

    const idx_usize: usize = @intFromFloat(index);

    // Iterate through UTF-8 codepoints to find the character at the given index
    var it = std.unicode.Utf8View.initUnchecked(str.string).iterator();
    var current_idx: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (current_idx == idx_usize) {
            return Value{ .character = cp };
        }
        current_idx += 1;
    }

    // Index out of bounds
    return ElzError.InvalidArgument;
}

/// `substring` extracts a portion of a string.
/// Takes a string, start index, and end index (exclusive).
///
/// Parameters:
/// - `args`: A `ValueList` containing a string, start index, and end index.
pub fn substring(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;
    const str = args.items[0];
    const start_val = args.items[1];
    const end_val = args.items[2];

    if (str != .string) return ElzError.InvalidArgument;
    if (start_val != .number or end_val != .number) return ElzError.InvalidArgument;

    const start = start_val.number;
    const end = end_val.number;

    if (start < 0 or end < 0 or @floor(start) != start or @floor(end) != end) {
        return ElzError.InvalidArgument;
    }

    const start_idx: usize = @intFromFloat(start);
    const end_idx: usize = @intFromFloat(end);

    if (start_idx > end_idx) return ElzError.InvalidArgument;

    // Handle special case: empty substring from start
    if (start_idx == 0 and end_idx == 0) {
        return Value{ .string = try env.allocator.dupe(u8, "") };
    }

    // Find byte offsets for the character indices
    var it = std.unicode.Utf8View.initUnchecked(str.string).iterator();
    var current_idx: usize = 0;
    var start_byte: usize = 0;
    var end_byte: usize = str.string.len;
    var found_start = start_idx == 0; // start_idx 0 is always at byte 0
    var found_end = false;

    var byte_offset: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        if (current_idx == start_idx) {
            start_byte = byte_offset;
            found_start = true;
        }
        if (current_idx == end_idx) {
            end_byte = byte_offset;
            found_end = true;
            break;
        }
        byte_offset += slice.len;
        current_idx += 1;
    }

    // Handle edge case: end is at string length
    if (!found_end and current_idx == end_idx) {
        end_byte = byte_offset;
        found_end = true;
    }

    if (!found_start or !found_end) {
        return ElzError.InvalidArgument;
    }

    if (start_byte > end_byte) return ElzError.InvalidArgument;

    const result = try env.allocator.dupe(u8, str.string[start_byte..end_byte]);
    return Value{ .string = result };
}

/// `number_to_string` converts a number to its string representation.
/// Syntax: (number->string num)
pub fn number_to_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const num_val = args.items[0];
    if (num_val != .number) return ElzError.InvalidArgument;

    const num = num_val.number;

    // Format the number, removing unnecessary decimal places for integers
    var buf: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return ElzError.OutOfMemory;

    return Value{ .string = try env.allocator.dupe(u8, formatted) };
}

/// `string_to_number` converts a string to a number.
/// Syntax: (string->number str)
/// Returns #f if the string cannot be parsed as a number.
pub fn string_to_number(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const str_val = args.items[0];
    if (str_val != .string) return ElzError.InvalidArgument;

    const str = str_val.string;
    const num = std.fmt.parseFloat(f64, str) catch {
        return Value{ .boolean = false };
    };

    return Value{ .number = num };
}

/// `string_split` splits a string by a delimiter into a list of strings.
/// Syntax: (string-split str delim)
pub fn string_split(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const str_val = args.items[0];
    const delim_val = args.items[1];

    if (str_val != .string) return ElzError.InvalidArgument;
    if (delim_val != .string) return ElzError.InvalidArgument;

    const str = str_val.string;
    const delim = delim_val.string;

    if (delim.len == 0) return ElzError.InvalidArgument;

    // Build a list of substrings
    var result: Value = Value.nil;
    var temp_parts = std.ArrayListUnmanaged([]const u8).empty;
    defer temp_parts.deinit(env.allocator);

    var it = std.mem.splitSequence(u8, str, delim);
    while (it.next()) |part| {
        try temp_parts.append(env.allocator, part);
    }

    // Build the list in reverse order
    var i = temp_parts.items.len;
    while (i > 0) {
        i -= 1;
        const pair = try env.allocator.create(core.Pair);
        pair.* = .{
            .car = Value{ .string = try env.allocator.dupe(u8, temp_parts.items[i]) },
            .cdr = result,
        };
        result = Value{ .pair = pair };
    }

    return result;
}

/// `make_string` creates a string of k characters.
/// Syntax: (make-string k) or (make-string k char)
pub fn make_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;

    const k_val = args.items[0];
    if (k_val != .number) return ElzError.InvalidArgument;

    const k = k_val.number;
    if (k < 0 or @floor(k) != k) return ElzError.InvalidArgument;

    const length: usize = @intFromFloat(k);

    if (args.items.len == 2) {
        const char_val = args.items[1];
        if (char_val != .character) return ElzError.InvalidArgument;

        const codepoint = char_val.character;
        if (codepoint > 0x10FFFF) return ElzError.InvalidArgument;

        const cp: u21 = @intCast(codepoint);
        if (!std.unicode.utf8ValidCodepoint(cp)) return ElzError.InvalidArgument;

        // Encode the codepoint to UTF-8
        var char_buf: [4]u8 = undefined;
        const char_len = std.unicode.utf8Encode(cp, &char_buf) catch return ElzError.InvalidArgument;

        // Allocate result string (length * char_len bytes)
        const result = try env.allocator.alloc(u8, length * char_len);
        var i: usize = 0;
        while (i < length) : (i += 1) {
            @memcpy(result[i * char_len .. (i + 1) * char_len], char_buf[0..char_len]);
        }
        return Value{ .string = result };
    } else {
        // Default fill is space
        const result = try env.allocator.alloc(u8, length);
        @memset(result, ' ');
        return Value{ .string = result };
    }
}

/// `string_eq` checks if two strings are equal.
/// Syntax: (string=? str1 str2)
pub fn string_eq(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .string or b != .string) return ElzError.InvalidArgument;
    return Value{ .boolean = std.mem.eql(u8, a.string, b.string) };
}

/// `string_lt` checks if the first string is lexicographically less than the second.
/// Syntax: (string<? str1 str2)
pub fn string_lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .string or b != .string) return ElzError.InvalidArgument;
    const order = std.mem.order(u8, a.string, b.string);
    return Value{ .boolean = order == .lt };
}

/// `string_gt` checks if the first string is lexicographically greater than the second.
/// Syntax: (string>? str1 str2)
pub fn string_gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .string or b != .string) return ElzError.InvalidArgument;
    const order = std.mem.order(u8, a.string, b.string);
    return Value{ .boolean = order == .gt };
}

/// `string_le` checks if the first string is lexicographically less than or equal to the second.
/// Syntax: (string<=? str1 str2)
pub fn string_le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .string or b != .string) return ElzError.InvalidArgument;
    const order = std.mem.order(u8, a.string, b.string);
    return Value{ .boolean = order != .gt };
}

/// `string_ge` checks if the first string is lexicographically greater than or equal to the second.
/// Syntax: (string>=? str1 str2)
pub fn string_ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const a = args.items[0];
    const b = args.items[1];
    if (a != .string or b != .string) return ElzError.InvalidArgument;
    const order = std.mem.order(u8, a.string, b.string);
    return Value{ .boolean = order != .lt };
}

/// `gensym` generates a unique symbol.
/// Syntax: (gensym) or (gensym prefix)
pub fn gensym(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const prefix = if (args.items.len >= 1) blk: {
        const p = args.items[0];
        if (p != .string and p != .symbol) return ElzError.InvalidArgument;
        break :blk if (p == .string) p.string else p.symbol;
    } else "g";

    interp.gensym_counter += 1;
    var buf: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, interp.gensym_counter }) catch return ElzError.OutOfMemory;

    return Value{ .symbol = try env.allocator.dupe(u8, formatted) };
}

test "string primitives" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // Test symbol->string
    var args = core.ValueList.init(interp.allocator);
    try args.append(interp.allocator, Value{ .symbol = "foo" });
    var result = try symbol_to_string(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == Value{ .string = "foo" });

    // Test string->symbol
    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .string = "bar" });
    result = try string_to_symbol(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == Value{ .symbol = "bar" });

    // Test string-length
    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .string = "hello" });
    result = try string_length(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == Value{ .number = 5 });

    // Test char=?
    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .character = 'a' });
    try args.append(interp.allocator, Value{ .character = 'a' });
    result = try char_eq(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == Value{ .boolean = true });
}

test "char-ci comparisons" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    var args = core.ValueList.init(interp.allocator);
    try args.append(interp.allocator, Value{ .character = 'A' });
    try args.append(interp.allocator, Value{ .character = 'a' });
    try testing.expect((try char_ci_eq(&interp, interp.root_env, args, &fuel)).boolean == true);
    try testing.expect((try char_ci_le(&interp, interp.root_env, args, &fuel)).boolean == true);
    try testing.expect((try char_ci_ge(&interp, interp.root_env, args, &fuel)).boolean == true);
    try testing.expect((try char_ci_lt(&interp, interp.root_env, args, &fuel)).boolean == false);
    try testing.expect((try char_ci_gt(&interp, interp.root_env, args, &fuel)).boolean == false);

    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .character = 'a' });
    try args.append(interp.allocator, Value{ .character = 'B' });
    try testing.expect((try char_ci_lt(&interp, interp.root_env, args, &fuel)).boolean == true);
}

test "char predicates" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    var args = core.ValueList.init(interp.allocator);
    try args.append(interp.allocator, Value{ .character = 'A' });
    try testing.expect((try char_alphabetic_p(&interp, interp.root_env, args, &fuel)).boolean == true);
    try testing.expect((try char_upper_case_p(&interp, interp.root_env, args, &fuel)).boolean == true);
    try testing.expect((try char_lower_case_p(&interp, interp.root_env, args, &fuel)).boolean == false);
    try testing.expect((try char_numeric_p(&interp, interp.root_env, args, &fuel)).boolean == false);
    try testing.expect((try char_whitespace_p(&interp, interp.root_env, args, &fuel)).boolean == false);

    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .character = '7' });
    try testing.expect((try char_numeric_p(&interp, interp.root_env, args, &fuel)).boolean == true);
    try testing.expect((try char_alphabetic_p(&interp, interp.root_env, args, &fuel)).boolean == false);

    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .character = ' ' });
    try testing.expect((try char_whitespace_p(&interp, interp.root_env, args, &fuel)).boolean == true);
}

test "char case conversion" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    var args = core.ValueList.init(interp.allocator);
    try args.append(interp.allocator, Value{ .character = 'a' });
    try testing.expect((try char_upcase(&interp, interp.root_env, args, &fuel)).character == 'A');
    try testing.expect((try char_downcase(&interp, interp.root_env, args, &fuel)).character == 'a');

    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .character = 'Z' });
    try testing.expect((try char_downcase(&interp, interp.root_env, args, &fuel)).character == 'z');

    // Non-letters pass through.
    args.clearRetainingCapacity();
    try args.append(interp.allocator, Value{ .character = '5' });
    try testing.expect((try char_upcase(&interp, interp.root_env, args, &fuel)).character == '5');
    try testing.expect((try char_downcase(&interp, interp.root_env, args, &fuel)).character == '5');
}
