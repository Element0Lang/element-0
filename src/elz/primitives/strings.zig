const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// Converts a numeric `Value` to a non-negative `usize` index.
fn toIndex(v: Value) ElzError!usize {
    return switch (v) {
        .exact_integer => |i| std.math.cast(usize, i) orelse ElzError.InvalidArgument,
        .number => |n| blk: {
            // Reject non-finite and out-of-range values: `@intFromFloat` is
            // illegal behavior unless the value fits the destination type.
            if (!std.math.isFinite(n) or n < 0 or @floor(n) != n) break :blk ElzError.InvalidArgument;
            if (n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) break :blk ElzError.InvalidArgument;
            break :blk @intFromFloat(n);
        },
        else => ElzError.InvalidArgument,
    };
}

/// Converts a numeric `Value` to an `i64`, rejecting non-finite values and
/// values outside the `i64` range (`@intFromFloat` would be illegal behavior).
fn toI64(v: Value) ElzError!i64 {
    return switch (v) {
        .exact_integer => |i| i,
        .number => |n| blk: {
            if (!std.math.isFinite(n) or @floor(n) != n) break :blk ElzError.InvalidArgument;
            if (n >= @as(f64, @floatFromInt(std.math.maxInt(i64))) or
                n < @as(f64, @floatFromInt(std.math.minInt(i64)))) break :blk ElzError.InvalidArgument;
            break :blk @intFromFloat(n);
        },
        else => ElzError.InvalidArgument,
    };
}

/// `symbol_to_string` converts a symbol to a string.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single symbol.
/// Simple one-to-one Unicode case mapping covering ASCII, Latin-1, Greek,
/// and Cyrillic. Multi-character special casings (like the German sharp s
/// to "SS") are not applied.
fn unicodeUpcase(c: u32) u32 {
    if (c < 128) return std.ascii.toUpper(@intCast(c));
    return switch (c) {
        0x00E0...0x00F6, 0x00F8...0x00FE => c - 0x20, // Latin-1
        0x03B1...0x03C1, 0x03C3...0x03C9 => c - 0x20, // Greek alpha to omega
        0x03C2 => 0x03A3, // final sigma
        0x03AC => 0x0386,
        0x03AD...0x03AF => c - 0x25,
        0x03CC => 0x038C,
        0x03CD...0x03CE => c - 0x3F,
        0x0430...0x044F => c - 0x20, // Cyrillic
        0x0450...0x045F => c - 0x50,
        else => c,
    };
}

fn unicodeDowncase(c: u32) u32 {
    if (c < 128) return std.ascii.toLower(@intCast(c));
    return switch (c) {
        0x00C0...0x00D6, 0x00D8...0x00DE => c + 0x20, // Latin-1
        0x0391...0x03A1, 0x03A3...0x03A9 => c + 0x20, // Greek
        0x0386 => 0x03AC,
        0x0388...0x038A => c + 0x25,
        0x038C => 0x03CC,
        0x038E...0x038F => c + 0x3F,
        0x0410...0x042F => c + 0x20, // Cyrillic
        0x0400...0x040F => c + 0x50,
        else => c,
    };
}

/// Resolves optional character-indexed [start [end]] arguments (starting at
/// args index `from`) into a byte slice of `str`.
fn sliceByChars(str: []const u8, args: []const Value, from: usize) ElzError![]const u8 {
    if (args.len > from + 2) return ElzError.WrongArgumentCount;
    var start: usize = 0;
    var end_opt: ?usize = null;
    if (args.len > from) {
        if (args[from] != .exact_integer or args[from].exact_integer < 0) return ElzError.InvalidArgument;
        start = @intCast(args[from].exact_integer);
    }
    if (args.len > from + 1) {
        if (args[from + 1] != .exact_integer or args[from + 1].exact_integer < 0) return ElzError.InvalidArgument;
        end_opt = @intCast(args[from + 1].exact_integer);
        if (end_opt.? < start) return ElzError.InvalidArgument;
    }

    var byte_start: usize = str.len;
    var byte_end: usize = str.len;
    if (start == 0) byte_start = 0;
    var ci: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (ci == start) byte_start = i;
        if (end_opt) |e| {
            if (ci == e) {
                byte_end = i;
                break;
            }
        }
        const l = std.unicode.utf8ByteSequenceLength(str[i]) catch return ElzError.InvalidArgument;
        i += l;
        ci += 1;
    }
    if (i >= str.len) {
        if (start > ci) return ElzError.InvalidArgument;
        if (end_opt) |e| {
            if (e > ci) return ElzError.InvalidArgument;
        }
    }
    return str[byte_start..byte_end];
}

/// Case-folds a character using the simple Unicode case mapping.
fn foldChar(c: u32) u32 {
    return unicodeDowncase(c);
}

fn isAsciiClass(c: u32, comptime pred: fn (u8) bool) bool {
    if (c >= 128) return false;
    return pred(@intCast(c));
}

/// Chained n-ary character comparison.
fn chainChars(args: core.ValueList, comptime fold: bool, comptime ok: fn (std.math.Order) bool) ElzError!Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;
    for (args.items[0 .. args.items.len - 1], args.items[1..]) |a, b| {
        if (a != .character or b != .character) return ElzError.InvalidArgument;
        const ca = if (fold) foldChar(a.character) else a.character;
        const cb = if (fold) foldChar(b.character) else b.character;
        const o: std.math.Order = if (ca < cb) .lt else if (ca > cb) .gt else .eq;
        if (!ok(o)) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

/// Chained n-ary string comparison.
fn chainStrings(args: core.ValueList, comptime ci: bool, comptime ok: fn (std.math.Order) bool) ElzError!Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;
    for (args.items[0 .. args.items.len - 1], args.items[1..]) |a, b| {
        if (a != .string or b != .string) return ElzError.InvalidArgument;
        const o = if (ci) string_ci_compare(a.string.bytes, b.string.bytes) else std.mem.order(u8, a.string.bytes, b.string.bytes);
        if (!ok(o)) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

fn okEq(o: std.math.Order) bool {
    return o == .eq;
}
fn okLt(o: std.math.Order) bool {
    return o == .lt;
}
fn okGt(o: std.math.Order) bool {
    return o == .gt;
}
fn okLe(o: std.math.Order) bool {
    return o != .gt;
}
fn okGe(o: std.math.Order) bool {
    return o != .lt;
}

pub fn symbol_to_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const sym = args.items[0];
    if (sym != .symbol) return ElzError.InvalidArgument;
    const str = try env.allocator.dupe(u8, sym.symbol);
    return (try core.makeString(env.allocator, str));
}

/// `string_to_symbol` converts a string to a symbol.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single string.
pub fn string_to_symbol(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const str = args.items[0];
    if (str != .string) return ElzError.InvalidArgument;
    const sym = try env.allocator.dupe(u8, str.string.bytes);
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
    const len = std.unicode.utf8CountCodepoints(str.string.bytes) catch return ElzError.InvalidArgument;
    return Value{ .exact_integer = @intCast(len) };
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
            .string => |s| try buffer.appendSlice(env.allocator, s.bytes),
            else => return ElzError.InvalidArgument,
        }
    }

    return (try core.makeString(env.allocator, try buffer.toOwnedSlice(env.allocator)));
}

/// `char_eq` checks if two characters are equal.
///
/// Parameters:
/// - `args`: A `ValueList` containing two characters.
pub fn char_eq(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, false, okEq);
}

/// `char_lt` checks if the first character is less than the second.
pub fn char_lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, false, okLt);
}

/// `char_gt` checks if the first character is greater than the second.
pub fn char_gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, false, okGt);
}

/// `char_le` checks if the first character is less than or equal to the second.
pub fn char_le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, false, okLe);
}

/// `char_ge` checks if the first character is greater than or equal to the second.
pub fn char_ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, false, okGe);
}

pub fn char_ci_eq(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, true, okEq);
}

pub fn char_ci_lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, true, okLt);
}

pub fn char_ci_gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, true, okGt);
}

pub fn char_ci_le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, true, okLe);
}

pub fn char_ci_ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainChars(args, true, okGe);
}

pub fn char_alphabetic_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = isAsciiClass(args.items[0].character, std.ascii.isAlphabetic) };
}

pub fn char_numeric_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = isAsciiClass(args.items[0].character, std.ascii.isDigit) };
}

pub fn char_whitespace_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = isAsciiClass(args.items[0].character, std.ascii.isWhitespace) };
}

pub fn char_upper_case_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = isAsciiClass(args.items[0].character, std.ascii.isUpper) };
}

pub fn char_lower_case_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .character) return ElzError.InvalidArgument;
    return Value{ .boolean = isAsciiClass(args.items[0].character, std.ascii.isLower) };
}

pub fn char_upcase(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .character) return ElzError.InvalidArgument;
    return Value{ .character = unicodeUpcase(args.items[0].character) };
}

pub fn char_downcase(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .character) return ElzError.InvalidArgument;
    return Value{ .character = unicodeDowncase(args.items[0].character) };
}

/// `char_to_integer` converts a character to its Unicode code point.
pub fn char_to_integer(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const c = args.items[0];
    if (c != .character) return ElzError.InvalidArgument;
    return Value{ .exact_integer = @intCast(c.character) };
}

/// `integer_to_char` converts a Unicode code point to a character.
pub fn integer_to_char(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const idx = try toIndex(args.items[0]);
    if (idx > 0x10FFFF) return ElzError.InvalidArgument;
    return Value{ .character = @intCast(idx) };
}

/// `string_ref` returns the character at a given index in a string.
/// Index is 0-based.
///
/// Parameters:
/// - `args`: A `ValueList` containing a string and an index.
pub fn string_ref(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const str = args.items[0];
    if (str != .string) return ElzError.InvalidArgument;
    const idx_usize = try toIndex(args.items[1]);

    // Iterate through UTF-8 codepoints to find the character at the given index
    var it = std.unicode.Utf8View.initUnchecked(str.string.bytes).iterator();
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
    if (str != .string) return ElzError.InvalidArgument;
    const start_idx = try toIndex(args.items[1]);
    const end_idx = try toIndex(args.items[2]);

    if (start_idx > end_idx) return ElzError.InvalidArgument;

    // Handle special case: empty substring from start
    if (start_idx == 0 and end_idx == 0) {
        return (try core.makeString(env.allocator, try env.allocator.dupe(u8, "")));
    }

    // Find byte offsets for the character indices
    var it = std.unicode.Utf8View.initUnchecked(str.string.bytes).iterator();
    var current_idx: usize = 0;
    var start_byte: usize = 0;
    var end_byte: usize = str.string.bytes.len;
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

    const result = try env.allocator.dupe(u8, str.string.bytes[start_byte..end_byte]);
    return (try core.makeString(env.allocator, result));
}

/// `number_to_string` converts a number to its string representation.
/// Syntax: (number->string num) or (number->string num radix)
pub fn number_to_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    const num_val = args.items[0];
    if (!num_val.isNumeric()) return ElzError.InvalidArgument;

    // With an explicit radix, convert integers to that base.
    if (args.items.len == 2) {
        const radix_val = args.items[1];
        const radix_num = try toI64(radix_val);
        if (radix_num < 2 or radix_num > 36) return ElzError.InvalidArgument;
        const radix: u8 = @intCast(radix_num);
        const n = try toI64(num_val);
        var buf: [128]u8 = undefined;
        const len = std.fmt.printInt(&buf, n, radix, .lower, .{});
        return (try core.makeString(env.allocator, try env.allocator.dupe(u8, buf[0..len])));
    }

    // Share the writer's number formatting so `number->string` and `write`
    // agree, in particular on inexact values (`1.0`, `+inf.0`).
    var aw: std.Io.Writer.Allocating = .init(env.allocator);
    defer aw.deinit();
    @import("../writer.zig").write(num_val, &aw.writer) catch return ElzError.OutOfMemory;
    return (try core.makeString(env.allocator, try env.allocator.dupe(u8, aw.written())));
}

/// `string_to_number` converts a string to a number.
/// Syntax: (string->number str) or (string->number str radix)
/// Returns #f if the string cannot be parsed as a number.
pub fn string_to_number(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    const str_val = args.items[0];
    if (str_val != .string) return ElzError.InvalidArgument;

    const str = str_val.string.bytes;
    const parser = @import("../parser.zig");

    if (args.items.len == 2) {
        const radix_num = try toI64(args.items[1]);
        if (radix_num != 2 and radix_num != 8 and radix_num != 10 and radix_num != 16) return ElzError.InvalidArgument;
        if (radix_num != 10) {
            // A radix prefix in the string overrides the argument (R7RS 6.2.7).
            if (str.len >= 2 and str[0] == '#') {
                const v = parser.parseNumber(str, env.allocator) catch return Value{ .boolean = false };
                return v orelse Value{ .boolean = false };
            }
            const radix: u8 = @intCast(radix_num);
            if (std.mem.indexOfScalar(u8, str, '/')) |slash| {
                const n = parser.parseIntegerStrict(str[0..slash], radix) orelse return Value{ .boolean = false };
                const d = parser.parseIntegerStrict(str[slash + 1 ..], radix) orelse return Value{ .boolean = false };
                if (d <= 0) return Value{ .boolean = false };
                return normalizeRationalValue(n, d, env.allocator);
            }
            if (parser.parseIntegerStrict(str, radix)) |n| return Value{ .exact_integer = n };
            return Value{ .boolean = false };
        }
    }

    const v = parser.parseNumber(str, env.allocator) catch return Value{ .boolean = false };
    return v orelse Value{ .boolean = false };
}

fn normalizeRationalValue(n: i64, d: i64, alloc: std.mem.Allocator) Value {
    return @import("math.zig").normalizeRational(n, d, alloc) catch Value{ .boolean = false };
}

/// `string_split` splits a string by a delimiter into a list of strings.
/// Syntax: (string-split str delim)
pub fn string_split(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const str_val = args.items[0];
    const delim_val = args.items[1];

    if (str_val != .string) return ElzError.InvalidArgument;
    if (delim_val != .string) return ElzError.InvalidArgument;

    const str = str_val.string.bytes;
    const delim = delim_val.string.bytes;

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
            .car = (try core.makeString(env.allocator, try env.allocator.dupe(u8, temp_parts.items[i]))),
            .cdr = result,
        };
        result = Value{ .pair = pair };
    }

    return result;
}

/// `string_from_chars` creates a string from one or more characters.
/// Syntax: (string char ...)
pub fn string_from_chars(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(env.allocator);
    for (args.items) |arg| {
        if (arg != .character) return ElzError.InvalidArgument;
        const cp: u21 = @intCast(arg.character);
        if (!std.unicode.utf8ValidCodepoint(cp)) return ElzError.InvalidArgument;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return ElzError.InvalidArgument;
        try bytes.appendSlice(env.allocator, buf[0..len]);
    }
    return (try core.makeString(env.allocator, try bytes.toOwnedSlice(env.allocator)));
}

/// `make_string` creates a string of k characters.
/// Syntax: (make-string k) or (make-string k char)
pub fn make_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;

    const length = try toIndex(args.items[0]);

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

        // Allocate result string (length * char_len bytes).
        const total = std.math.mul(usize, length, char_len) catch return ElzError.OutOfMemory;
        const result = try env.allocator.alloc(u8, total);
        var i: usize = 0;
        while (i < length) : (i += 1) {
            @memcpy(result[i * char_len .. (i + 1) * char_len], char_buf[0..char_len]);
        }
        return (try core.makeString(env.allocator, result));
    } else {
        // Default fill is space
        const result = try env.allocator.alloc(u8, length);
        @memset(result, ' ');
        return (try core.makeString(env.allocator, result));
    }
}

/// `string_eq` checks if two strings are equal.
/// Syntax: (string=? str1 str2)
pub fn string_eq(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, false, okEq);
}

/// `string_lt` checks if the first string is lexicographically less than the second.
/// Syntax: (string<? str1 str2)
pub fn string_lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, false, okLt);
}

/// `string_gt` checks if the first string is lexicographically greater than the second.
/// Syntax: (string>? str1 str2)
pub fn string_gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, false, okGt);
}

/// `string_le` checks if the first string is lexicographically less than or equal to the second.
/// Syntax: (string<=? str1 str2)
pub fn string_le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, false, okLe);
}

/// `string_ge` checks if the first string is lexicographically greater than or equal to the second.
/// Syntax: (string>=? str1 str2)
pub fn string_ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, false, okGe);
}

fn string_ci_compare(a: []const u8, b: []const u8) std.math.Order {
    var ia = std.unicode.Utf8View.initUnchecked(a).iterator();
    var ib = std.unicode.Utf8View.initUnchecked(b).iterator();
    while (true) {
        const ca = ia.nextCodepoint();
        const cb = ib.nextCodepoint();
        if (ca == null and cb == null) return .eq;
        if (ca == null) return .lt;
        if (cb == null) return .gt;
        const la: u32 = foldChar(ca.?);
        const lb: u32 = foldChar(cb.?);
        if (la < lb) return .lt;
        if (la > lb) return .gt;
    }
}

pub fn string_ci_eq(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, true, okEq);
}

pub fn string_ci_lt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, true, okLt);
}

pub fn string_ci_le(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, true, okLe);
}

pub fn string_ci_gt(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, true, okGt);
}

pub fn string_ci_ge(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    return chainStrings(args, true, okGe);
}

pub fn string_copy(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    const slice = try sliceByChars(args.items[0].string.bytes, args.items, 1);
    return (try core.makeString(env.allocator, try env.allocator.dupe(u8, slice)));
}

pub fn string_to_list(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    const slice = try sliceByChars(args.items[0].string.bytes, args.items, 1);
    var it = std.unicode.Utf8View.initUnchecked(slice).iterator();
    var result: Value = .nil;
    var chars = std.ArrayListUnmanaged(u21).empty;
    defer chars.deinit(env.allocator);
    while (it.nextCodepoint()) |cp| {
        try chars.append(env.allocator, cp);
    }
    var i: usize = chars.items.len;
    while (i > 0) {
        i -= 1;
        const pair = try env.allocator.create(core.Pair);
        pair.* = .{ .car = Value{ .character = chars.items[i] }, .cdr = result };
        result = Value{ .pair = pair };
    }
    return result;
}

pub fn list_to_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(env.allocator);
    var node = args.items[0];
    while (node == .pair) {
        const c = node.pair.car;
        if (c != .character) return ElzError.InvalidArgument;
        const cp: u21 = @intCast(c.character);
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return ElzError.InvalidArgument;
        try bytes.appendSlice(env.allocator, buf[0..len]);
        node = node.pair.cdr;
    }
    if (node != .nil) return ElzError.InvalidArgument;
    return (try core.makeString(env.allocator, try bytes.toOwnedSlice(env.allocator)));
}

pub fn string_set_bang(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    if (args.items[2] != .character) return ElzError.InvalidArgument;
    const str = args.items[0].string;
    const s = str.bytes;
    const idx = try toIndex(args.items[1]);
    if (args.items[2].character > 0x10FFFF) return ElzError.InvalidArgument;
    const cp_new: u21 = @intCast(args.items[2].character);
    var buf_new: [4]u8 = undefined;
    const len_new = std.unicode.utf8Encode(cp_new, &buf_new) catch return ElzError.InvalidArgument;
    // Find the byte range of the codepoint at idx.
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var cur: usize = 0;
    var byte_start: usize = 0;
    var byte_end: usize = 0;
    var found = false;
    while (it.nextCodepointSlice()) |slice| {
        if (cur == idx) {
            byte_end = byte_start + slice.len;
            found = true;
            break;
        }
        byte_start += slice.len;
        cur += 1;
    }
    if (!found) return ElzError.InvalidArgument;
    if (len_new == byte_end - byte_start) {
        @memcpy(s[byte_start..byte_end], buf_new[0..len_new]);
        return Value.unspecified;
    }
    // The encoded width changed: rebuild the buffer. Every alias shares the
    // string object, so they all observe the new contents.
    const new_len = s.len - (byte_end - byte_start) + len_new;
    const rebuilt = env.allocator.alloc(u8, new_len) catch return ElzError.OutOfMemory;
    @memcpy(rebuilt[0..byte_start], s[0..byte_start]);
    @memcpy(rebuilt[byte_start .. byte_start + len_new], buf_new[0..len_new]);
    @memcpy(rebuilt[byte_start + len_new ..], s[byte_end..]);
    str.bytes = rebuilt;
    return Value.unspecified;
}

pub fn string_fill_bang(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    if (args.items[1] != .character) return ElzError.InvalidArgument;
    const str = args.items[0].string;
    const s = str.bytes;
    if (args.items[1].character > 0x10FFFF) return ElzError.InvalidArgument;
    const cp: u21 = @intCast(args.items[1].character);
    var buf: [4]u8 = undefined;
    const char_len = std.unicode.utf8Encode(cp, &buf) catch return ElzError.InvalidArgument;
    const slice = try sliceByChars(s, args.items, 2);
    const start = @intFromPtr(slice.ptr) - @intFromPtr(s.ptr);
    const end = start + slice.len;
    const count = std.unicode.utf8CountCodepoints(slice) catch return ElzError.InvalidArgument;
    // Rebuild: prefix, `count` copies of the fill character, suffix.
    const new_len = start + count * char_len + (s.len - end);
    const rebuilt = env.allocator.alloc(u8, new_len) catch return ElzError.OutOfMemory;
    @memcpy(rebuilt[0..start], s[0..start]);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(rebuilt[start + i * char_len .. start + (i + 1) * char_len], buf[0..char_len]);
    }
    @memcpy(rebuilt[start + count * char_len ..], s[end..]);
    str.bytes = rebuilt;
    return Value.unspecified;
}

/// `gensym` generates a unique symbol.
/// Syntax: (gensym) or (gensym prefix)
pub fn gensym(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const prefix = if (args.items.len >= 1) blk: {
        const p = args.items[0];
        if (p != .string and p != .symbol) return ElzError.InvalidArgument;
        break :blk if (p == .string) p.string.bytes else p.symbol;
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
    try args.append(Value{ .symbol = "foo" });
    var result = try symbol_to_string(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == .string and std.mem.eql(u8, result.string.bytes, "foo"));

    // Test string->symbol
    args.clearRetainingCapacity();
    try args.append((try core.makeString(interp.allocator, "bar")));
    result = try string_to_symbol(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == .symbol and std.mem.eql(u8, result.symbol, "bar"));

    // Test string-length
    args.clearRetainingCapacity();
    try args.append((try core.makeString(interp.allocator, "hello")));
    result = try string_length(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == .exact_integer and result.exact_integer == 5);

    // Test char=?
    args.clearRetainingCapacity();
    try args.append(Value{ .character = 'a' });
    try args.append(Value{ .character = 'a' });
    result = try char_eq(&interp, interp.root_env, args, &fuel);
    try testing.expect(result == .boolean and result.boolean == true);
}

test "toI64 and toIndex reject values outside range without panicking" {
    const testing = std.testing;
    const huge_f = 9223372036854775808.0; // 2^63
    const out_of_usize = 18446744073709551616.0; // 2^64
    try testing.expectError(ElzError.InvalidArgument, toI64(Value{ .number = huge_f }));
    try testing.expectError(ElzError.InvalidArgument, toIndex(Value{ .number = out_of_usize }));
    try testing.expectError(ElzError.InvalidArgument, toI64(Value{ .number = 1.5 }));
}
