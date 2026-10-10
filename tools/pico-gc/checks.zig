const std = @import("std");
const Heap = @import("managed_heap").Heap;

extern fn gc_report(name: [*]const u8, len: usize, status: c_int) void;
extern fn gc_panic(message: [*]const u8, len: usize) noreturn;

pub const panic = std.debug.FullPanic(panic_handler);

fn panic_handler(message: []const u8, _: ?usize) noreturn {
    gc_panic(message.ptr, message.len);
}

var memory: [128 * 1024]u8 align(256) = undefined;

const Node = struct {
    value: usize = 0,
    next: ?*Node = null,

    fn trace(self: *const Node, visitor: *Heap.Visitor) void {
        visitor.mark(self.next);
    }
};

fn check(ok: bool) error{CheckFailed}!void {
    if (!ok) return error.CheckFailed;
}

fn cycles() !void {
    var heap = try Heap.init(&memory);
    const a = try heap.create(Node, .{ .value = 42 }, Node.trace);
    const b = try heap.create(Node, .{ .next = a }, Node.trace);
    a.next = b;
    var root: Heap.Root = .{};
    heap.add_root(&root, a);
    defer root.deinit();
    heap.collect();
    heap.collect();
    try check(heap.object_count == 2 and b.next.?.value == 42);
    root.set(null);
    heap.collect();
    try check(heap.object_count == 0 and heap.bytes_used == 0);
}

fn roots() !void {
    var heap = try Heap.init(&memory);
    const a = try heap.create(u32, 10, null);
    const b = try heap.create(u32, 20, null);
    var first: Heap.Root = .{};
    var second: Heap.Root = .{};
    var third: Heap.Root = .{};
    heap.add_root(&first, a);
    heap.add_root(&second, b);
    heap.add_root(&third, null);
    second.deinit();
    first.set(b);
    heap.collect();
    try check(heap.object_count == 1 and b.* == 20);
    first.deinit();
    third.deinit();
    heap.collect();
    try check(heap.object_count == 0 and heap.roots == null);
}

fn exhaustion() !void {
    var heap = try Heap.init(&memory);
    const kept = try heap.create(u32, 42, null);
    var root: Heap.Root = .{};
    heap.add_root(&root, kept);
    defer root.deinit();
    while (true) _ = heap.create([128]u8, @splat(0), null) catch break;
    const used = heap.bytes_used;
    if (heap.allocator().alloc(u8, memory.len)) |_| {
        return error.CheckFailed;
    } else |err| try check(err == error.OutOfMemory);
    try check(heap.bytes_used == used);
    heap.collect();
    try check(kept.* == 42 and heap.object_count == 1);
    _ = try heap.allocator().alloc(u8, 4096);
    try check(heap.bytes_used <= memory.len);
}

fn coalescing() !void {
    var heap = try Heap.init(&memory);
    _ = try heap.create([128]u8, @splat(0), null);
    const middle = try heap.create(u8, 7, null);
    _ = try heap.create([128]u8, @splat(0), null);
    var root: Heap.Root = .{};
    heap.add_root(&root, middle);
    heap.collect();
    try check(middle.* == 7);
    root.deinit();
    heap.collect();
    _ = try heap.allocator().alloc(u8, 120 * 1024);
}

fn alignment() !void {
    const Aligned = struct { bytes: [33]u8 align(256) };
    var heap = try Heap.init(memory[1..]);
    const object = try heap.create(Aligned, .{ .bytes = @splat(9) }, null);
    try check(std.mem.isAligned(@intFromPtr(object), 256));
    var root: Heap.Root = .{};
    heap.add_root(&root, object);
    defer root.deinit();
    heap.collect();
    try check(object.bytes[32] == 9);
}

fn buffers() !void {
    const Buffer = struct {
        bytes: []u8,

        fn trace(self: *const @This(), visitor: *Heap.Visitor) void {
            if (self.bytes.len != 0) visitor.mark(self.bytes.ptr);
        }
    };
    var heap = try Heap.init(&memory);
    const allocator = heap.allocator();
    const owner = try heap.create(Buffer, .{ .bytes = try allocator.dupe(u8, "hello") }, Buffer.trace);
    var root: Heap.Root = .{};
    heap.add_root(&root, owner);
    defer root.deinit();
    heap.collect();
    try check(std.mem.eql(u8, owner.bytes, "hello") and heap.object_count == 2);
    owner.bytes = try allocator.realloc(owner.bytes, 64);
    heap.collect();
    try check(std.mem.eql(u8, owner.bytes[0..5], "hello") and heap.object_count == 2);
    root.set(null);
    heap.collect();
    try check(heap.bytes_used == 0);
}

fn deep_graph() !void {
    var heap = try Heap.init(&memory);
    var root: Heap.Root = .{};
    heap.add_root(&root, null);
    defer root.deinit();
    var head: ?*Node = null;
    for (0..1500) |i| head = try heap.create(Node, .{ .value = i, .next = head }, Node.trace);
    root.set(head);
    heap.collect();
    try check(heap.object_count == 1500 and head.?.value == 1499);
    root.set(null);
    heap.collect();
    try check(heap.bytes_used == 0);
}

fn bounded_stress() !void {
    var heap = try Heap.init(&memory);
    var root: Heap.Root = .{};
    heap.add_root(&root, null);
    defer root.deinit();
    for (0..10000) |i| {
        const node = try heap.create(Node, .{ .value = i }, Node.trace);
        root.set(node);
        heap.collect();
        try check(heap.object_count == 1 and node.value == i and heap.bytes_used < 256);
    }
}

fn bounds() !void {
    @memset(&memory, 0xa5);
    var heap = try Heap.init(memory[1 .. memory.len - 1]);
    for (0..3) |_| {
        while (true) _ = heap.create([128]u8, @splat(0), null) catch break;
        heap.collect();
    }
    try check(memory[0] == 0xa5 and memory[memory.len - 1] == 0xa5);
    try check(heap.bytes_used == 0);
}

export fn gc_run_tests() c_int {
    const Case = struct { name: []const u8, run: *const fn () anyerror!void };
    const cases = [_]Case{
        .{ .name = "cycles", .run = cycles },
        .{ .name = "roots", .run = roots },
        .{ .name = "exhaustion", .run = exhaustion },
        .{ .name = "coalescing", .run = coalescing },
        .{ .name = "alignment", .run = alignment },
        .{ .name = "buffers", .run = buffers },
        .{ .name = "deep_graph", .run = deep_graph },
        .{ .name = "bounded_stress", .run = bounded_stress },
        .{ .name = "bounds", .run = bounds },
    };
    var failures: c_int = 0;
    for (cases) |case| {
        gc_report(case.name.ptr, case.name.len, -1);
        case.run() catch |err| {
            failures += 1;
            const name = @errorName(err);
            gc_report(name.ptr, name.len, 1);
            continue;
        };
        gc_report(case.name.ptr, case.name.len, 0);
    }
    return failures;
}
