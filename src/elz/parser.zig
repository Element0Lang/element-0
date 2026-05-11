//! This module is responsible for parsing Element 0 source code.
//! It includes a tokenizer and a parser that builds an abstract syntax tree (AST).

const std = @import("std");
const core = @import("core.zig");
const Value = core.Value;
const ElzError = @import("errors.zig").ElzError;

/// Tokenizes a string of Element 0 source code.
/// This function breaks the source code into a sequence of tokens, such as
/// parentheses, symbols, and literals. It also handles comments.
///
/// Parameters:
/// - `source`: The source code to tokenize.
/// - `allocator`: The memory allocator to use for the token list.
///
/// Returns:
/// An `ArrayList` of tokens, or an error if tokenization fails.
fn tokenize(source: []const u8, allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    var tokens = std.ArrayListUnmanaged([]const u8).empty;
    errdefer tokens.deinit(allocator);
    var i: usize = 0;
    while (i < source.len) {
        const char = source[i];
        switch (char) {
            ';' => { // Handle comments
                while (i < source.len and source[i] != '\n') {
                    i += 1;
                }
            },
            ' ', '\t', '\r', '\n' => i += 1,
            '(', ')', '\'', '`' => {
                try tokens.append(allocator, source[i .. i + 1]);
                i += 1;
            },
            ',' => {
                if (i + 1 < source.len and source[i + 1] == '@') {
                    try tokens.append(allocator, source[i .. i + 2]);
                    i += 2;
                } else {
                    try tokens.append(allocator, source[i .. i + 1]);
                    i += 1;
                }
            },
            '"' => {
                var j = i + 1;
                while (j < source.len and source[j] != '"') {
                    if (source[j] == '\\' and j + 1 < source.len) {
                        j += 2;
                    } else {
                        j += 1;
                    }
                }
                if (j >= source.len) return ElzError.UnterminatedString;
                try tokens.append(allocator, source[i .. j + 1]);
                i = j + 1;
            },
            else => {
                var j = i;
                while (j < source.len) {
                    const c = source[j];
                    if (std.ascii.isWhitespace(c)) break;
                    if (c == '(' or c == ')' or c == '\'' or c == '`' or c == ',' or c == ';' or c == '"') break;
                    j += 1;
                }
                try tokens.append(allocator, source[i..j]);
                i = j;
            },
        }
    }
    return tokens;
}

/// The parser for Element 0 source code.
/// It holds the state of the parsing process.
const Parser = struct {
    tokens: std.ArrayList([]const u8),
    position: usize,
    allocator: std.mem.Allocator,

    /// Parses a single form from the token stream.
    ///
    /// - `self`: A pointer to the parser.
    /// - `return`: The parsed `Value`.
    fn parse_form(self: *Parser) ElzError!Value {
        if (self.position >= self.tokens.items.len) return ElzError.UnexpectedEndOfInput;
        const token = self.tokens.items[self.position];
        self.position += 1;
        // Quote and quasiquote-family shorthand: each wraps the next form in a one-arg
        // application of the corresponding special form.
        const wrapper_name: ?[]const u8 = if (std.mem.eql(u8, token, "'"))
            "quote"
        else if (std.mem.eql(u8, token, "`"))
            "quasiquote"
        else if (std.mem.eql(u8, token, ","))
            "unquote"
        else if (std.mem.eql(u8, token, ",@"))
            "unquote-splicing"
        else
            null;
        if (wrapper_name) |name| {
            const next_form = try self.parse_form();
            const sym = Value{ .symbol = name };
            const p1 = try self.allocator.create(core.Pair);
            p1.* = .{ .car = next_form, .cdr = Value.nil };
            const p2 = try self.allocator.create(core.Pair);
            p2.* = .{ .car = sym, .cdr = Value{ .pair = p1 } };
            return Value{ .pair = p2 };
        }
        if (std.mem.eql(u8, token, "(")) {
            var values = std.ArrayListUnmanaged(Value).empty;
            defer values.deinit(self.allocator);
            while (true) {
                if (self.position >= self.tokens.items.len) {
                    return ElzError.UnmatchedOpenParen;
                }
                const next_token = self.tokens.items[self.position];
                if (std.mem.eql(u8, next_token, ")")) {
                    self.position += 1;
                    var result: Value = Value.nil;
                    var j = values.items.len;
                    while (j > 0) {
                        j -= 1;
                        const p = try self.allocator.create(core.Pair);
                        p.* = .{ .car = values.items[j], .cdr = result };
                        result = Value{ .pair = p };
                    }
                    return result;
                }
                if (std.mem.eql(u8, next_token, ".")) {
                    self.position += 1;
                    if (values.items.len == 0) return ElzError.InvalidDottedPair;
                    const cdr = try self.parse_form();
                    if (self.position >= self.tokens.items.len or !std.mem.eql(u8, self.tokens.items[self.position], ")")) {
                        return ElzError.InvalidDottedPair;
                    }
                    self.position += 1;
                    var result: Value = cdr;
                    var k = values.items.len;
                    while (k > 0) {
                        k -= 1;
                        const p = try self.allocator.create(core.Pair);
                        p.* = .{ .car = values.items[k], .cdr = result };
                        result = Value{ .pair = p };
                    }
                    return result;
                }
                try values.append(self.allocator, try self.parse_form());
            }
        } else if (std.mem.eql(u8, token, ")")) {
            return ElzError.UnexpectedCloseParen;
        } else {
            return parse_atom(token, self.allocator);
        }
    }
};

/// Parses an atomic value from a token.
///
/// - `token`: The token to parse.
/// - `allocator`: The memory allocator to use.
/// - `return`: The parsed `Value`.
fn parse_atom(token: []const u8, allocator: std.mem.Allocator) ElzError!Value {
    if (std.mem.eql(u8, token, "#t")) return Value{ .boolean = true };
    if (std.mem.eql(u8, token, "#f")) return Value{ .boolean = false };
    if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
        var unescaped = std.ArrayListUnmanaged(u8).empty;
        defer unescaped.deinit(allocator);
        var i: usize = 1;
        while (i < token.len - 1) {
            if (token[i] == '\\' and i + 1 < token.len - 1) {
                switch (token[i + 1]) {
                    'n' => try unescaped.append(allocator, '\n'),
                    't' => try unescaped.append(allocator, '\t'),
                    '\\' => try unescaped.append(allocator, '\\'),
                    '"' => try unescaped.append(allocator, '"'),
                    else => {
                        try unescaped.append(allocator, '\\');
                        try unescaped.append(allocator, token[i + 1]);
                    },
                }
                i += 2;
            } else {
                try unescaped.append(allocator, token[i]);
                i += 1;
            }
        }
        return Value{ .string = try unescaped.toOwnedSlice(allocator) };
    }
    if (token.len > 2 and token[0] == '#' and token[1] == '\\') {
        const char_name = token[2..];
        if (std.mem.eql(u8, char_name, "space")) return Value{ .character = ' ' };
        if (std.mem.eql(u8, char_name, "newline")) return Value{ .character = '\n' };
        if (std.mem.eql(u8, char_name, "tab")) return Value{ .character = '\t' };
        if (std.mem.eql(u8, char_name, "return")) return Value{ .character = '\r' };
        if (char_name.len == 1) return Value{ .character = char_name[0] };
        return ElzError.InvalidCharacterLiteral;
    }
    // Handle exactness prefix: #e (exact) or #i (inexact)
    var rest = token;
    var force_exact: ?bool = null;
    if (token.len >= 2 and token[0] == '#') {
        switch (token[1]) {
            'e', 'E' => { force_exact = true; rest = token[2..]; },
            'i', 'I' => { force_exact = false; rest = token[2..]; },
            else => {},
        }
    }

    // Try rational literal p/q
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const num_str = rest[0..slash];
        const den_str = rest[slash + 1 ..];
        const numer = std.fmt.parseInt(i64, num_str, 10) catch null;
        const denom = std.fmt.parseInt(i64, den_str, 10) catch null;
        if (numer != null and denom != null and denom.? != 0) {
            const rational_val = try core.normalizeRational(numer.?, denom.?, allocator);
            if (force_exact == false) {
                const f = switch (rational_val) {
                    .exact_integer => |n| @as(f64, @floatFromInt(n)),
                    .rational => |r| r.toFloat(),
                    else => unreachable,
                };
                return Value{ .number = f };
            }
            return rational_val;
        }
    }

    // Try integer (no decimal point, no exponent)
    const is_int = blk: {
        var s = rest;
        if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s = s[1..];
        if (s.len == 0) break :blk false;
        for (s) |c| {
            if (c < '0' or c > '9') break :blk false;
        }
        break :blk true;
    };
    if (is_int) {
        const n = std.fmt.parseInt(i64, rest, 10) catch null;
        if (n != null) {
            if (force_exact == false) return Value{ .number = @floatFromInt(n.?) };
            return Value{ .exact_integer = n.? };
        }
    }

    const num = std.fmt.parseFloat(f64, rest) catch {
        if (force_exact != null) return ElzError.InvalidArgument;
        return Value{ .symbol = try allocator.dupe(u8, token) };
    };
    if (force_exact == true) {
        const as_int = @as(i64, @intFromFloat(num));
        if (@as(f64, @floatFromInt(as_int)) == num) return Value{ .exact_integer = as_int };
        return ElzError.InvalidArgument;
    }
    return Value{ .number = num };
}

/// Reads and parses a single form from a string of source code.
/// This function is useful for parsing a single expression, such as in a REPL.
///
/// Parameters:
/// - `source`: The string of source code to parse.
/// - `allocator`: The memory allocator to use for creating new `Value`s and the token list.
///
/// Returns:
/// The parsed `Value`, or an error if parsing fails (e.g., `ElzError.UnterminatedString`, `ElzError.UnexpectedCloseParen`).
pub fn read(source: []const u8, allocator: std.mem.Allocator) ElzError!Value {
    var tokens = tokenize(source, allocator) catch |err| {
        return err;
    };
    defer tokens.deinit(allocator);
    if (tokens.items.len == 0) return ElzError.EmptyInput;
    var parser = Parser{
        .tokens = tokens,
        .position = 0,
        .allocator = allocator,
    };
    return parser.parse_form();
}

/// Reads and parses all forms from a string of source code.
/// This function is useful for parsing a whole file or a block of code.
///
/// Parameters:
/// - `source`: The string of source code to parse.
/// - `allocator`: The memory allocator to use for creating new `Value`s and other allocations.
///
/// Returns:
/// An `ArrayList` of parsed `Value`s, or an error if parsing fails.
pub fn readAll(source: []const u8, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(Value) {
    var tokens = tokenize(source, allocator) catch |err| {
        return err;
    };
    defer tokens.deinit(allocator);
    if (tokens.items.len == 0) return .empty;

    var parser = Parser{
        .tokens = tokens,
        .position = 0,
        .allocator = allocator,
    };

    var forms = std.ArrayListUnmanaged(Value).empty;
    while (parser.position < parser.tokens.items.len) {
        try forms.append(allocator, try parser.parse_form());
    }
    return forms;
}

test "parser" {
    // The parser allocates symbol, string, and pair values from the supplied allocator
    // and never owns their lifetime in production (the GC does). An arena lets the test
    // free everything in one shot.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing = std.testing;

    // Test parsing a number
    var value = try read("42", allocator);
    try testing.expect(value == .exact_integer);
    try testing.expectEqual(@as(i64, 42), value.exact_integer);

    // Test parsing a symbol
    value = try read("foo", allocator);
    try testing.expect(value.is_symbol("foo"));

    // Test parsing a string
    value = try read("\"hello world\"", allocator);
    try testing.expect(value == .string);
    try testing.expectEqualStrings("hello world", value.string);

    // Test parsing a list
    value = try read("(+ 1 2)", allocator);
    if (value != .pair) return error.TestExpectedPair;
    var p = value.pair;
    try testing.expect(p.car.is_symbol("+"));
    p = p.cdr.pair;
    try testing.expect(p.car == .exact_integer and p.car.exact_integer == 1);
    p = p.cdr.pair;
    try testing.expect(p.car == .exact_integer and p.car.exact_integer == 2);
    try testing.expect(p.cdr == .nil);

    // Test parsing a quoted expression
    value = try read("'(1 2)", allocator);
    if (value != .pair) return error.TestExpectedPair;
    p = value.pair;
    try testing.expect(p.car.is_symbol("quote"));
    p = p.cdr.pair;
    const inner_list = p.car;
    if (inner_list != .pair) return error.TestExpectedPair;
    p = inner_list.pair;
    try testing.expect(p.car == .exact_integer and p.car.exact_integer == 1);
    p = p.cdr.pair;
    try testing.expect(p.car == .exact_integer and p.car.exact_integer == 2);
    try testing.expect(p.cdr == .nil);

    // Test unterminated string error
    var err = read("\"hello", allocator);
    try testing.expectError(ElzError.UnterminatedString, err);

    // Test unmatched open paren error
    err = read("(", allocator);
    try testing.expectError(ElzError.UnmatchedOpenParen, err);

    // Test unexpected close paren error
    err = read(")", allocator);
    try testing.expectError(ElzError.UnexpectedCloseParen, err);
}
