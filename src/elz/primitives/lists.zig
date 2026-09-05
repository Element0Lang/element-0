const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");
const vm_mod = @import("../vm.zig");
const predicates = @import("predicates.zig");

/// Charges one unit of work while a primitive walks a list, so a circular
/// list or a very long one stays inside the caller's fuel and time budget.
fn tick(interp: *interpreter.Interpreter, fuel: *u64) ElzError!void {
    try interp.checkTimeBudget();
    if (fuel.* == 0) return ElzError.ExecutionBudgetExceeded;
    fuel.* -= 1;
}

/// `cons` creates a new pair.
///
/// Parameters:
/// - `args`: A `ValueList` containing two elements, the `car` and the `cdr` of the new pair.
///
/// Returns:
/// A new `Value.pair`.
pub fn cons(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const p = try env.allocator.create(core.Pair);
    p.* = .{
        .car = args.items[0],
        .cdr = args.items[1],
    };
    return Value{ .pair = p };
}

/// `car` returns the first element of a pair.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single pair.
///
/// Returns:
/// The `car` of the pair.
pub fn car(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const p = args.items[0];
    if (p != .pair) return interp.fail(ElzError.InvalidArgument, "car: expected a pair, got {s}", .{core.typeName(p)});
    return p.pair.car;
}

/// `cdr` returns the second element of a pair.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single pair.
///
/// Returns:
/// The `cdr` of the pair.
pub fn cdr(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    const p = args.items[0];
    if (p != .pair) return interp.fail(ElzError.InvalidArgument, "cdr: expected a pair, got {s}", .{core.typeName(p)});
    return p.pair.cdr;
}

/// `list` creates a new list from its arguments.
///
/// Parameters:
/// - `args`: A `ValueList` of elements to be included in the new list.
///
/// Returns:
/// A new list.
pub fn list(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    var head: core.Value = .nil;
    var i = args.items.len;
    while (i > 0) {
        i -= 1;
        const p = try env.allocator.create(core.Pair);
        p.* = .{
            .car = args.items[i],
            .cdr = head,
        };
        head = Value{ .pair = p };
    }
    return head;
}

/// `list_length` returns the number of elements in a proper list.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single list.
///
/// Returns:
/// The length of the list as a `Value.number`.
pub fn list_length(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    // A circular list has no length (R7RS: it is an error).
    if (!predicates.isProperList(args.items[0])) return interp.fail(ElzError.InvalidArgument, "length: expected a proper list, got {s}", .{core.typeName(args.items[0])});
    var count: i64 = 0;
    var current = args.items[0];
    while (current != .nil) {
        try tick(interp, fuel);
        const p = switch (current) {
            .pair => |pair_val| pair_val,
            else => return ElzError.InvalidArgument,
        };
        count += 1;
        current = p.cdr;
    }
    return Value{ .exact_integer = count };
}

/// Helper for converting a numeric `Value` to a non-negative `usize` index.
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

/// `append` concatenates multiple lists into a single list.
///
/// Parameters:
/// - `args`: A `ValueList` of lists to be appended.
///
/// Returns:
/// A new list containing the elements of all the input lists.
pub fn append(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len == 0) return Value.nil;
    var result_head: core.Value = .nil;
    var result_tail: ?*core.Pair = null;
    for (args.items[0 .. args.items.len - 1]) |list_val| {
        var current_node = list_val;
        while (current_node != .nil) {
            try tick(interp, fuel);
            const p_node = switch (current_node) {
                .pair => |p| p,
                else => return ElzError.InvalidArgument,
            };
            const new_pair = try env.allocator.create(core.Pair);
            new_pair.* = .{ .car = p_node.car, .cdr = .nil };
            if (result_head == .nil) {
                result_head = Value{ .pair = new_pair };
                result_tail = new_pair;
            } else {
                if (result_tail) |tail| {
                    tail.cdr = Value{ .pair = new_pair };
                }
                result_tail = new_pair;
            }
            current_node = p_node.cdr;
        }
    }
    const last_list = args.items[args.items.len - 1];
    if (result_head == .nil) {
        return last_list;
    } else {
        if (result_tail) |tail| {
            tail.cdr = last_list;
        }
        return result_head;
    }
}

/// `reverse` reverses the order of elements in a proper list.
///
/// Parameters:
/// - `args`: A `ValueList` containing a single list to be reversed.
///
/// Returns:
/// A new list with the elements in reverse order.
pub fn reverse(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    var head: core.Value = .nil;
    var current = args.items[0];
    while (current != .nil) {
        try tick(interp, fuel);
        const p_node = switch (current) {
            .pair => |p| p,
            else => return ElzError.InvalidArgument,
        };
        const new_pair = try env.allocator.create(core.Pair);
        new_pair.* = .{ .car = p_node.car, .cdr = head };
        head = Value{ .pair = new_pair };
        current = p_node.cdr;
    }
    return head;
}

/// `map` applies a procedure to each element of a list and returns a new list with the results.
///
/// Parameters:
/// - `args`: A `ValueList` containing two elements: the procedure to apply and the list to map over.
///
/// Returns:
/// A new list containing the results of applying the procedure to each element of the input list.
pub fn map(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len < 2) return ElzError.WrongArgumentCount;
    const proc = args.items[0];
    const num_lists = args.items.len - 1;
    var result_head: core.Value = .nil;
    var result_tail: ?*core.Pair = null;
    // current position in each input list
    var cursors = try env.allocator.alloc(core.Value, num_lists);
    defer env.allocator.free(cursors);
    for (0..num_lists) |i| cursors[i] = args.items[i + 1];
    var call_args = core.ValueList.init(env.allocator);
    defer call_args.deinit();
    while (true) {
        // Stop at the shortest list (R7RS): done when any cursor is exhausted.
        var any_done = false;
        for (cursors) |cur| {
            if (cur != .pair) {
                any_done = true;
                break;
            }
        }
        if (any_done) break;
        try tick(interp, fuel);
        // Collect one element from each list.
        call_args.items.len = 0;
        for (0..num_lists) |i| {
            const cur = cursors[i];
            if (cur != .pair) return interp.fail(ElzError.InvalidArgument, "map: expected a pair, got {s}", .{core.typeName(cur)});
            try call_args.append(cur.pair.car);
            cursors[i] = cur.pair.cdr;
        }
        const mapped_val = try vm_mod.callProc(interp, proc, call_args, fuel);
        const new_pair = try env.allocator.create(core.Pair);
        new_pair.* = .{ .car = mapped_val, .cdr = .nil };
        if (result_tail) |tail| {
            tail.cdr = Value{ .pair = new_pair };
            result_tail = new_pair;
        } else {
            result_head = Value{ .pair = new_pair };
            result_tail = new_pair;
        }
    }
    return result_head;
}

/// `list_ref` returns the k-th element of a list.
/// Syntax: (list-ref list k)
pub fn list_ref(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const list_val = args.items[0];
    var idx = try toIndex(args.items[1]);
    var current = list_val;
    while (idx > 0) : (idx -= 1) {
        try tick(interp, fuel);
        if (current != .pair) return interp.fail(ElzError.InvalidArgument, "list-ref: expected a pair, got {s}", .{core.typeName(current)});
        current = current.pair.cdr;
    }
    if (current != .pair) return interp.fail(ElzError.InvalidArgument, "list-ref: expected a pair, got {s}", .{core.typeName(current)});
    return current.pair.car;
}

/// `list_tail` returns the sublist of a list starting at position k.
/// Syntax: (list-tail list k)
pub fn list_tail(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const list_val = args.items[0];
    var idx = try toIndex(args.items[1]);
    var current = list_val;
    while (idx > 0) : (idx -= 1) {
        try tick(interp, fuel);
        if (current != .pair) return interp.fail(ElzError.InvalidArgument, "list-tail: expected a pair, got {s}", .{core.typeName(current)});
        current = current.pair.cdr;
    }
    return current;
}

/// `memq` returns the first sublist whose car is eq? to obj, or #f.
/// Syntax: (memq obj list)
pub fn memq(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const obj = args.items[0];
    var current = args.items[1];

    while (current != .nil) {
        try tick(interp, fuel);
        if (current != .pair) return interp.fail(ElzError.InvalidArgument, "memq: expected a pair, got {s}", .{core.typeName(current)});
        const p = current.pair;
        // eq? comparison - pointer/value equality
        if (eqCheck(obj, p.car)) {
            return current;
        }
        current = p.cdr;
    }
    return Value{ .boolean = false };
}

/// Helper for eq? check: `eq?` and `eqv?` coincide in this implementation, so
/// procedures, strings, and other heap objects compare by identity here too.
fn eqCheck(a: Value, b: Value) bool {
    return predicates.is_eqv_internal(a, b);
}

/// `assq` returns the first pair in alist whose car is eq? to obj, or #f.
/// Syntax: (assq obj alist)
pub fn assq(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, fuel: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const obj = args.items[0];
    var current = args.items[1];

    while (current != .nil) {
        try tick(interp, fuel);
        if (current != .pair) return interp.fail(ElzError.InvalidArgument, "assq: expected a pair, got {s}", .{core.typeName(current)});
        const p = current.pair;
        if (p.car != .pair) return ElzError.InvalidArgument;
        if (eqCheck(obj, p.car.pair.car)) {
            return p.car;
        }
        current = p.cdr;
    }
    return Value{ .boolean = false };
}

/// `is_pair` checks if a value is a pair.
/// Syntax: (pair? obj)
pub fn is_pair(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .pair };
}

/// `set_car` modifies the car of a pair.
/// Syntax: (set-car! pair obj)
pub fn set_car(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const p = args.items[0];
    if (p != .pair) return interp.fail(ElzError.InvalidArgument, "set-car!: expected a pair, got {s}", .{core.typeName(p)});
    p.pair.car = args.items[1];
    return Value.unspecified;
}

/// `list_set_bang` stores a value in element k of a list, in place.
/// Syntax: (list-set! list k obj)
pub fn list_set_bang(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;
    if (args.items[1] != .exact_integer or args.items[1].exact_integer < 0) return ElzError.InvalidArgument;
    var cur = args.items[0];
    var k = args.items[1].exact_integer;
    while (k > 0) : (k -= 1) {
        if (cur != .pair) return interp.fail(ElzError.InvalidArgument, "list-set!: expected a pair, got {s}", .{core.typeName(cur)});
        cur = cur.pair.cdr;
    }
    if (cur != .pair) return interp.fail(ElzError.InvalidArgument, "list-set!: expected a pair, got {s}", .{core.typeName(cur)});
    cur.pair.car = args.items[2];
    return Value.unspecified;
}

/// `set_cdr` modifies the cdr of a pair.
/// Syntax: (set-cdr! pair obj)
pub fn set_cdr(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    const p = args.items[0];
    if (p != .pair) return interp.fail(ElzError.InvalidArgument, "set-cdr!: expected a pair, got {s}", .{core.typeName(p)});
    p.pair.cdr = args.items[1];
    return Value.unspecified;
}

test "list primitives" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // Test list
    var args = core.ValueList.init(interp.allocator);
    try args.append(Value{ .exact_integer = 1 });
    try args.append(Value{ .exact_integer = 2 });
    const list_val = try list(&interp, interp.root_env, args, &fuel);
    try testing.expect(list_val.pair.car == .exact_integer);
    try testing.expectEqual(@as(i64, 1), list_val.pair.car.exact_integer);
    try testing.expect(list_val.pair.cdr.pair.car == .exact_integer);
    try testing.expectEqual(@as(i64, 2), list_val.pair.cdr.pair.car.exact_integer);

    // Test cons
    args.clearRetainingCapacity();
    try args.append(Value{ .exact_integer = 0 });
    try args.append(list_val);
    const new_list = try cons(&interp, interp.root_env, args, &fuel);
    try testing.expect(new_list.pair.car == .exact_integer and new_list.pair.car.exact_integer == 0);

    // Test car
    args.clearRetainingCapacity();
    try args.append(new_list);
    const car_val = try car(&interp, interp.root_env, args, &fuel);
    try testing.expect(car_val == .exact_integer and car_val.exact_integer == 0);

    // Test cdr
    args.clearRetainingCapacity();
    try args.append(new_list);
    const cdr_val = try cdr(&interp, interp.root_env, args, &fuel);
    try testing.expect(cdr_val.pair.car == .exact_integer and cdr_val.pair.car.exact_integer == 1);

    // Test list-length
    args.clearRetainingCapacity();
    try args.append(new_list);
    const len_val = try list_length(&interp, interp.root_env, args, &fuel);
    try testing.expect(len_val == .exact_integer and len_val.exact_integer == 3);

    // Test reverse
    args.clearRetainingCapacity();
    try args.append(list_val);
    const reversed_list = try reverse(&interp, interp.root_env, args, &fuel);
    try testing.expect(reversed_list.pair.car == .exact_integer and reversed_list.pair.car.exact_integer == 2);
    try testing.expect(reversed_list.pair.cdr.pair.car == .exact_integer and reversed_list.pair.cdr.pair.car.exact_integer == 1);

    // Test append
    args.clearRetainingCapacity();
    try args.append(list_val);
    try args.append(reversed_list);
    const appended_list = try append(&interp, interp.root_env, args, &fuel);
    try testing.expect(appended_list.pair.car == .exact_integer and appended_list.pair.car.exact_integer == 1);
    try testing.expect(appended_list.pair.cdr.pair.car == .exact_integer and appended_list.pair.cdr.pair.car.exact_integer == 2);
    try testing.expect(appended_list.pair.cdr.pair.cdr.pair.car == .exact_integer and appended_list.pair.cdr.pair.cdr.pair.car.exact_integer == 2);
    try testing.expect(appended_list.pair.cdr.pair.cdr.pair.cdr.pair.car == .exact_integer and appended_list.pair.cdr.pair.cdr.pair.cdr.pair.car.exact_integer == 1);

    // Test map
    const proc_val = try interp.evalString("(lambda (x) (* x 2))", &fuel);
    args.clearRetainingCapacity();
    try args.append(proc_val);
    try args.append(list_val);
    const mapped_list = try map(&interp, interp.root_env, args, &fuel);
    try testing.expect(mapped_list.pair.car == .exact_integer and mapped_list.pair.car.exact_integer == 2);
    try testing.expect(mapped_list.pair.cdr.pair.car == .exact_integer and mapped_list.pair.cdr.pair.car.exact_integer == 4);
}
