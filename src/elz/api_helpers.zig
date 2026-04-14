//! This module provides helper functions for the public API, especially for FFI.

const std = @import("std");
const core = @import("./core.zig");
const ElzError = @import("./errors.zig").ElzError;
const Value = core.Value;

/// Converts an Element 0 proper list to a Zig slice of `Value`s.
/// This function is useful for converting data from Elz to a format that is easier to work with in Zig.
///
/// Parameters:
/// - `allocator`: The memory allocator to use for the new slice.
/// - `list_head`: The head of the Element 0 list, which must be a proper list (ending in `nil`).
///
/// Returns:
/// A new slice containing the values from the list, or an error if the input is not a proper list.
pub fn listToSlice(allocator: std.mem.Allocator, list_head: Value) ![]Value {
    var items = std.ArrayListUnmanaged(Value).empty;

    var current_node = list_head;
    while (current_node != .nil) {
        const p = switch (current_node) {
            .pair => |pair_val| pair_val,
            else => return ElzError.InvalidArgument, // Not a proper list
        };
        try items.append(allocator, p.car);
        current_node = p.cdr;
    }
    return items.toOwnedSlice(allocator);
}

/// Converts a Zig slice of `Value`s to an Element 0 proper list.
/// This function is useful for creating Element 0 lists in Zig to be passed to Elz.
///
/// Parameters:
/// - `allocator`: The memory allocator to use for allocating the pairs of the new list.
/// - `slice`: The slice of `Value`s to convert.
///
/// Returns:
/// The head of a new Element 0 list as a `Value`, or an error if allocation fails.
pub fn sliceToList(allocator: std.mem.Allocator, slice: []const Value) !Value {
    var head: Value = .nil;
    var i = slice.len;
    while (i > 0) {
        i -= 1;
        const p = try allocator.create(core.Pair);
        p.* = .{
            .car = slice[i],
            .cdr = head,
        };
        head = Value{ .pair = p };
    }
    return head;
}

test "sliceToList empty slice" {
    const allocator = std.testing.allocator;
    const result = try sliceToList(allocator, &[_]Value{});
    try std.testing.expect(result == .nil);
}

test "sliceToList single element" {
    const allocator = std.testing.allocator;
    const result = try sliceToList(allocator, &[_]Value{Value{ .number = 42 }});
    try std.testing.expect(result == .pair);
    try std.testing.expectEqual(@as(f64, 42), result.pair.car.number);
    try std.testing.expect(result.pair.cdr == .nil);
}

test "sliceToList multiple elements" {
    const allocator = std.testing.allocator;
    const result = try sliceToList(allocator, &[_]Value{
        Value{ .number = 1 },
        Value{ .number = 2 },
        Value{ .number = 3 },
    });
    // First element
    try std.testing.expect(result == .pair);
    try std.testing.expectEqual(@as(f64, 1), result.pair.car.number);
    // Second element
    try std.testing.expectEqual(@as(f64, 2), result.pair.cdr.pair.car.number);
    // Third element
    try std.testing.expectEqual(@as(f64, 3), result.pair.cdr.pair.cdr.pair.car.number);
    // End of list
    try std.testing.expect(result.pair.cdr.pair.cdr.pair.cdr == .nil);
}

test "listToSlice empty list" {
    const allocator = std.testing.allocator;
    const slice = try listToSlice(allocator, Value.nil);
    defer allocator.free(slice);
    try std.testing.expectEqual(@as(usize, 0), slice.len);
}

test "listToSlice proper list" {
    const allocator = std.testing.allocator;
    // Build list (1 2 3)
    const list = try sliceToList(allocator, &[_]Value{
        Value{ .number = 1 },
        Value{ .number = 2 },
        Value{ .number = 3 },
    });
    const slice = try listToSlice(allocator, list);
    defer allocator.free(slice);

    try std.testing.expectEqual(@as(usize, 3), slice.len);
    try std.testing.expectEqual(@as(f64, 1), slice[0].number);
    try std.testing.expectEqual(@as(f64, 2), slice[1].number);
    try std.testing.expectEqual(@as(f64, 3), slice[2].number);
}

test "listToSlice improper list returns error" {
    const allocator = std.testing.allocator;
    // Create an improper list (1 . 2)
    const pair = try allocator.create(core.Pair);
    pair.* = .{
        .car = Value{ .number = 1 },
        .cdr = Value{ .number = 2 }, // Not .nil or .pair - improper
    };
    const improper_list = Value{ .pair = pair };

    const result = listToSlice(allocator, improper_list);
    try std.testing.expectError(ElzError.InvalidArgument, result);
}
