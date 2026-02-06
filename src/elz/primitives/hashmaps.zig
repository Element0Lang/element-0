const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");
const writer = @import("../writer.zig");

/// `make_hash_map` creates a new empty hash map.
/// Syntax: (make-hash-map)
pub fn make_hash_map(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;

    const hm = try env.allocator.create(core.HashMap);
    hm.* = core.HashMap.init(env.allocator);

    return Value{ .hash_map = hm };
}

/// `hash_map_set` sets a key-value pair in the hash map.
/// Syntax: (hash-map-set! hm key value)
pub fn hash_map_set(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;

    const hm_val = args.items[0];
    const key_val = args.items[1];
    const value = args.items[2];

    if (hm_val != .hash_map) return ElzError.InvalidArgument;

    // Convert key to string representation
    const key = getKeyString(key_val) orelse return ElzError.InvalidArgument;

    try hm_val.hash_map.put(key, value);

    return Value.unspecified;
}

/// `hash_map_get` retrieves a value by key from the hash map.
/// Syntax: (hash-map-ref hm key) or (hash-map-ref hm key default)
pub fn hash_map_get(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 2 or args.items.len > 3) return ElzError.WrongArgumentCount;

    const hm_val = args.items[0];
    const key_val = args.items[1];

    if (hm_val != .hash_map) return ElzError.InvalidArgument;

    const key = getKeyString(key_val) orelse return ElzError.InvalidArgument;

    if (hm_val.hash_map.get(key)) |value| {
        return value;
    } else {
        if (args.items.len == 3) {
            return args.items[2]; // Return default value
        }
        return Value{ .boolean = false }; // Return #f if no default
    }
}

/// `hash_map_remove` removes a key from the hash map.
/// Syntax: (hash-map-remove! hm key)
pub fn hash_map_remove(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const hm_val = args.items[0];
    const key_val = args.items[1];

    if (hm_val != .hash_map) return ElzError.InvalidArgument;

    const key = getKeyString(key_val) orelse return ElzError.InvalidArgument;

    const removed = hm_val.hash_map.remove(key);
    return Value{ .boolean = removed };
}

/// `hash_map_contains` checks if a key exists in the hash map.
/// Syntax: (hash-map-contains? hm key)
pub fn hash_map_contains(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const hm_val = args.items[0];
    const key_val = args.items[1];

    if (hm_val != .hash_map) return ElzError.InvalidArgument;

    const key = getKeyString(key_val) orelse return ElzError.InvalidArgument;

    return Value{ .boolean = hm_val.hash_map.get(key) != null };
}

/// `hash_map_count` returns the number of entries in the hash map.
/// Syntax: (hash-map-count hm)
pub fn hash_map_count(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const hm_val = args.items[0];
    if (hm_val != .hash_map) return ElzError.InvalidArgument;

    return Value{ .number = @floatFromInt(hm_val.hash_map.count()) };
}

/// `is_hash_map` checks if a value is a hash map.
/// Syntax: (hash-map? obj)
pub fn is_hash_map(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .hash_map };
}

/// Helper function to get a string key from a value.
fn getKeyString(val: Value) ?[]const u8 {
    return switch (val) {
        .string => |s| s,
        .symbol => |s| s,
        else => null,
    };
}

test "hash_map primitives" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // Test make_hash_map
    var args = core.ValueList.init(interp.allocator);

    const hm_val = try make_hash_map(&interp, interp.root_env, args, &fuel);
    try testing.expect(hm_val == .hash_map);

    // Test hash_map_set and hash_map_get
    args.clearRetainingCapacity();
    try args.append(interp.allocator, hm_val);
    try args.append(interp.allocator, Value{ .string = "key1" });
    try args.append(interp.allocator, Value{ .number = 42 });
    _ = try hash_map_set(&interp, interp.root_env, args, &fuel);

    // Test hash_map_get
    args.clearRetainingCapacity();
    try args.append(interp.allocator, hm_val);
    try args.append(interp.allocator, Value{ .string = "key1" });
    const get_result = try hash_map_get(&interp, interp.root_env, args, &fuel);
    try testing.expect(get_result == .number);
    try testing.expectEqual(get_result.number, 42);

    // Test hash_map_contains
    const contains_result = try hash_map_contains(&interp, interp.root_env, args, &fuel);
    try testing.expect(contains_result == .boolean);
    try testing.expect(contains_result.boolean == true);

    // Test hash_map_count
    args.clearRetainingCapacity();
    try args.append(interp.allocator, hm_val);
    const count_result = try hash_map_count(&interp, interp.root_env, args, &fuel);
    try testing.expect(count_result == .number);
    try testing.expectEqual(count_result.number, 1);

    // Test is_hash_map
    const is_hm_result = try is_hash_map(&interp, interp.root_env, args, &fuel);
    try testing.expect(is_hm_result == .boolean);
    try testing.expect(is_hm_result.boolean == true);

    // Test hash_map_remove
    args.clearRetainingCapacity();
    try args.append(interp.allocator, hm_val);
    try args.append(interp.allocator, Value{ .string = "key1" });
    const remove_result = try hash_map_remove(&interp, interp.root_env, args, &fuel);
    try testing.expect(remove_result == .boolean);
    try testing.expect(remove_result.boolean == true);
}
