const core = @import("core.zig");
const std = @import("std");
const Value = core.Value;

/// Maximum nesting depth for printing lists to prevent stack overflow.
/// This protects against circular references and extremely deep nesting.
const MAX_PRINT_DEPTH: usize = 1000;

/// Writes a character as itself (display mode). Invalid code points are
/// rendered as a placeholder rather than raising an error.
fn writeCharRaw(c: u32, writer: anytype) !void {
    if (c > 0x10FFFF) return writer.writeAll("invalid-char");
    const codepoint: u21 = @intCast(c);
    if (!std.unicode.utf8ValidCodepoint(codepoint)) return writer.writeAll("invalid-char");
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return writer.writeAll("invalid-char");
    try writer.writeAll(buf[0..len]);
}

/// Writes an inexact real in its R7RS external representation. An inexact
/// value always carries a decimal point or an exponent, so `1.0` never prints
/// as `1` (which would read back as an exact integer), and the infinities and
/// NaN use their standard spellings.
pub fn writeFloat(n: f64, writer: anytype) !void {
    if (std.math.isNan(n)) return writer.writeAll("+nan.0");
    if (std.math.isInf(n)) return writer.writeAll(if (n > 0) "+inf.0" else "-inf.0");

    var buf: [128]u8 = undefined;
    const magnitude = @abs(n);
    // Very large and very small magnitudes use exponent notation: the plain
    // decimal expansion of, say, 1e300 would be 300 digits long.
    if (magnitude != 0 and (magnitude >= 1e21 or magnitude < 1e-10)) {
        const text = std.fmt.bufPrint(&buf, "{e}", .{n}) catch return error.WriteFailed;
        return writer.writeAll(text);
    }
    const text = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return error.WriteFailed;
    try writer.writeAll(text);
    // Shortest-round-trip formatting drops a trailing ".0"; put it back.
    if (std.mem.indexOfAny(u8, text, ".e") == null) try writer.writeAll(".0");
}

/// Reports whether a symbol must be written as `|...|` to read back as the
/// same symbol: empty names, names with delimiters or whitespace, names that
/// would read as a number or start like one, and names starting with `#`.
fn symbolNeedsBars(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '#') return true;
    for (name) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r', '(', ')', '"', ';', '\'', '`', ',', '|' => return true,
            else => if (c < 0x20) return true,
        }
    }
    const first = name[0];
    const digit_start = std.ascii.isDigit(first) or
        ((first == '+' or first == '-' or first == '.') and name.len > 1 and (std.ascii.isDigit(name[1]) or name[1] == '.'));
    if (digit_start) return true;
    if (std.mem.eql(u8, name, ".")) return true;
    return false;
}

/// How strings and characters are rendered. `write` produces machine-readable
/// output (quoted strings, `#\a` characters); `display` produces human-readable
/// output (raw string bytes and characters). The distinction applies at every
/// nesting level, so `(display '("a" #\b))` prints `(a b)`.
pub const Mode = enum { write, display };

/// `write` prints a `Value` to the given writer in a machine-readable format.
/// This function is used by the `write` primitive function, as well as the REPL.
///
/// Parameters:
/// - `value`: The `Value` to be written.
/// - `writer`: The writer to print to. This can be any `std.io.Writer`.
pub fn write(value: Value, writer: anytype) !void {
    try writeWithDepth(value, writer, 0, .write);
}

/// `display` prints a `Value` in human-readable form: strings appear without
/// quotes and characters as themselves, at every nesting level.
pub fn display(value: Value, writer: anytype) !void {
    try writeWithDepth(value, writer, 0, .display);
}

/// Internal function that tracks recursion depth to prevent stack overflow.
fn writeWithDepth(value: Value, writer: anytype, depth: usize, mode: Mode) !void {
    if (depth > MAX_PRINT_DEPTH) {
        try writer.writeAll("...");
        return;
    }

    switch (value) {
        .symbol => |s| {
            if (mode == .display or !symbolNeedsBars(s)) return writer.writeAll(s);
            try writer.writeByte('|');
            for (s) |c| {
                switch (c) {
                    '|' => try writer.writeAll("\\|"),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('|');
        },
        .eof => try writer.writeAll("#<eof>"),
        .number => |n| try writeFloat(n, writer),
        .exact_integer => |n| try writer.print("{d}", .{n}),
        .rational => |r| try writer.print("{d}/{d}", .{ r.numerator, r.denominator }),
        .complex => |c| {
            try writeFloat(c.real, writer);
            // The imaginary part always carries an explicit sign.
            if (!std.math.signbit(c.imag) and std.math.isFinite(c.imag)) try writer.writeAll("+");
            try writeFloat(c.imag, writer);
            try writer.writeAll("i");
        },
        .boolean => |b| try writer.writeAll(if (b) "#t" else "#f"),
        .nil => try writer.writeAll("()"),
        .character => |c| {
            if (mode == .display) return writeCharRaw(c, writer);
            try writer.writeAll("#\\");
            switch (c) {
                ' ' => try writer.writeAll("space"),
                '\n' => try writer.writeAll("newline"),
                '\t' => try writer.writeAll("tab"),
                '\r' => try writer.writeAll("return"),
                0 => try writer.writeAll("null"),
                7 => try writer.writeAll("alarm"),
                8 => try writer.writeAll("backspace"),
                27 => try writer.writeAll("escape"),
                127 => try writer.writeAll("delete"),
                else => {
                    if (c < 0x20) {
                        try writer.print("x{x}", .{c});
                        return;
                    }
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
            if (mode == .display) return writer.writeAll(s);
            try writer.writeAll("\"");
            for (s) |c| {
                switch (c) {
                    '\\' => try writer.writeAll("\\\\"),
                    '"' => try writer.writeAll("\\\""),
                    '\n' => try writer.writeAll("\\n"),
                    '\t' => try writer.writeAll("\\t"),
                    '\r' => try writer.writeAll("\\r"),
                    else => {
                        if (c < 0x20 or c == 0x7f) {
                            try writer.print("\\x{x};", .{c});
                        } else {
                            try writer.writeByte(c);
                        }
                    },
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
                try writeWithDepth(current.car, writer, depth + 1, mode);
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
                        try writeWithDepth(current.cdr, writer, depth + 1, mode);
                        break;
                    },
                }
            }
            try writer.writeAll(")");
        },
        .vm_closure => try writer.writeAll("#<closure>"),
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
                try writeWithDepth(item, writer, depth + 1, mode);
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
        .bytevector => |bv| {
            try writer.writeAll("#u8(");
            for (bv.items, 0..) |byte, i| {
                if (i > 0) try writer.writeAll(" ");
                try writer.print("{d}", .{byte});
            }
            try writer.writeAll(")");
        },
        .continuation => try writer.writeAll("#<continuation>"),
        .escape => try writer.writeAll("#<escape-continuation>"),
        .record_type => |rtd| {
            try writer.writeAll("#<record-type:");
            try writer.writeAll(rtd.name);
            try writer.writeAll(">");
        },
        .record => |rec| {
            try writer.writeAll("#<");
            try writer.writeAll(rec.rtd.name);
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
    try testing.expectEqualStrings("42.0", w.buffered());

    // An inexact value is never written like an exact one.
    w = .fixed(&buf);
    try write(Value{ .number = 0.5 }, &w);
    try testing.expectEqualStrings("0.5", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .exact_integer = 42 }, &w);
    try testing.expectEqualStrings("42", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .number = 1e300 }, &w);
    try testing.expectEqualStrings("1e300", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .number = std.math.inf(f64) }, &w);
    try testing.expectEqualStrings("+inf.0", w.buffered());

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

    // Test complex numbers
    var c1: core.Complex = .{ .real = 1.0, .imag = 2.0 };
    var c2: core.Complex = .{ .real = 1.0, .imag = -2.0 };
    var c3: core.Complex = .{ .real = 1.0, .imag = -0.0 };
    var c4: core.Complex = .{ .real = 1.0, .imag = 0.0 };
    var c5: core.Complex = .{ .real = 1.0, .imag = std.math.inf(f64) };
    var c6: core.Complex = .{ .real = 1.0, .imag = -std.math.inf(f64) };
    var c7: core.Complex = .{ .real = 1.0, .imag = std.math.nan(f64) };

    w = .fixed(&buf);
    try write(Value{ .complex = &c1 }, &w);
    try testing.expectEqualStrings("1.0+2.0i", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .complex = &c2 }, &w);
    try testing.expectEqualStrings("1.0-2.0i", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .complex = &c3 }, &w);
    try testing.expectEqualStrings("1.0-0.0i", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .complex = &c4 }, &w);
    try testing.expectEqualStrings("1.0+0.0i", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .complex = &c5 }, &w);
    try testing.expectEqualStrings("1.0+inf.0i", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .complex = &c6 }, &w);
    try testing.expectEqualStrings("1.0-inf.0i", w.buffered());
    w = .fixed(&buf);
    try write(Value{ .complex = &c7 }, &w);
    try testing.expectEqualStrings("1.0+nan.0i", w.buffered());
}

test "write deeply nested list - regression for stack overflow" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Build a deeply nested list `(1 (2 (3 (4 ... (500)))))`. The innermost level is the
    // one-element list `(500)`. Each outer level wraps the previous list with one extra
    // pair so the writer's recursive `car` walk reaches the configured depth.
    var allocated_pairs: std.ArrayListUnmanaged(*core.Pair) = .empty;
    defer allocated_pairs.deinit(allocator);

    const innermost = try allocator.create(core.Pair);
    try allocated_pairs.append(allocator, innermost);
    innermost.* = .{ .car = Value{ .exact_integer = 500 }, .cdr = Value.nil };
    var current: Value = Value{ .pair = innermost };

    var depth: usize = 1;
    while (depth < 500) : (depth += 1) {
        const wrapper = try allocator.create(core.Pair);
        try allocated_pairs.append(allocator, wrapper);
        wrapper.* = .{ .car = current, .cdr = Value.nil };

        const outer = try allocator.create(core.Pair);
        try allocated_pairs.append(allocator, outer);
        outer.* = .{
            .car = Value{ .exact_integer = @intCast(500 - depth) },
            .cdr = Value{ .pair = wrapper },
        };
        current = Value{ .pair = outer };
    }
    defer for (allocated_pairs.items) |p| allocator.destroy(p);

    // This should not stack overflow.
    try write(current, &w);
    const output = w.buffered();

    // Verify it starts correctly.
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
            .car = Value{ .exact_integer = @intCast(1100 - depth) },
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
            .car = Value{ .exact_integer = @intCast(i) },
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
        .car = Value{ .exact_integer = 1 },
        .cdr = Value{ .exact_integer = 2 },
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

// ---------------------------------------------------------------------------
// Labeled writing (R7RS write / write-shared): datum labels for cycles.
// ---------------------------------------------------------------------------

/// Which nodes receive datum labels.
pub const LabelMode = enum {
    /// Label only nodes that are part of a cycle (R7RS `write`).
    cycles,
    /// Label every shared node (R7RS `write-shared`).
    shared,
};

fn ptrOf(value: Value) ?usize {
    return switch (value) {
        .pair => |p| @intFromPtr(p),
        .vector => |v| @intFromPtr(v),
        else => null,
    };
}

const AnalyzeState = struct {
    allocator: std.mem.Allocator,
    /// 1 = on the current traversal path, 2 = fully traversed.
    states: std.AutoHashMapUnmanaged(usize, u8) = .empty,
    cyclic: std.AutoHashMapUnmanaged(usize, void) = .empty,
    shared: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn deinit(self: *AnalyzeState) void {
        self.states.deinit(self.allocator);
        self.cyclic.deinit(self.allocator);
        self.shared.deinit(self.allocator);
    }

    /// Returns true when the value was already seen (and marked accordingly).
    fn checkSeen(self: *AnalyzeState, ptr: usize) !bool {
        if (self.states.get(ptr)) |st| {
            if (st == 1) {
                try self.cyclic.put(self.allocator, ptr, {});
            } else {
                try self.shared.put(self.allocator, ptr, {});
            }
            return true;
        }
        return false;
    }

    fn analyze(self: *AnalyzeState, value: Value) !void {
        return self.analyzeDepth(value, 0);
    }

    fn analyzeDepth(self: *AnalyzeState, value: Value, depth: usize) !void {
        // The printer truncates beyond MAX_PRINT_DEPTH, so nothing deeper
        // needs labels; stopping here keeps the native stack bounded.
        if (depth > MAX_PRINT_DEPTH) return;
        switch (value) {
            .pair => {
                // Iterate the cdr chain so long lists do not recurse deeply.
                // Chain nodes stay "on path" until the whole chain is done.
                var chain: std.ArrayListUnmanaged(usize) = .empty;
                defer chain.deinit(self.allocator);
                var cur = value;
                while (cur == .pair) {
                    const ptr = @intFromPtr(cur.pair);
                    if (try self.checkSeen(ptr)) break;
                    try self.states.put(self.allocator, ptr, 1);
                    try chain.append(self.allocator, ptr);
                    try self.analyzeDepth(cur.pair.car, depth + 1);
                    cur = cur.pair.cdr;
                }
                if (cur != .pair) try self.analyzeDepth(cur, depth + 1);
                for (chain.items) |ptr| {
                    try self.states.put(self.allocator, ptr, 2);
                }
            },
            .vector => |v| {
                const ptr = @intFromPtr(v);
                if (try self.checkSeen(ptr)) return;
                try self.states.put(self.allocator, ptr, 1);
                for (v.items) |item| {
                    try self.analyzeDepth(item, depth + 1);
                }
                try self.states.put(self.allocator, ptr, 2);
            },
            else => {},
        }
    }
};

const LabelWriter = struct {
    allocator: std.mem.Allocator,
    /// Labeled node -> assigned label index, or null before first emission.
    labels: std.AutoHashMapUnmanaged(usize, ?usize) = .empty,
    next_label: usize = 0,

    fn deinit(self: *LabelWriter) void {
        self.labels.deinit(self.allocator);
    }

    /// Emits "#n#" (returns true) for an already-printed labeled node, or the
    /// "#n=" prefix (returns false) on its first emission.
    fn emitLabel(self: *LabelWriter, ptr: usize, writer: anytype) !bool {
        const entry = self.labels.getPtr(ptr) orelse return false;
        if (entry.*) |n| {
            try writer.print("#{d}#", .{n});
            return true;
        }
        entry.* = self.next_label;
        try writer.print("#{d}=", .{self.next_label});
        self.next_label += 1;
        return false;
    }

    fn writeValue(self: *LabelWriter, value: Value, writer: anytype, depth: usize, mode: Mode) !void {
        if (depth > MAX_PRINT_DEPTH) {
            try writer.writeAll("...");
            return;
        }
        switch (value) {
            .pair => {
                if (ptrOf(value)) |ptr| {
                    if (self.labels.contains(ptr)) {
                        if (try self.emitLabel(ptr, writer)) return;
                    }
                }
                try writer.writeAll("(");
                var cur = value.pair;
                while (true) {
                    try self.writeValue(cur.car, writer, depth + 1, mode);
                    switch (cur.cdr) {
                        .pair => |next| {
                            // A labeled tail must print in dotted position.
                            if (self.labels.contains(@intFromPtr(next))) {
                                try writer.writeAll(" . ");
                                try self.writeValue(cur.cdr, writer, depth + 1, mode);
                                break;
                            }
                            try writer.writeAll(" ");
                            cur = next;
                        },
                        .nil => break,
                        else => {
                            try writer.writeAll(" . ");
                            try self.writeValue(cur.cdr, writer, depth + 1, mode);
                            break;
                        },
                    }
                }
                try writer.writeAll(")");
            },
            .vector => |v| {
                if (self.labels.contains(@intFromPtr(v))) {
                    if (try self.emitLabel(@intFromPtr(v), writer)) return;
                }
                try writer.writeAll("#(");
                for (v.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(" ");
                    try self.writeValue(item, writer, depth + 1, mode);
                }
                try writer.writeAll(")");
            },
            else => try writeWithDepth(value, writer, depth, mode),
        }
    }
};

/// Writes `value` with datum labels: for cycles only (`write`), or for all
/// shared structure (`write-shared`).
pub fn writeLabeled(allocator: std.mem.Allocator, value: Value, writer: anytype, label_mode: LabelMode, mode: Mode) !void {
    var analysis = AnalyzeState{ .allocator = allocator };
    defer analysis.deinit();
    try analysis.analyze(value);

    var lw = LabelWriter{ .allocator = allocator };
    defer lw.deinit();
    var it = analysis.cyclic.keyIterator();
    while (it.next()) |ptr| {
        try lw.labels.put(allocator, ptr.*, null);
    }
    if (label_mode == .shared) {
        var sit = analysis.shared.keyIterator();
        while (sit.next()) |ptr| {
            try lw.labels.put(allocator, ptr.*, null);
        }
    }
    if (lw.labels.count() == 0) {
        return writeWithDepth(value, writer, 0, mode);
    }
    try lw.writeValue(value, writer, 0, mode);
}
