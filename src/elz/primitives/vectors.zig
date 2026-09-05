const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const Vector = core.Vector;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// Converts a numeric `Value` to a non-negative `usize` index.
/// Accepts `.exact_integer` (>= 0) and `.number` (non-negative integer-valued).
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

/// `make_vector` creates a new vector of a given length, optionally filled with a value.
/// Syntax: (make-vector k) or (make-vector k fill)
pub fn make_vector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;

    const length = try toIndex(args.items[0]);
    const fill: Value = if (args.items.len == 2) args.items[1] else Value{ .exact_integer = 0 };

    const vec = try env.allocator.create(Vector);
    const items = try env.allocator.alloc(Value, length);

    for (items) |*item| {
        item.* = fill;
    }

    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// `vector` creates a new vector from the given arguments.
/// Syntax: (vector obj ...)
pub fn vector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const vec = try env.allocator.create(Vector);
    const items = try env.allocator.alloc(Value, args.items.len);

    for (args.items, 0..) |arg, i| {
        items[i] = arg;
    }

    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// `vector_length` returns the length of a vector.
/// Syntax: (vector-length vec)
pub fn vector_length(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    if (vec_val != .vector) return interp.fail(ElzError.InvalidArgument, "vector-length: expected a vector, got {s}", .{core.typeName(vec_val)});

    return Value{ .exact_integer = @intCast(vec_val.vector.items.len) };
}

/// `vector_ref` returns the element at a given index in a vector.
/// Syntax: (vector-ref vec k)
pub fn vector_ref(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    if (vec_val != .vector) return interp.fail(ElzError.InvalidArgument, "vector-ref: expected a vector, got {s}", .{core.typeName(vec_val)});
    const index = try toIndex(args.items[1]);
    const vec = vec_val.vector;
    if (index >= vec.items.len) return interp.fail(ElzError.InvalidArgument, "vector-ref: index {d} is out of range for a vector of length {d}", .{ index, vec.items.len });
    return vec.items[index];
}

/// `vector_set` sets the element at a given index in a vector.
/// Syntax: (vector-set! vec k obj)
pub fn vector_set(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    const obj = args.items[2];

    if (vec_val != .vector) return interp.fail(ElzError.InvalidArgument, "vector-set!: expected a vector, got {s}", .{core.typeName(vec_val)});
    const index = try toIndex(args.items[1]);
    const vec = vec_val.vector;
    if (index >= vec.items.len) return interp.fail(ElzError.InvalidArgument, "vector-set!: index {d} is out of range for a vector of length {d}", .{ index, vec.items.len });

    vec.items[index] = obj;
    return Value.unspecified;
}

/// `is_vector` checks if a value is a vector.
/// Syntax: (vector? obj)
pub fn is_vector(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .vector };
}

/// `list_to_vector` converts a list to a vector.
/// Syntax: (list->vector list)
pub fn list_to_vector(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const list = args.items[0];

    // Count list length
    var length: usize = 0;
    var current = list;
    while (current != .nil) {
        if (current != .pair) return interp.fail(ElzError.InvalidArgument, "list->vector: expected a pair, got {s}", .{core.typeName(current)});
        length += 1;
        current = current.pair.cdr;
    }

    const vec = try env.allocator.create(Vector);
    const items = try env.allocator.alloc(Value, length);

    current = list;
    var i: usize = 0;
    while (current != .nil) {
        items[i] = current.pair.car;
        current = current.pair.cdr;
        i += 1;
    }

    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// `vector_fill_bang` fills every slot of a vector with a given value.
/// Syntax: (vector-fill! vec fill)
/// Resolves optional [start [end]] arguments (from args index `from`) against
/// an element count.
fn rangeArgs(args: []const Value, from: usize, len: usize) ElzError!struct { start: usize, end: usize } {
    if (args.len > from + 2) return ElzError.WrongArgumentCount;
    var start: usize = 0;
    var end: usize = len;
    if (args.len > from) {
        if (args[from] != .exact_integer or args[from].exact_integer < 0) return ElzError.InvalidArgument;
        start = @intCast(args[from].exact_integer);
    }
    if (args.len > from + 1) {
        if (args[from + 1] != .exact_integer or args[from + 1].exact_integer < 0) return ElzError.InvalidArgument;
        end = @intCast(args[from + 1].exact_integer);
    }
    if (start > end or end > len) return ElzError.InvalidArgument;
    return .{ .start = start, .end = end };
}

pub fn vector_fill_bang(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;
    const vec_val = args.items[0];
    if (vec_val != .vector) return interp.fail(ElzError.InvalidArgument, "vector-fill!: expected a vector, got {s}", .{core.typeName(vec_val)});
    const fill = args.items[1];
    const vec = vec_val.vector;
    const r = try rangeArgs(args.items, 2, vec.items.len);
    for (vec.items[r.start..r.end]) |*slot| {
        slot.* = fill;
    }
    return Value.unspecified;
}

/// `vector_to_list` converts a vector to a list.
/// Syntax: (vector->list vec)
pub fn vector_to_list(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    if (vec_val != .vector) return interp.fail(ElzError.InvalidArgument, "vector->list: expected a vector, got {s}", .{core.typeName(vec_val)});

    const vec = vec_val.vector;
    const r = try rangeArgs(args.items, 1, vec.items.len);

    var result: Value = Value.nil;
    var i = r.end;
    while (i > r.start) {
        i -= 1;
        const pair = try env.allocator.create(core.Pair);
        pair.* = .{
            .car = vec.items[i],
            .cdr = result,
        };
        result = Value{ .pair = pair };
    }

    return result;
}

test "vector primitives" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // Test make-vector
    var args = core.ValueList.init(interp.allocator);
    try args.append(Value{ .exact_integer = 3 });
    try args.append(Value{ .exact_integer = 42 });
    const result = try make_vector(&interp, interp.root_env, args, &fuel);
    try std.testing.expect(result == .vector);
    try std.testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try std.testing.expectEqual(@as(i64, 42), result.vector.items[0].exact_integer);

    // Test vector-length
    args = core.ValueList.init(interp.allocator);
    try args.append(result);
    const len_result = try vector_length(&interp, interp.root_env, args, &fuel);
    try std.testing.expect(len_result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 3), len_result.exact_integer);
}
