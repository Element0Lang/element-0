const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

// ============================================================================
// Minimal NFA-based Regex Engine
// Supports: literals, . (any), *, +, ?, ^, $, [abc], [a-z], \. \* etc.
// ============================================================================

const NodeKind = enum {
    literal, // Match a specific byte
    any, // Match any byte (.)
    char_class, // Match any byte in a set
    neg_char_class, // Match any byte NOT in a set
    split, // Epsilon split: out1 and out2
    jump, // Unconditional epsilon: out1
    match, // Successful match
    anchor_start, // ^ - match start of string
    anchor_end, // $ - match end of string
};

const Node = struct {
    kind: NodeKind,
    ch: u8 = 0,
    class_bits: ?*[256]bool = null,
    out1: ?usize = null,
    out2: ?usize = null,
};

const Regex = struct {
    nodes: []Node,
    start: usize,
};

const MatchResult = struct { start: usize, end: usize };

fn compile(pattern: []const u8, allocator: std.mem.Allocator) !Regex {
    var nodes = std.ArrayListUnmanaged(Node){};
    errdefer nodes.deinit(allocator);

    // First pass: compile atoms into nodes without linking
    // We'll collect indices of the "atom" nodes and then link them
    var atom_indices = std.ArrayListUnmanaged(usize){};
    defer atom_indices.deinit(allocator);

    var i: usize = 0;
    while (i < pattern.len) {
        // Parse one atom (possibly with quantifier)
        const atom_start = nodes.items.len;

        switch (pattern[i]) {
            '.' => {
                try nodes.append(allocator, .{ .kind = .any });
                i += 1;
            },
            '^' => {
                try nodes.append(allocator, .{ .kind = .anchor_start });
                i += 1;
                try atom_indices.append(allocator, atom_start);
                continue; // anchors can't have quantifiers
            },
            '$' => {
                try nodes.append(allocator, .{ .kind = .anchor_end });
                i += 1;
                try atom_indices.append(allocator, atom_start);
                continue;
            },
            '[' => {
                i += 1;
                const negated = i < pattern.len and pattern[i] == '^';
                if (negated) i += 1;

                const bits = try allocator.create([256]bool);
                @memset(bits, false);

                while (i < pattern.len and pattern[i] != ']') {
                    if (i + 2 < pattern.len and pattern[i + 1] == '-') {
                        var c: usize = pattern[i];
                        while (c <= pattern[i + 2]) : (c += 1) bits[c] = true;
                        i += 3;
                    } else {
                        bits[pattern[i]] = true;
                        i += 1;
                    }
                }
                if (i >= pattern.len) {
                    allocator.destroy(bits);
                    return error.OutOfMemory;
                }
                i += 1; // skip ']'
                try nodes.append(allocator, .{
                    .kind = if (negated) .neg_char_class else .char_class,
                    .class_bits = bits,
                });
            },
            '\\' => {
                i += 1;
                if (i >= pattern.len) return error.OutOfMemory;
                try nodes.append(allocator, .{ .kind = .literal, .ch = pattern[i] });
                i += 1;
            },
            '*', '+', '?' => {
                // Quantifier without preceding atom, treat as literal
                try nodes.append(allocator, .{ .kind = .literal, .ch = pattern[i] });
                i += 1;
                try atom_indices.append(allocator, atom_start);
                continue;
            },
            else => {
                try nodes.append(allocator, .{ .kind = .literal, .ch = pattern[i] });
                i += 1;
            },
        }

        // Check for quantifier
        if (i < pattern.len and (pattern[i] == '*' or pattern[i] == '+' or pattern[i] == '?')) {
            const quant = pattern[i];
            i += 1;

            switch (quant) {
                '*' => {
                    // split -> atom | next; atom -> split
                    const split_idx = nodes.items.len;
                    try nodes.append(allocator, .{ .kind = .split, .out1 = atom_start, .out2 = null });
                    nodes.items[atom_start].out1 = split_idx; // loop back
                    try atom_indices.append(allocator, split_idx);
                },
                '+' => {
                    // atom -> split -> atom | next
                    const split_idx = nodes.items.len;
                    try nodes.append(allocator, .{ .kind = .split, .out1 = atom_start, .out2 = null });
                    nodes.items[atom_start].out1 = split_idx;
                    try atom_indices.append(allocator, atom_start);
                },
                '?' => {
                    // split -> atom | next; atom -> next (via jump)
                    const split_idx = nodes.items.len;
                    try nodes.append(allocator, .{ .kind = .split, .out1 = atom_start, .out2 = null });
                    const jump_idx = nodes.items.len;
                    try nodes.append(allocator, .{ .kind = .jump, .out1 = null });
                    nodes.items[atom_start].out1 = jump_idx; // atom -> jump
                    try atom_indices.append(allocator, split_idx);
                },
                else => {},
            }
        } else {
            try atom_indices.append(allocator, atom_start);
        }
    }

    // Add match node
    const match_idx = nodes.items.len;
    try nodes.append(allocator, .{ .kind = .match });

    // Link: patch all null out1/out2 to the correct next destination.
    // For each atom fragment, all nodes between this entry and the next entry
    // that have null exits should point to the next entry.
    for (atom_indices.items, 0..) |_, ai| {
        const entry = atom_indices.items[ai];
        const next_entry = if (ai + 1 < atom_indices.items.len) atom_indices.items[ai + 1] else match_idx;
        const end = if (ai + 1 < atom_indices.items.len) atom_indices.items[ai + 1] else match_idx;

        // Patch all nodes in range [entry, end) that have null exits
        const range_end = @min(end, nodes.items.len);
        for (entry..range_end) |ni| {
            const node = &nodes.items[ni];
            switch (node.kind) {
                .split => {
                    if (node.out2 == null) node.out2 = next_entry;
                },
                .jump => {
                    if (node.out1 == null) node.out1 = next_entry;
                },
                .literal, .any, .char_class, .neg_char_class => {
                    if (node.out1 == null) node.out1 = next_entry;
                },
                .anchor_start, .anchor_end => {
                    if (node.out1 == null) node.out1 = next_entry;
                },
                .match => {},
            }
        }
    }

    const start = if (atom_indices.items.len > 0) atom_indices.items[0] else match_idx;

    return .{
        .nodes = try nodes.toOwnedSlice(allocator),
        .start = start,
    };
}

/// Try to match the regex starting at a specific position in the input.
fn matchAt(regex: Regex, input: []const u8, start_pos: usize, allocator: std.mem.Allocator) !?MatchResult {
    var current = std.AutoHashMapUnmanaged(usize, void){};
    defer current.deinit(allocator);
    var next_states = std.AutoHashMapUnmanaged(usize, void){};
    defer next_states.deinit(allocator);

    try addState(&current, regex, regex.start, allocator, input, start_pos);

    var last_match: ?usize = null; // Track longest match position
    var pos = start_pos;

    while (pos <= input.len) {
        // Check for match state (greedy: keep going to find longest)
        var it = current.iterator();
        while (it.next()) |entry| {
            if (regex.nodes[entry.key_ptr.*].kind == .match) {
                last_match = pos;
            }
        }

        if (pos >= input.len) break;
        if (current.count() == 0) break;

        next_states.clearRetainingCapacity();
        var curr_it = current.iterator();
        while (curr_it.next()) |entry| {
            const state = entry.key_ptr.*;
            const node = regex.nodes[state];
            const ch = input[pos];

            const matches = switch (node.kind) {
                .literal => node.ch == ch,
                .any => true,
                .char_class => if (node.class_bits) |bits| bits[ch] else false,
                .neg_char_class => if (node.class_bits) |bits| !bits[ch] else false,
                else => false,
            };

            if (matches) {
                if (node.out1) |out| {
                    try addState(&next_states, regex, out, allocator, input, pos + 1);
                }
            }
        }

        const tmp = current;
        current = next_states;
        next_states = tmp;
        next_states.clearRetainingCapacity();
        pos += 1;
    }

    // Final check at the end position
    var final_it = current.iterator();
    while (final_it.next()) |entry| {
        if (regex.nodes[entry.key_ptr.*].kind == .match) {
            last_match = pos;
        }
    }

    if (last_match) |end| {
        return .{ .start = start_pos, .end = end };
    }
    return null;
}

fn addState(set: *std.AutoHashMapUnmanaged(usize, void), regex: Regex, state: usize, allocator: std.mem.Allocator, input: []const u8, pos: usize) !void {
    if (set.contains(state)) return;
    try set.put(allocator, state, {});

    const node = regex.nodes[state];
    switch (node.kind) {
        .split => {
            if (node.out1) |out| try addState(set, regex, out, allocator, input, pos);
            if (node.out2) |out| try addState(set, regex, out, allocator, input, pos);
        },
        .jump => {
            if (node.out1) |out| try addState(set, regex, out, allocator, input, pos);
        },
        .anchor_start => {
            if (pos == 0) {
                if (node.out1) |out| try addState(set, regex, out, allocator, input, pos);
            }
        },
        .anchor_end => {
            if (pos == input.len) {
                if (node.out1) |out| try addState(set, regex, out, allocator, input, pos);
            }
        },
        else => {},
    }
}

// ============================================================================
// Element 0 Primitives
// ============================================================================

pub fn regex_match(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    if (args.items[1] != .string) return ElzError.InvalidArgument;

    const pattern = args.items[0].string;
    const input = args.items[1].string;

    var full = std.ArrayListUnmanaged(u8){};
    defer full.deinit(env.allocator);
    full.append(env.allocator, '^') catch return ElzError.OutOfMemory;
    full.appendSlice(env.allocator, pattern) catch return ElzError.OutOfMemory;
    full.append(env.allocator, '$') catch return ElzError.OutOfMemory;

    const regex = compile(full.items, env.allocator) catch return ElzError.InvalidArgument;
    defer env.allocator.free(regex.nodes);

    const result = matchAt(regex, input, 0, env.allocator) catch return ElzError.OutOfMemory;
    return Value{ .boolean = result != null };
}

pub fn regex_search(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    if (args.items[1] != .string) return ElzError.InvalidArgument;

    const pattern = args.items[0].string;
    const input = args.items[1].string;

    const regex = compile(pattern, env.allocator) catch return ElzError.InvalidArgument;
    defer env.allocator.free(regex.nodes);

    for (0..input.len + 1) |pos| {
        const result = matchAt(regex, input, pos, env.allocator) catch return ElzError.OutOfMemory;
        if (result) |m| {
            if (m.end > m.start) {
                return Value{ .string = env.allocator.dupe(u8, input[m.start..m.end]) catch return ElzError.OutOfMemory };
            }
        }
    }
    return Value{ .boolean = false };
}

pub fn regex_replace(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    if (args.items[1] != .string) return ElzError.InvalidArgument;
    if (args.items[2] != .string) return ElzError.InvalidArgument;

    const pattern = args.items[0].string;
    const replacement = args.items[1].string;
    const input = args.items[2].string;

    const regex = compile(pattern, env.allocator) catch return ElzError.InvalidArgument;
    defer env.allocator.free(regex.nodes);

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(env.allocator);
    var pos: usize = 0;

    while (pos <= input.len) {
        // Search for the next match starting from pos or later
        var found: ?MatchResult = null;
        var search_pos = pos;
        while (search_pos <= input.len) {
            const m = matchAt(regex, input, search_pos, env.allocator) catch return ElzError.OutOfMemory;
            if (m) |match_result| {
                if (match_result.end > match_result.start) {
                    found = match_result;
                    break;
                }
            }
            search_pos += 1;
        }

        if (found) |match_result| {
            result.appendSlice(env.allocator, input[pos..match_result.start]) catch return ElzError.OutOfMemory;
            result.appendSlice(env.allocator, replacement) catch return ElzError.OutOfMemory;
            pos = match_result.end;
        } else {
            result.appendSlice(env.allocator, input[pos..]) catch return ElzError.OutOfMemory;
            break;
        }
    }

    return Value{ .string = result.toOwnedSlice(env.allocator) catch return ElzError.OutOfMemory };
}

pub fn regex_split(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    if (args.items[1] != .string) return ElzError.InvalidArgument;

    const pattern = args.items[0].string;
    const input = args.items[1].string;

    const regex = compile(pattern, env.allocator) catch return ElzError.InvalidArgument;
    defer env.allocator.free(regex.nodes);

    var parts = std.ArrayListUnmanaged(Value){};
    defer parts.deinit(env.allocator);
    var pos: usize = 0;

    while (pos <= input.len) {
        // Search for the next match starting from pos or later
        var found: ?MatchResult = null;
        var search_pos = pos;
        while (search_pos <= input.len) {
            const m = matchAt(regex, input, search_pos, env.allocator) catch return ElzError.OutOfMemory;
            if (m) |match_result| {
                if (match_result.end > match_result.start) {
                    found = match_result;
                    break;
                }
            }
            search_pos += 1;
        }

        if (found) |match_result| {
            const part = env.allocator.dupe(u8, input[pos..match_result.start]) catch return ElzError.OutOfMemory;
            parts.append(env.allocator, Value{ .string = part }) catch return ElzError.OutOfMemory;
            pos = match_result.end;
        } else {
            break;
        }
    }

    // Add remaining
    const rest = env.allocator.dupe(u8, input[pos..]) catch return ElzError.OutOfMemory;
    parts.append(env.allocator, Value{ .string = rest }) catch return ElzError.OutOfMemory;

    // Build list
    var list_result: Value = Value.nil;
    var j = parts.items.len;
    while (j > 0) {
        j -= 1;
        const p = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
        p.* = .{ .car = parts.items[j], .cdr = list_result };
        list_result = Value{ .pair = p };
    }
    return list_result;
}

// ============================================================================
// Tests
// ============================================================================

test "regex-match? basic" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 10000;

    const r1 = try interp.evalString("(regex-match? \"hello\" \"hello\")", &fuel);
    try testing.expect(r1 == .boolean and r1.boolean == true);

    fuel = 10000;
    const r2 = try interp.evalString("(regex-match? \"hello\" \"world\")", &fuel);
    try testing.expect(r2 == .boolean and r2.boolean == false);

    fuel = 10000;
    const r3 = try interp.evalString("(regex-match? \"h.llo\" \"hello\")", &fuel);
    try testing.expect(r3 == .boolean and r3.boolean == true);

    fuel = 10000;
    const r4 = try interp.evalString("(regex-match? \"ab*c\" \"ac\")", &fuel);
    try testing.expect(r4 == .boolean and r4.boolean == true);

    fuel = 10000;
    const r5 = try interp.evalString("(regex-match? \"ab*c\" \"abbc\")", &fuel);
    try testing.expect(r5 == .boolean and r5.boolean == true);

    fuel = 10000;
    const r6 = try interp.evalString("(regex-match? \"ab?c\" \"abc\")", &fuel);
    try testing.expect(r6 == .boolean and r6.boolean == true);

    fuel = 10000;
    const r7 = try interp.evalString("(regex-match? \"ab?c\" \"ac\")", &fuel);
    try testing.expect(r7 == .boolean and r7.boolean == true);

    fuel = 10000;
    const r8 = try interp.evalString("(regex-match? \"ab+c\" \"abc\")", &fuel);
    try testing.expect(r8 == .boolean and r8.boolean == true);

    fuel = 10000;
    const r9 = try interp.evalString("(regex-match? \"ab+c\" \"ac\")", &fuel);
    try testing.expect(r9 == .boolean and r9.boolean == false);
}

test "regex-search" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 10000;

    const r1 = try interp.evalString("(regex-search \"[0-9]+\" \"abc123def\")", &fuel);
    try testing.expect(r1 == .string);
    try testing.expectEqualStrings("123", r1.string);
}

test "regex-replace" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 10000;

    const r1 = try interp.evalString("(regex-replace \"[0-9]+\" \"NUM\" \"abc123def456\")", &fuel);
    try testing.expect(r1 == .string);
    try testing.expectEqualStrings("abcNUMdefNUM", r1.string);
}

test "regex-split" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 10000;

    const r1 = try interp.evalString("(regex-split \",\" \"a,b,c\")", &fuel);
    try testing.expect(r1 == .pair);
    try testing.expectEqualStrings("a", r1.pair.car.string);
}
