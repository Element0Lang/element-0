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
        .exact_integer => |i| if (i < 0) ElzError.InvalidArgument else @intCast(i),
        .number => |n| blk: {
            if (n < 0 or @floor(n) != n) break :blk ElzError.InvalidArgument;
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
        item.* = try fill.deep_clone(env.allocator);
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
        items[i] = try arg.deep_clone(env.allocator);
    }

    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// `vector_length` returns the length of a vector.
/// Syntax: (vector-length vec)
pub fn vector_length(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    if (vec_val != .vector) return ElzError.InvalidArgument;

    return Value{ .exact_integer = @intCast(vec_val.vector.items.len) };
}

/// `vector_ref` returns the element at a given index in a vector.
/// Syntax: (vector-ref vec k)
pub fn vector_ref(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    if (vec_val != .vector) return ElzError.InvalidArgument;
    const index = try toIndex(args.items[1]);
    const vec = vec_val.vector;
    if (index >= vec.items.len) return ElzError.InvalidArgument;
    return vec.items[index];
}

/// `vector_set` sets the element at a given index in a vector.
/// Syntax: (vector-set! vec k obj)
pub fn vector_set(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    const obj = args.items[2];

    if (vec_val != .vector) return ElzError.InvalidArgument;
    const index = try toIndex(args.items[1]);
    const vec = vec_val.vector;
    if (index >= vec.items.len) return ElzError.InvalidArgument;

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
pub fn list_to_vector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const list = args.items[0];

    // Count list length
    var length: usize = 0;
    var current = list;
    while (current != .nil) {
        if (current != .pair) return ElzError.InvalidArgument;
        length += 1;
        current = current.pair.cdr;
    }

    const vec = try env.allocator.create(Vector);
    const items = try env.allocator.alloc(Value, length);

    current = list;
    var i: usize = 0;
    while (current != .nil) {
        items[i] = try current.pair.car.deep_clone(env.allocator);
        current = current.pair.cdr;
        i += 1;
    }

    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// `vector_fill_bang` fills every slot of a vector with a given value.
/// Syntax: (vector-fill! vec fill)
pub fn vector_fill_bang(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const vec_val = args.items[0];
    if (vec_val != .vector) return ElzError.InvalidArgument;
    const fill = args.items[1];
    const vec = vec_val.vector;
    for (vec.items) |*slot| {
        slot.* = try fill.deep_clone(env.allocator);
    }
    return Value.unspecified;
}

/// `vector_to_list` converts a vector to a list.
/// Syntax: (vector->list vec)
pub fn vector_to_list(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    if (vec_val != .vector) return ElzError.InvalidArgument;

    const vec = vec_val.vector;

    var result: Value = Value.nil;
    var i = vec.items.len;
    while (i > 0) {
        i -= 1;
        const pair = try env.allocator.create(core.Pair);
        pair.* = .{
            .car = try vec.items[i].deep_clone(env.allocator),
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
