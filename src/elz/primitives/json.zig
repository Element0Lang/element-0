const std = @import("std");
const core = @import("../core.zig");
const writer_mod = @import("../writer.zig");
const parser_mod = @import("../parser.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

const ParseResult = struct { value: Value, pos: usize };

/// Serializes a Value to JSON format and writes to the writer.
fn serializeValue(value: Value, w: *std.Io.Writer) !void {
    switch (value) {
        .number => |n| {
            // Handle special float values
            if (std.math.isNan(n) or std.math.isInf(n)) {
                try w.writeAll("null");
            } else {
                try w.print("{d}", .{n});
            }
        },
        .string => |s| {
            try w.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\t' => try w.writeAll("\\t"),
                    '\r' => try w.writeAll("\\r"),
                    else => {
                        if (c < 0x20) {
                            try w.print("\\u{x:0>4}", .{c});
                        } else {
                            try w.writeByte(c);
                        }
                    },
                }
            }
            try w.writeByte('"');
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .nil => try w.writeAll("null"),
        .pair => {
            // Serialize proper list as JSON array
            try w.writeByte('[');
            var current: Value = value;
            var first = true;
            while (current == .pair) {
                if (!first) try w.writeByte(',');
                first = false;
                try serializeValue(current.pair.car, w);
                current = current.pair.cdr;
            }
            // If improper list, serialize the cdr too
            if (current != .nil) {
                if (!first) try w.writeByte(',');
                try serializeValue(current, w);
            }
            try w.writeByte(']');
        },
        .vector => |v| {
            try w.writeByte('[');
            for (v.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try serializeValue(item, w);
            }
            try w.writeByte(']');
        },
        .hash_map => |hm| {
            try w.writeByte('{');
            var it = hm.entries.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                // Key is always a string in Element 0 hash maps
                try w.writeByte('"');
                for (entry.key_ptr.*) |c| {
                    switch (c) {
                        '"' => try w.writeAll("\\\""),
                        '\\' => try w.writeAll("\\\\"),
                        else => try w.writeByte(c),
                    }
                }
                try w.writeByte('"');
                try w.writeByte(':');
                try serializeValue(entry.value_ptr.*, w);
            }
            try w.writeByte('}');
        },
        .character => |c| {
            // Serialize as single-character string
            try w.writeByte('"');
            if (c > 0x10FFFF) {
                try w.writeByte('?');
            } else {
                const codepoint: u21 = @intCast(c);
                if (std.unicode.utf8ValidCodepoint(codepoint)) {
                    var char_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &char_buf) catch {
                        try w.writeByte('?');
                        try w.writeByte('"');
                        return;
                    };
                    try w.writeAll(char_buf[0..@as(usize, @intCast(len))]);
                } else {
                    try w.writeByte('?');
                }
            }
            try w.writeByte('"');
        },
        .symbol => |s| {
            // Serialize symbols as strings
            try w.writeByte('"');
            try w.writeAll(s);
            try w.writeByte('"');
        },
        // Non-serializable types
        .closure, .macro, .procedure, .foreign_procedure, .opaque_pointer, .cell, .module, .port, .promise, .multi_values, .syntax_rules, .unspecified => {
            return error.OutOfMemory; // Signal unsupported type
        },
    }
}

/// Parses a JSON string and returns the position after the closing quote.
fn parseJsonString(json: []const u8, start: usize, allocator: std.mem.Allocator) !ParseResult {
    if (start >= json.len or json[start] != '"') return error.OutOfMemory;
    var i = start + 1;
    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

    while (i < json.len and json[i] != '"') {
        if (json[i] == '\\' and i + 1 < json.len) {
            switch (json[i + 1]) {
                'n' => try result.append(allocator, '\n'),
                't' => try result.append(allocator, '\t'),
                'r' => try result.append(allocator, '\r'),
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                '/' => try result.append(allocator, '/'),
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, json[i + 1]);
                },
            }
            i += 2;
        } else {
            try result.append(allocator, json[i]);
            i += 1;
        }
    }
    if (i >= json.len) return error.OutOfMemory;
    return .{
        .value = Value{ .string = try result.toOwnedSlice(allocator) },
        .pos = i + 1, // skip closing quote
    };
}

/// Skip whitespace in JSON.
fn skipWhitespace(json: []const u8, start: usize) usize {
    var i = start;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) {
        i += 1;
    }
    return i;
}

/// Parse a single JSON value, returning the parsed value and position after it.
fn parseJsonValue(json: []const u8, start: usize, allocator: std.mem.Allocator) !ParseResult {
    var i = skipWhitespace(json, start);
    if (i >= json.len) return error.OutOfMemory;

    switch (json[i]) {
        '"' => return parseJsonString(json, i, allocator),
        't' => {
            if (i + 4 <= json.len and std.mem.eql(u8, json[i .. i + 4], "true")) {
                return .{ .value = Value{ .boolean = true }, .pos = i + 4 };
            }
            return error.OutOfMemory;
        },
        'f' => {
            if (i + 5 <= json.len and std.mem.eql(u8, json[i .. i + 5], "false")) {
                return .{ .value = Value{ .boolean = false }, .pos = i + 5 };
            }
            return error.OutOfMemory;
        },
        'n' => {
            if (i + 4 <= json.len and std.mem.eql(u8, json[i .. i + 4], "null")) {
                return .{ .value = Value.nil, .pos = i + 4 };
            }
            return error.OutOfMemory;
        },
        '[' => {
            // Parse array -> list
            i += 1;
            i = skipWhitespace(json, i);

            var elements = std.ArrayListUnmanaged(Value).empty;
            defer elements.deinit(allocator);

            if (i < json.len and json[i] == ']') {
                return .{ .value = Value.nil, .pos = i + 1 };
            }

            while (i < json.len) {
                const elem = try parseJsonValue(json, i, allocator);
                try elements.append(allocator, elem.value);
                i = skipWhitespace(json, elem.pos);

                if (i < json.len and json[i] == ',') {
                    i += 1;
                } else if (i < json.len and json[i] == ']') {
                    i += 1;
                    break;
                } else {
                    return error.OutOfMemory;
                }
            }

            // Build list from elements (reverse order)
            var result: Value = Value.nil;
            var j = elements.items.len;
            while (j > 0) {
                j -= 1;
                const p = try allocator.create(core.Pair);
                p.* = .{ .car = elements.items[j], .cdr = result };
                result = Value{ .pair = p };
            }
            return .{ .value = result, .pos = i };
        },
        '{' => {
            // Parse object -> hash-map
            i += 1;
            i = skipWhitespace(json, i);

            const hm = try allocator.create(core.HashMap);
            hm.* = core.HashMap.init(allocator);

            if (i < json.len and json[i] == '}') {
                return .{ .value = Value{ .hash_map = hm }, .pos = i + 1 };
            }

            while (i < json.len) {
                i = skipWhitespace(json, i);
                const key = try parseJsonString(json, i, allocator);
                i = skipWhitespace(json, key.pos);

                if (i >= json.len or json[i] != ':') return error.OutOfMemory;
                i += 1;

                const val = try parseJsonValue(json, i, allocator);
                i = val.pos;

                try hm.put(key.value.string, val.value);

                i = skipWhitespace(json, i);
                if (i < json.len and json[i] == ',') {
                    i += 1;
                } else if (i < json.len and json[i] == '}') {
                    i += 1;
                    break;
                } else {
                    return error.OutOfMemory;
                }
            }
            return .{ .value = Value{ .hash_map = hm }, .pos = i };
        },
        '-', '0'...'9' => {
            // Parse number
            var end = i;
            if (json[end] == '-') end += 1;
            while (end < json.len and ((json[end] >= '0' and json[end] <= '9') or json[end] == '.' or json[end] == 'e' or json[end] == 'E' or json[end] == '+' or json[end] == '-')) {
                if ((json[end] == '-' or json[end] == '+') and end > i + 1 and json[end - 1] != 'e' and json[end - 1] != 'E') break;
                end += 1;
            }
            const num = std.fmt.parseFloat(f64, json[i..end]) catch return error.OutOfMemory;
            return .{ .value = Value{ .number = num }, .pos = end };
        },
        else => return error.OutOfMemory,
    }
}

/// `json-serialize` converts a Value to a JSON string.
///
/// Syntax: (json-serialize value)
pub fn json_serialize(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const allocator = env.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    serializeValue(args.items[0], &aw.writer) catch return ElzError.InvalidArgument;
    return Value{ .string = aw.toOwnedSlice() catch return ElzError.OutOfMemory };
}

/// `json-deserialize` parses a JSON string into a Value.
///
/// Syntax: (json-deserialize json-string)
pub fn json_deserialize(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const str_val = args.items[0];
    if (str_val != .string) return ElzError.InvalidArgument;

    const result = parseJsonValue(str_val.string, 0, env.allocator) catch return ElzError.InvalidArgument;
    return result.value;
}

test "json serialize numbers" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r = try interp.evalString("(json-serialize 42)", &fuel);
    try testing.expect(r == .string);
    try testing.expectEqualStrings("42", r.string);
}

test "json serialize strings" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r = try interp.evalString("(json-serialize \"hello\")", &fuel);
    try testing.expect(r == .string);
    try testing.expectEqualStrings("\"hello\"", r.string);
}

test "json serialize booleans and nil" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r1 = try interp.evalString("(json-serialize #t)", &fuel);
    try testing.expectEqualStrings("true", r1.string);

    fuel = 10000;
    const r2 = try interp.evalString("(json-serialize #f)", &fuel);
    try testing.expectEqualStrings("false", r2.string);

    fuel = 10000;
    const r3 = try interp.evalString("(json-serialize '())", &fuel);
    try testing.expectEqualStrings("null", r3.string);
}

test "json serialize list as array" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r = try interp.evalString("(json-serialize '(1 2 3))", &fuel);
    try testing.expect(r == .string);
    try testing.expectEqualStrings("[1,2,3]", r.string);
}

test "json deserialize number" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r = try interp.evalString("(json-deserialize \"42\")", &fuel);
    try testing.expect(r == .number);
    try testing.expectEqual(@as(f64, 42), r.number);
}

test "json deserialize string" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r = try interp.evalString("(json-deserialize \"\\\"hello\\\"\")", &fuel);
    try testing.expect(r == .string);
    try testing.expectEqualStrings("hello", r.string);
}

test "json deserialize array" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    const r = try interp.evalString("(json-deserialize \"[1,2,3]\")", &fuel);
    try testing.expect(r == .pair);
    try testing.expect(r.pair.car == .number);
    try testing.expectEqual(@as(f64, 1), r.pair.car.number);
}

test "json roundtrip" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var fuel: u64 = 10000;
    // Serialize then deserialize a number
    const r1 = try interp.evalString("(json-deserialize (json-serialize 42))", &fuel);
    try testing.expect(r1 == .number);
    try testing.expectEqual(@as(f64, 42), r1.number);

    // Serialize then deserialize a string
    fuel = 10000;
    const r2 = try interp.evalString("(json-deserialize (json-serialize \"hello\"))", &fuel);
    try testing.expect(r2 == .string);
    try testing.expectEqualStrings("hello", r2.string);

    // Serialize then deserialize a boolean
    fuel = 10000;
    const r3 = try interp.evalString("(json-deserialize (json-serialize #t))", &fuel);
    try testing.expect(r3 == .boolean);
    try testing.expect(r3.boolean == true);
}
