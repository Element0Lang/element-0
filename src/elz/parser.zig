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
            '|' => {
                // Pipe-delimited symbol: |name with spaces| with \-escapes.
                var j = i + 1;
                while (j < source.len and source[j] != '|') {
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
                // #( is the vector literal prefix — emit it as a two-character token.
                // #u8( is the bytevector literal prefix — emit it as a four-character token.
                if (char == '#' and i + 1 < source.len and source[i + 1] == '|') {
                    // Block comment, nestable: #| ... |#
                    var nesting: usize = 1;
                    var j = i + 2;
                    while (j + 1 < source.len and nesting > 0) {
                        if (source[j] == '#' and source[j + 1] == '|') {
                            nesting += 1;
                            j += 2;
                        } else if (source[j] == '|' and source[j + 1] == '#') {
                            nesting -= 1;
                            j += 2;
                        } else {
                            j += 1;
                        }
                    }
                    if (nesting > 0) return ElzError.UnexpectedEndOfInput;
                    i = j;
                } else if (char == '#' and i + 1 < source.len and source[i + 1] == ';') {
                    // Datum comment: the parser discards the following form.
                    try tokens.append(allocator, source[i .. i + 2]);
                    i += 2;
                } else if (char == '#' and i + 1 < source.len and source[i + 1] == '\\') {
                    // Character literal: always take one character after the
                    // backslash (it may be a delimiter), then any name tail.
                    var j = i + 2;
                    if (j < source.len) {
                        const seq_len = std.unicode.utf8ByteSequenceLength(source[j]) catch 1;
                        j += seq_len;
                    }
                    while (j < source.len and (std.ascii.isAlphanumeric(source[j]) or source[j] == '-')) {
                        j += 1;
                    }
                    try tokens.append(allocator, source[i..j]);
                    i = j;
                } else if (char == '#' and i + 3 < source.len and std.mem.eql(u8, source[i .. i + 4], "#u8(")) {
                    try tokens.append(allocator, source[i .. i + 4]);
                    i += 4;
                } else if (char == '#' and i + 1 < source.len and source[i + 1] == '(') {
                    try tokens.append(allocator, source[i .. i + 2]);
                    i += 2;
                } else {
                    var j = i;
                    while (j < source.len) {
                        const c = source[j];
                        if (std.ascii.isWhitespace(c)) break;
                        if (c == '(' or c == ')' or c == '\'' or c == '`' or c == ',' or c == ';' or c == '"') break;
                        j += 1;
                    }
                    try tokens.append(allocator, source[i..j]);
                    i = j;
                }
            },
        }
    }
    return tokens;
}

/// The parser for Element 0 source code.
/// It holds the state of the parsing process.
/// A source location attached to a parsed form.
pub const SourceLoc = struct {
    file: []const u8,
    line: u32,
};

/// Maps a Pair pointer (as usize) to the source location of its opening paren.
pub const FormLocations = std.AutoHashMapUnmanaged(usize, SourceLoc);

/// Deepest datum nesting the reader accepts. Each level costs a native stack
/// frame, so hostile input must be bounded.
const MAX_PARSE_DEPTH: usize = 2048;

const Parser = struct {
    tokens: std.ArrayList([]const u8),
    position: usize,
    allocator: std.mem.Allocator,
    depth: usize = 0,
    /// Set when tracking locations: the original source and its file name.
    source: []const u8 = "",
    file: []const u8 = "",
    locations: ?*FormLocations = null,

    /// The 1-based line number of a token (a slice into `source`).
    fn lineOf(self: *const Parser, token: []const u8) u32 {
        const off = @intFromPtr(token.ptr) - @intFromPtr(self.source.ptr);
        var line: u32 = 1;
        for (self.source[0..off]) |c| {
            if (c == '\n') line += 1;
        }
        return line;
    }

    fn recordLocation(self: *Parser, form: Value, token: []const u8) void {
        const locs = self.locations orelse return;
        if (form != .pair) return;
        if (@intFromPtr(token.ptr) < @intFromPtr(self.source.ptr)) return;
        locs.put(self.allocator, @intFromPtr(form.pair), .{
            .file = self.file,
            .line = self.lineOf(token),
        }) catch {};
    }

    /// Parses a single form from the token stream.
    ///
    /// - `self`: A pointer to the parser.
    /// - `return`: The parsed `Value`.
    fn parse_form(self: *Parser) ElzError!Value {
        if (self.depth >= MAX_PARSE_DEPTH) return ElzError.UnexpectedEndOfInput;
        self.depth += 1;
        defer self.depth -= 1;
        if (self.position >= self.tokens.items.len) return ElzError.UnexpectedEndOfInput;
        const token = self.tokens.items[self.position];
        self.position += 1;
        if (std.mem.eql(u8, token, "#;")) {
            // Datum comment: discard the next form, return the one after it.
            _ = try self.parse_form();
            return self.parse_form();
        }
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
        if (std.mem.eql(u8, token, "#u8(")) {
            var bytes = std.ArrayListUnmanaged(u8).empty;
            defer bytes.deinit(self.allocator);
            while (true) {
                if (self.position >= self.tokens.items.len) return ElzError.UnmatchedOpenParen;
                const next = self.tokens.items[self.position];
                if (std.mem.eql(u8, next, "#;")) {
                    self.position += 1;
                    _ = try self.parse_form();
                    continue;
                }
                if (std.mem.eql(u8, next, ")")) {
                    self.position += 1;
                    break;
                }
                const elem = try self.parse_form();
                if (elem != .exact_integer or elem.exact_integer < 0 or elem.exact_integer > 255) {
                    return ElzError.InvalidArgument;
                }
                try bytes.append(self.allocator, @intCast(elem.exact_integer));
            }
            const bv = try self.allocator.create(core.Bytevector);
            bv.* = core.Bytevector{ .items = try bytes.toOwnedSlice(self.allocator) };
            return Value{ .bytevector = bv };
        }
        if (std.mem.eql(u8, token, "#(")) {
            var items = std.ArrayListUnmanaged(Value).empty;
            defer items.deinit(self.allocator);
            while (true) {
                if (self.position >= self.tokens.items.len) return ElzError.UnmatchedOpenParen;
                const next = self.tokens.items[self.position];
                if (std.mem.eql(u8, next, "#;")) {
                    self.position += 1;
                    _ = try self.parse_form();
                    continue;
                }
                if (std.mem.eql(u8, next, ")")) {
                    self.position += 1;
                    break;
                }
                try items.append(self.allocator, try self.parse_form());
            }
            const vec = try self.allocator.create(core.Vector);
            vec.* = core.Vector{ .items = try items.toOwnedSlice(self.allocator) };
            return Value{ .vector = vec };
        }
        if (std.mem.eql(u8, token, "(")) {
            const open_token = token;
            var values = std.ArrayListUnmanaged(Value).empty;
            defer values.deinit(self.allocator);
            while (true) {
                if (self.position >= self.tokens.items.len) {
                    return ElzError.UnmatchedOpenParen;
                }
                const next_token = self.tokens.items[self.position];
                if (std.mem.eql(u8, next_token, "#;")) {
                    self.position += 1;
                    _ = try self.parse_form();
                    continue;
                }
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
                    self.recordLocation(result, open_token);
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

/// Parses the real-number part of a complex literal: decimal, inf, or nan.
fn parseRealText(text: []const u8) ?f64 {
    return parseReal(text);
}

/// Parses a rectangular complex literal (ending in i). An exact-zero
/// imaginary part ("+0i") yields the real part alone, per R7RS typing.
fn parseComplex(text: []const u8, allocator: std.mem.Allocator) ElzError!Value {
    const body = text[0 .. text.len - 1];
    // Split at the sign of the imaginary part: the last +/- not at position 0
    // and not part of an exponent or inf/nan spelling.
    var split: ?usize = null;
    var i = body.len;
    while (i > 1) {
        i -= 1;
        const c = body[i];
        if (c == '+' or c == '-') {
            const prev = body[i - 1];
            if (prev == 'e' or prev == 'E') continue;
            // "inf.0" / "nan.0" contain no signs, so any other +/- splits.
            if (std.mem.endsWith(u8, body[0..i], "inf.") or std.mem.endsWith(u8, body[0..i], "nan.")) continue;
            split = i;
            break;
        }
    }
    var real_text: []const u8 = "";
    var imag_text: []const u8 = body;
    if (split) |at| {
        real_text = body[0..at];
        imag_text = body[at..];
    }
    if (imag_text.len == 0) return ElzError.InvalidArgument;
    if (imag_text[0] != '+' and imag_text[0] != '-') {
        // No sign on the imaginary part means this is not a complex literal.
        return ElzError.InvalidArgument;
    }
    // An exact-zero imaginary part makes the value real.
    if (std.mem.eql(u8, imag_text, "+0") or std.mem.eql(u8, imag_text, "-0")) {
        if (real_text.len == 0) return Value{ .exact_integer = 0 };
        return (try parseNumber(real_text, allocator)) orelse ElzError.InvalidArgument;
    }
    const imag: f64 = if (imag_text.len == 1)
        (if (imag_text[0] == '+') @as(f64, 1) else @as(f64, -1))
    else
        parseRealText(imag_text) orelse return ElzError.InvalidArgument;
    const real: f64 = if (real_text.len == 0)
        0
    else
        parseRealText(real_text) orelse return ElzError.InvalidArgument;
    const c = allocator.create(core.Complex) catch return ElzError.OutOfMemory;
    c.* = .{ .real = real, .imag = imag };
    return Value{ .complex = c };
}

/// Parses an atomic value from a token.
///
/// - `token`: The token to parse.
/// - `allocator`: The memory allocator to use.
/// - `return`: The parsed `Value`.
fn parse_atom(token: []const u8, allocator: std.mem.Allocator) ElzError!Value {
    if (std.mem.eql(u8, token, "#t") or std.mem.eql(u8, token, "#true")) return Value{ .boolean = true };
    if (std.mem.eql(u8, token, "#f") or std.mem.eql(u8, token, "#false")) return Value{ .boolean = false };
    if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
        var unescaped = std.ArrayListUnmanaged(u8).empty;
        defer unescaped.deinit(allocator);
        var i: usize = 1;
        while (i < token.len - 1) {
            if (token[i] == '\\' and i + 1 < token.len - 1) {
                switch (token[i + 1]) {
                    'n' => try unescaped.append(allocator, '\n'),
                    't' => try unescaped.append(allocator, '\t'),
                    'r' => try unescaped.append(allocator, '\r'),
                    'a' => try unescaped.append(allocator, 7),
                    'b' => try unescaped.append(allocator, 8),
                    '0' => try unescaped.append(allocator, 0),
                    '\\' => try unescaped.append(allocator, '\\'),
                    '"' => try unescaped.append(allocator, '"'),
                    'x', 'X' => {
                        // \xHH...; hex escape, terminated by a semicolon.
                        const semi = std.mem.indexOfScalarPos(u8, token, i + 2, ';') orelse return ElzError.UnterminatedString;
                        const cp = std.fmt.parseInt(u21, token[i + 2 .. semi], 16) catch return ElzError.UnterminatedString;
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return ElzError.UnterminatedString;
                        try unescaped.appendSlice(allocator, buf[0..len]);
                        i = semi + 1;
                        continue;
                    },
                    ' ', '\t', '\n', '\r' => {
                        // Line continuation: backslash, optional intraline
                        // whitespace, a line ending, then leading whitespace
                        // of the next line, all dropped (R7RS 6.7).
                        var j = i + 1;
                        while (j < token.len - 1 and (token[j] == ' ' or token[j] == '\t')) j += 1;
                        if (j < token.len - 1 and (token[j] == '\n' or token[j] == '\r')) {
                            if (token[j] == '\r' and j + 1 < token.len - 1 and token[j + 1] == '\n') j += 1;
                            j += 1;
                            while (j < token.len - 1 and (token[j] == ' ' or token[j] == '\t')) j += 1;
                            i = j;
                            continue;
                        }
                        return ElzError.UnterminatedString;
                    },
                    else => return ElzError.UnterminatedString,
                }
                i += 2;
            } else {
                try unescaped.append(allocator, token[i]);
                i += 1;
            }
        }
        return (try core.makeString(allocator, try unescaped.toOwnedSlice(allocator)));
    }
    if (token.len >= 2 and token[0] == '|' and token[token.len - 1] == '|') {
        var name = std.ArrayListUnmanaged(u8).empty;
        defer name.deinit(allocator);
        var i: usize = 1;
        while (i < token.len - 1) {
            if (token[i] == '\\' and i + 1 < token.len - 1) {
                switch (token[i + 1]) {
                    'n' => try name.append(allocator, '\n'),
                    't' => try name.append(allocator, '\t'),
                    'x', 'X' => {
                        const semi = std.mem.indexOfScalarPos(u8, token, i + 2, ';') orelse return ElzError.InvalidArgument;
                        const cp = std.fmt.parseInt(u21, token[i + 2 .. semi], 16) catch return ElzError.InvalidArgument;
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return ElzError.InvalidArgument;
                        try name.appendSlice(allocator, buf[0..len]);
                        i = semi + 1;
                        continue;
                    },
                    else => try name.append(allocator, token[i + 1]),
                }
                i += 2;
            } else {
                try name.append(allocator, token[i]);
                i += 1;
            }
        }
        return Value{ .symbol = try name.toOwnedSlice(allocator) };
    }
    if (token.len > 2 and token[0] == '#' and token[1] == '\\') {
        const char_name = token[2..];
        if (std.mem.eql(u8, char_name, "space")) return Value{ .character = ' ' };
        if (std.mem.eql(u8, char_name, "newline")) return Value{ .character = '\n' };
        if (std.mem.eql(u8, char_name, "tab")) return Value{ .character = '\t' };
        if (std.mem.eql(u8, char_name, "return")) return Value{ .character = '\r' };
        if (std.mem.eql(u8, char_name, "alarm")) return Value{ .character = 7 };
        if (std.mem.eql(u8, char_name, "backspace")) return Value{ .character = 8 };
        if (std.mem.eql(u8, char_name, "delete")) return Value{ .character = 127 };
        if (std.mem.eql(u8, char_name, "escape")) return Value{ .character = 27 };
        if (std.mem.eql(u8, char_name, "null")) return Value{ .character = 0 };
        if (char_name.len == 1) return Value{ .character = char_name[0] };
        // #\xHH... hex code point.
        if ((char_name[0] == 'x' or char_name[0] == 'X') and char_name.len > 1) {
            const cp = std.fmt.parseInt(u32, char_name[1..], 16) catch return ElzError.InvalidCharacterLiteral;
            if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return ElzError.InvalidCharacterLiteral;
            return Value{ .character = cp };
        }
        // A single non-ASCII UTF-8 character.
        const seq_len = std.unicode.utf8ByteSequenceLength(char_name[0]) catch return ElzError.InvalidCharacterLiteral;
        if (char_name.len == seq_len) {
            const cp = std.unicode.utf8Decode(char_name) catch return ElzError.InvalidCharacterLiteral;
            return Value{ .character = cp };
        }
        return ElzError.InvalidCharacterLiteral;
    }
    if (try parseNumber(token, allocator)) |num| return num;
    return Value{ .symbol = try allocator.dupe(u8, token) };
}

/// Validates the strict decimal syntax `[+-]? (digits [. digits*] | . digits) ([eE] [+-]? digits)?`.
/// `std.fmt.parseFloat` alone also accepts `inf`, `nan`, hex floats, and
/// digit separators, none of which are Scheme numbers.
fn isDecimalSyntax(text: []const u8) bool {
    var i: usize = 0;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    var int_digits: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) int_digits += 1;
    var frac_digits: usize = 0;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) frac_digits += 1;
    }
    if (int_digits == 0 and frac_digits == 0) return false;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false;
    }
    return i == text.len;
}

/// Parses a decimal real, including the inf/nan spellings. Returns null when
/// `text` is not a real number.
pub fn parseReal(text: []const u8) ?f64 {
    if (std.mem.eql(u8, text, "+inf.0")) return std.math.inf(f64);
    if (std.mem.eql(u8, text, "-inf.0")) return -std.math.inf(f64);
    if (std.mem.eql(u8, text, "+nan.0") or std.mem.eql(u8, text, "-nan.0")) return std.math.nan(f64);
    if (!isDecimalSyntax(text)) return null;
    return std.fmt.parseFloat(f64, text) catch null;
}

/// Parses an integer in `radix` with an optional sign. Digit separators are
/// rejected. Returns null when `text` is not such an integer.
pub fn parseIntegerStrict(text: []const u8, radix: u8) ?i64 {
    var i: usize = 0;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    if (i >= text.len) return null;
    for (text[i..]) |c| {
        const d = std.fmt.charToDigit(c, radix) catch return null;
        _ = d;
    }
    return std.fmt.parseInt(i64, text, radix) catch null;
}

/// Converts a decimal literal to an exact rational, for the `#e` prefix.
fn exactFromDecimal(text: []const u8, allocator: std.mem.Allocator) ElzError!Value {
    var i: usize = 0;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    var mantissa: i128 = 0;
    var scale: i32 = 0; // value = mantissa * 10^scale
    var seen_dot = false;
    while (i < text.len and text[i] != 'e' and text[i] != 'E') : (i += 1) {
        const c = text[i];
        if (c == '.') {
            seen_dot = true;
            continue;
        }
        mantissa = std.math.mul(i128, mantissa, 10) catch return ElzError.Overflow;
        mantissa += c - '0';
        if (seen_dot) scale -= 1;
    }
    if (i < text.len) {
        const exp = std.fmt.parseInt(i32, text[i + 1 ..], 10) catch return ElzError.Overflow;
        scale += exp;
    }
    if (negative) mantissa = -mantissa;
    var num: i128 = mantissa;
    var den: i128 = 1;
    var k = scale;
    while (k > 0) : (k -= 1) num = std.math.mul(i128, num, 10) catch return ElzError.Overflow;
    while (k < 0) : (k += 1) den = std.math.mul(i128, den, 10) catch return ElzError.Overflow;
    // Reduce before narrowing to i64.
    const g = gcd128(if (num < 0) -num else num, den);
    if (g > 1) {
        num = @divExact(num, g);
        den = @divExact(den, g);
    }
    if (num > std.math.maxInt(i64) or num < std.math.minInt(i64) or den > std.math.maxInt(i64)) return ElzError.Overflow;
    return core.normalizeRational(@intCast(num), @intCast(den), allocator);
}

fn gcd128(a: i128, b: i128) i128 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = @rem(x, y);
        x = t;
    }
    return x;
}

/// Parses `token` as a number with the Scheme prefixes `#e`, `#i`, `#x`,
/// `#o`, `#b`, and `#d` in either order. Returns null when the token is not
/// numeric, so the caller can treat it as a symbol.
pub fn parseNumber(token: []const u8, allocator: std.mem.Allocator) ElzError!?Value {
    var rest = token;
    var force_exact: ?bool = null;
    var radix: ?u8 = null;
    // Up to two prefixes, in either order.
    var prefixes: usize = 0;
    while (prefixes < 2 and rest.len >= 2 and rest[0] == '#') : (prefixes += 1) {
        switch (rest[1]) {
            'e', 'E' => {
                if (force_exact != null) return null;
                force_exact = true;
            },
            'i', 'I' => {
                if (force_exact != null) return null;
                force_exact = false;
            },
            'x', 'X' => {
                if (radix != null) return null;
                radix = 16;
            },
            'o', 'O' => {
                if (radix != null) return null;
                radix = 8;
            },
            'b', 'B' => {
                if (radix != null) return null;
                radix = 2;
            },
            'd', 'D' => {
                if (radix != null) return null;
                radix = 10;
            },
            else => return null,
        }
        rest = rest[2..];
    }
    const has_prefix = prefixes > 0;
    const r: u8 = radix orelse 10;

    // Rational p/q.
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const numer = parseIntegerStrict(rest[0..slash], r) orelse return if (has_prefix) ElzError.InvalidArgument else null;
        const denom = parseIntegerStrict(rest[slash + 1 ..], r) orelse return if (has_prefix) ElzError.InvalidArgument else null;
        if (rest[slash + 1] == '+' or rest[slash + 1] == '-') return if (has_prefix) ElzError.InvalidArgument else null;
        if (denom == 0) return ElzError.DivisionByZero;
        const rational_val = try core.normalizeRational(numer, denom, allocator);
        if (force_exact == false) {
            const f = switch (rational_val) {
                .exact_integer => |n| @as(f64, @floatFromInt(n)),
                .rational => |rv| rv.toFloat(),
                else => unreachable,
            };
            return Value{ .number = f };
        }
        return rational_val;
    }

    // Integer.
    if (parseIntegerStrict(rest, r)) |n| {
        if (force_exact == false) return Value{ .number = @floatFromInt(n) };
        return Value{ .exact_integer = n };
    }
    if (r != 10) {
        // An integer that overflows i64 in a non-decimal radix, or garbage.
        return if (has_prefix) ElzError.InvalidArgument else null;
    }

    // Decimal real, infinities, and NaN.
    if (parseReal(rest)) |num| {
        if (force_exact == true) {
            if (!std.math.isFinite(num)) return ElzError.InvalidArgument;
            return try exactFromDecimal(rest, allocator);
        }
        return Value{ .number = num };
    }

    // Complex literal: <real><sign><imag>i, e.g. 3+4i, -2.5+0.0i, +inf.0i.
    if (rest.len >= 2 and (rest[rest.len - 1] == 'i' or rest[rest.len - 1] == 'I')) {
        if (parseComplex(rest, allocator)) |v| {
            if (force_exact == true) return ElzError.InvalidArgument;
            return v;
        } else |_| {}
    }

    return if (has_prefix) ElzError.InvalidArgument else null;
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

/// Parses the first datum in `source`. Returns the value and the byte offset
/// just past its final token, or null when the source holds no datum.
pub fn readOne(source: []const u8, allocator: std.mem.Allocator) ElzError!?struct { value: Value, consumed: usize } {
    var tokens = tokenize(source, allocator) catch |err| return err;
    defer tokens.deinit(allocator);
    if (tokens.items.len == 0) return null;

    var p = Parser{
        .tokens = tokens,
        .position = 0,
        .allocator = allocator,
        .source = source,
    };
    const v = try p.parse_form();
    const consumed = if (p.position < p.tokens.items.len) blk: {
        const next_tok = p.tokens.items[p.position];
        break :blk @intFromPtr(next_tok.ptr) - @intFromPtr(source.ptr);
    } else source.len;
    return .{ .value = v, .consumed = consumed };
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
    return readAllTracked(source, allocator, "", null);
}

/// Like `readAll`, but records the file and line of every parsed pair into
/// `locations` (keyed by pair pointer) for error reporting.
pub fn readAllTracked(source: []const u8, allocator: std.mem.Allocator, file: []const u8, locations: ?*FormLocations) !std.ArrayListUnmanaged(Value) {
    var tokens = tokenize(source, allocator) catch |err| {
        return err;
    };
    defer tokens.deinit(allocator);
    if (tokens.items.len == 0) return .empty;

    var parser = Parser{
        .tokens = tokens,
        .position = 0,
        .allocator = allocator,
        .source = source,
        .file = file,
        .locations = locations,
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
    try testing.expectEqualStrings("hello world", value.string.bytes);

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
