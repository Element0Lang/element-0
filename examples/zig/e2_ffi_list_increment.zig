const std = @import("std");
const elz = @import("elz");

fn increment_list_elements(allocator: std.mem.Allocator, args: []const elz.Value) !elz.Value {
    if (args.len != 1) {
        return elz.ElzError.WrongArgumentCount;
    }
    const list_head = args[0];
    if (list_head != .pair and list_head != .nil) {
        return elz.ElzError.InvalidArgument;
    }
    var numbers = std.ArrayListUnmanaged(f64).empty;
    defer numbers.deinit(allocator);
    var current_node = list_head;
    while (current_node != .nil) {
        switch (current_node) {
            .pair => |p| {
                switch (p.car) {
                    .number => |n| try numbers.append(allocator, n),
                    else => return elz.ElzError.InvalidArgument,
                }
                current_node = p.cdr;
            },
            else => return elz.ElzError.InvalidArgument,
        }
    }
    for (numbers.items) |*n| {
        n.* += 1.0;
    }
    if (numbers.items.len == 0) {
        return elz.Value.nil;
    }
    const head_pair = try allocator.create(elz.core.Pair);
    head_pair.* = .{
        .car = elz.Value{ .number = numbers.items[0] },
        .cdr = elz.Value.nil,
    };
    const new_list_head = elz.Value{ .pair = head_pair };
    var tail_pair = head_pair;
    for (numbers.items[1..]) |num| {
        const next_pair = try allocator.create(elz.core.Pair);
        next_pair.* = .{
            .car = elz.Value{ .number = num },
            .cdr = elz.Value.nil,
        };
        tail_pair.cdr = elz.Value{ .pair = next_pair };
        tail_pair = next_pair;
    }
    return new_list_head;
}

pub fn main() !void {
    var interpreter = try elz.Interpreter.init(.{});
    try elz.define_foreign_func(interpreter.root_env, "increment-list", increment_list_elements);
    const source = "(increment-list (quote (10 20 30)))";
    std.debug.print("Evaluating Element 0 code: {s}\n", .{source});
    var fuel: u64 = 1000;
    const result = try interpreter.evalString(source, &fuel);
    var buffer: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("Result: ");
    try elz.write(result, stdout);
    try stdout.writeAll("\n");
    try stdout.flush();
}
