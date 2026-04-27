const core = @import("core.zig");
const std = @import("std");
const Value = core.Value;

/// Maximum nesting depth for printing lists to prevent stack overflow.
/// This protects against circular references and extremely deep nesting.
const MAX_PRINT_DEPTH: usize = 1000;

/// `write` prints a `Value` to the given writer in a human-readable format.
/// This function is used by the `display` and `write` primitive functions, as well as the REPL.
///
/// Parameters:
/// - `value`: The `Value` to be written.
/// - `writer`: The writer to print to. This can be any `std.io.Writer`.
pub fn write(value: Value, writer: anytype) !void {
    try writeWithDepth(value, writer, 0);
}

/// Internal function that tracks recursion depth to prevent stack overflow.
fn writeWithDepth(value: Value, writer: anytype, depth: usize) !void {
    if (depth > MAX_PRINT_DEPTH) {
        try writer.writeAll("...");
        return;
    }

    switch (value) {
        .symbol => |s| try writer.print("{s}", .{s}),
        .number => |n| try writer.print("{d}", .{n}),
        .boolean => |b| try writer.writeAll(if (b) "#t" else "#f"),
        .nil => try writer.writeAll("()"),
        .character => |c| {
            try writer.writeAll("#\\");
            switch (c) {
                ' ' => try writer.writeAll("space"),
                '\n' => try writer.writeAll("newline"),
                '\t' => try writer.writeAll("tab"),
                '\r' => try writer.writeAll("return"),
                else => {
                    if (c > 0x10FFFF) {
                        try writer.writeAll("invalid-char");
                        return;
                    }

                    const codepoint: u21 = @intCast(c);
                    if (!std.unicode.utf8ValidCodepoint(codepoint)) {
                        try writer.writeAll("invalid-char");
                        return;
                    }

                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                        try writer.writeAll("invalid-char");
                        return;
                    };
                    try writer.writeAll(buf[0..@as(usize, @intCast(len))]);
                },
            }
        },
        .string => |s| {
            try writer.writeAll("\"");
            for (s) |c| {
                switch (c) {
                    '\\' => try writer.writeAll("\\\\"),
                    '"' => try writer.writeAll("\\\""),
                    '\n' => try writer.writeAll("\\n"),
                    '\t' => try writer.writeAll("\\t"),
                    '\r' => try writer.writeAll("\\r"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeAll("\"");
        },
        .pair => |p| {
            try writer.writeAll("(");
            var current = p;
            var list_depth: usize = 0;
            while (true) {
                if (list_depth > MAX_PRINT_DEPTH) {
                    try writer.writeAll("...");
                    break;
                }
                try writeWithDepth(current.car, writer, depth + 1);
                switch (current.cdr) {
                    .pair => |next_p| {
                        try writer.writeAll(" ");
                        current = next_p;
                        list_depth += 1;
                    },
                    .nil => {
                        break;
                    },
                    else => {
                        try writer.writeAll(" . ");
                        try writeWithDepth(current.cdr, writer, depth + 1);
                        break;
                    },
                }
            }
            try writer.writeAll(")");
        },
        .closure => try writer.writeAll("#<closure>"),
        .macro => |m| {
            try writer.writeAll("#<macro:");
            try writer.writeAll(m.name);
            try writer.writeAll(">");
        },
        .procedure => try writer.writeAll("#<procedure>"),
        .foreign_procedure => try writer.writeAll("#<foreign-procedure>"),
        .opaque_pointer => try writer.writeAll("#<opaque-pointer>"),
        .cell => try writer.writeAll("#<cell>"),
        .module => try writer.writeAll("#<module>"),
        .vector => |v| {
            try writer.writeAll("#(");
            for (v.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(" ");
                try writeWithDepth(item, writer, depth + 1);
            }
            try writer.writeAll(")");
        },
        .hash_map => |hm| {
            try writer.writeAll("#<hash-map:");
            var buf: [32]u8 = undefined;
            const count_str = std.fmt.bufPrint(&buf, "{d}", .{hm.count()}) catch "?";
            try writer.writeAll(count_str);
            try writer.writeAll(" entries>");
        },
        .port => |p| {
            if (p.is_input) {
                try writer.writeAll("#<input-port:");
            } else {
                try writer.writeAll("#<output-port:");
            }
            try writer.writeAll(p.name);
            try writer.writeAll(">");
        },
        .promise => |pr| {
            if (pr.forced) {
                try writer.writeAll("#<promise:forced>");
            } else {
                try writer.writeAll("#<promise>");
            }
        },
        .multi_values => |mv| {
            try writer.writeAll("#<values:");
            var buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrint(&buf, "{d}", .{mv.items.len}) catch "?";
            try writer.writeAll(count_str);
            try writer.writeAll(">");
        },
        .syntax_rules => |sr| {
            try writer.writeAll("#<syntax-rules:");
            try writer.writeAll(sr.name);
            try writer.writeAll(">");
        },
        .unspecified => try writer.writeAll("#<unspecified>"),
    }
}

test "write simple values" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Test number
    try write(Value{ .number = 42 }, &w);
    try testing.expectEqualStrings("42", w.buffered());

    // Test boolean
    w = .fixed(&buf);
    try write(Value{ .boolean = true }, &w);
    try testing.expectEqualStrings("#t", w.buffered());

    // Test nil
    w = .fixed(&buf);
    try write(Value.nil, &w);
    try testing.expectEqualStrings("()", w.buffered());

    // Test symbol
    w = .fixed(&buf);
    try write(Value{ .symbol = "foo" }, &w);
    try testing.expectEqualStrings("foo", w.buffered());

    // Test string
    w = .fixed(&buf);
    try write(Value{ .string = "hello" }, &w);
    try testing.expectEqualStrings("\"hello\"", w.buffered());
}

test "write deeply nested list - regression for stack overflow" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Create a deeply nested list: (1 (2 (3 (4 ... ))))
    var current: Value = Value.nil;
    var depth: usize = 0;

    // Create 500 levels of nesting (well below the 1000 limit)
    while (depth < 500) : (depth += 1) {
        const p = try allocator.create(core.Pair);
        p.* = .{
            .car = Value{ .number = @floatFromInt(500 - depth) },
            .cdr = current,
        };
        current = Value{ .pair = p };
    }
    defer {
        var temp = current;
        while (temp != .nil) {
            const p = temp.pair;
            temp = p.cdr;
            allocator.destroy(p);
        }
    }

    // This should not stack overflow
    try write(current, &w);
    const output = w.buffered();

    // Verify it starts correctly
    try testing.expect(std.mem.startsWith(u8, output, "(1 (2 (3"));
}

test "write extremely deeply nested list - triggers depth limit" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Create a list deeper than MAX_PRINT_DEPTH (1000)
    var current: Value = Value.nil;
    var depth: usize = 0;

    // Create 1100 levels of nesting (exceeds the 1000 limit)
    while (depth < 1100) : (depth += 1) {
        const p = try allocator.create(core.Pair);
        p.* = .{
            .car = Value{ .number = @floatFromInt(1100 - depth) },
            .cdr = current,
        };
        current = Value{ .pair = p };
    }
    defer {
        var temp = current;
        while (temp != .nil) {
            const p = temp.pair;
            temp = p.cdr;
            allocator.destroy(p);
        }
    }

    // This should truncate with "..."
    try write(current, &w);
    const output = w.buffered();

    // Verify it contains the truncation marker
    try testing.expect(std.mem.indexOf(u8, output, "...") != null);
}

test "write long flat list - regression for list depth limit" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf: [32768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Create a very long flat list: (1 2 3 4 ... 1200)
    var current: Value = Value.nil;
    var i: usize = 1200;

    while (i > 0) : (i -= 1) {
        const p = try allocator.create(core.Pair);
        p.* = .{
            .car = Value{ .number = @floatFromInt(i) },
            .cdr = current,
        };
        current = Value{ .pair = p };
    }
    defer {
        var temp = current;
        while (temp != .nil) {
            const p = temp.pair;
            temp = p.cdr;
            allocator.destroy(p);
        }
    }

    // This should truncate because list iteration depth > 1000
    try write(current, &w);
    const output = w.buffered();

    // Should contain truncation
    try testing.expect(std.mem.indexOf(u8, output, "...") != null);
}

test "write dotted pair" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Create (1 . 2)
    const p = try allocator.create(core.Pair);
    defer allocator.destroy(p);
    p.* = .{
        .car = Value{ .number = 1 },
        .cdr = Value{ .number = 2 },
    };

    try write(Value{ .pair = p }, &w);
    try testing.expectEqualStrings("(1 . 2)", w.buffered());
}

test "write character special cases" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Test space
    try write(Value{ .character = ' ' }, &w);
    try testing.expectEqualStrings("#\\space", w.buffered());

    // Test newline
    w = .fixed(&buf);
    try write(Value{ .character = '\n' }, &w);
    try testing.expectEqualStrings("#\\newline", w.buffered());

    // Test regular character
    w = .fixed(&buf);
    try write(Value{ .character = 'a' }, &w);
    try testing.expectEqualStrings("#\\a", w.buffered());
}
