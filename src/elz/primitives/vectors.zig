const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const Vector = core.Vector;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `make_vector` creates a new vector of a given length, optionally filled with a value.
/// Syntax: (make-vector k) or (make-vector k fill)
pub fn make_vector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;

    const k_val = args.items[0];
    if (k_val != .number) return ElzError.InvalidArgument;

    const k = k_val.number;
    if (k < 0 or @floor(k) != k) return ElzError.InvalidArgument;

    const length: usize = @intFromFloat(k);
    const fill: Value = if (args.items.len == 2) args.items[1] else Value{ .number = 0 };

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

    return Value{ .number = @floatFromInt(vec_val.vector.items.len) };
}

/// `vector_ref` returns the element at a given index in a vector.
/// Syntax: (vector-ref vec k)
pub fn vector_ref(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    const idx_val = args.items[1];

    if (vec_val != .vector) return ElzError.InvalidArgument;
    if (idx_val != .number) return ElzError.InvalidArgument;

    const idx = idx_val.number;
    if (idx < 0 or @floor(idx) != idx) return ElzError.InvalidArgument;

    const index: usize = @intFromFloat(idx);
    const vec = vec_val.vector;

    if (index >= vec.items.len) return ElzError.InvalidArgument;

    return vec.items[index];
}

/// `vector_set` sets the element at a given index in a vector.
/// Syntax: (vector-set! vec k obj)
pub fn vector_set(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    const idx_val = args.items[1];
    const obj = args.items[2];

    if (vec_val != .vector) return ElzError.InvalidArgument;
    if (idx_val != .number) return ElzError.InvalidArgument;

    const idx = idx_val.number;
    if (idx < 0 or @floor(idx) != idx) return ElzError.InvalidArgument;

    const index: usize = @intFromFloat(idx);
    const vec = vec_val.vector;

    if (index >= vec.items.len) return ElzError.InvalidArgument;

    vec.items[index] = try obj.deep_clone(env.allocator);
    return Value.unspecified;
}

/// `is_vector` checks if a value is a vector.
/// Syntax: (vector? obj)
pub fn is_vector(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .vector };
}

/// `vector_fill` stores `fill` at every index of a vector.
/// Syntax: (vector-fill! vec fill)
pub fn vector_fill(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const vec_val = args.items[0];
    const fill = args.items[1];

    if (vec_val != .vector) return ElzError.InvalidArgument;

    for (vec_val.vector.items) |*slot| {
        slot.* = try fill.deep_clone(env.allocator);
    }
    return Value.unspecified;
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
    try args.append(Value{ .number = 3 });
    try args.append(Value{ .number = 42 });
    const result = try make_vector(&interp, interp.root_env, args, &fuel);
    try std.testing.expect(result == .vector);
    try std.testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try std.testing.expectEqual(@as(f64, 42), result.vector.items[0].number);

    // Test vector-length
    args = core.ValueList.init(interp.allocator);
    try args.append(result);
    const len_result = try vector_length(&interp, interp.root_env, args, &fuel);
    try std.testing.expect(len_result == .number);
    try std.testing.expectEqual(@as(f64, 3), len_result.number);
}

test "vector-fill!" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    var make_args = core.ValueList.init(interp.allocator);
    try make_args.append(Value{ .number = 4 });
    try make_args.append(Value{ .number = 0 });
    const v = try make_vector(&interp, interp.root_env, make_args, &fuel);

    var fill_args = core.ValueList.init(interp.allocator);
    try fill_args.append(v);
    try fill_args.append(Value{ .number = 7 });
    const out = try vector_fill(&interp, interp.root_env, fill_args, &fuel);
    try std.testing.expect(out == .unspecified);
    for (v.vector.items) |item| {
        try std.testing.expectEqual(@as(f64, 7), item.number);
    }
}
