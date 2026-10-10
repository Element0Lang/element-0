//! A precise, non-moving heap for the next GC integration step.
//! The caller owns the memory and must keep the heap and registered roots at
//! stable addresses. Collection is manual and never allocates. Tracing callbacks
//! may only mark pointers returned by this heap, and must describe every edge.

const std = @import("std");
const assert = std.debug.assert;

pub const Heap = struct {
    memory: []u8,
    first: *Block,
    roots: ?*Root = null,
    pending: ?*Block = null,
    collecting: bool = false,
    /// Occupied block bytes, including headers, alignment, and unsplit tails.
    bytes_used: usize = 0,
    object_count: usize = 0,

    const Block = struct {
        next: ?*Block = null,
        size: usize,
        owner: ?*Heap = null,
        payload_offset: usize = 0,
        trace: ?*const fn (*Block, *Visitor) void = null,
        pending_next: ?*Block = null,
        marked: bool = false,
    };

    const block_alignment = @alignOf(Block);
    const minimum_block_size = @sizeOf(Block) + @sizeOf(*Block);

    /// A root keeps one object and its reachable graph alive. Register the root
    /// after placing it at its final address, then remove it before its scope ends.
    pub const Root = struct {
        heap: ?*Heap = null,
        next: ?*Root = null,
        value: ?*const anyopaque = null,

        /// Changes the protected object. Null protects no object.
        pub fn set(self: *Root, value: ?*const anyopaque) void {
            const heap = self.heap.?;
            assert(!heap.collecting);
            if (value) |ptr| _ = heap.block_for(ptr);
            self.value = value;
        }

        pub fn deinit(self: *Root) void {
            const heap = self.heap.?;
            assert(!heap.collecting);
            var link = &heap.roots;
            while (link.* != self) link = &link.*.?.next;
            link.* = self.next;
            self.* = .{};
        }
    };

    pub const Visitor = struct {
        heap: *Heap,

        /// Marks an exact object pointer from this heap. Null is ignored.
        pub fn mark(self: *Visitor, value: ?*const anyopaque) void {
            const block = self.heap.block_for(value orelse return);
            if (block.marked) return;
            block.marked = true;
            block.pending_next = self.heap.pending;
            self.heap.pending = block;
        }
    };

    /// Uses only this region. Leading and trailing bytes needed to align the
    /// block headers are excluded from `memory` and its usable capacity.
    pub fn init(memory: []u8) error{OutOfMemory}!Heap {
        const start = std.mem.alignForward(usize, @intFromPtr(memory.ptr), block_alignment);
        const end = std.mem.alignBackward(usize, @intFromPtr(memory.ptr) + memory.len, block_alignment);
        if (end < start or end - start < minimum_block_size) return error.OutOfMemory;
        const first: *Block = @ptrFromInt(start);
        first.* = .{ .size = end - start };
        return .{ .memory = @as([*]u8, @ptrFromInt(start))[0 .. end - start], .first = first };
    }

    /// Allocates and initializes one object. Null tracing is for objects without
    /// managed references. Allocation never collects, so native temporaries stay
    /// valid until the caller explicitly calls `collect`.
    pub fn create(
        self: *Heap,
        comptime T: type,
        value: T,
        comptime trace: ?*const fn (*const T, *Visitor) void,
    ) error{OutOfMemory}!*T {
        const block = try self.allocate(@sizeOf(T), @alignOf(T));
        const object: *T = @ptrFromInt(@intFromPtr(block) + block.payload_offset);
        object.* = value;
        block.trace = if (trace) |trace_fn| struct {
            fn visit(current: *Block, visitor: *Visitor) void {
                const ptr: *const T = @ptrFromInt(@intFromPtr(current) + current.payload_offset);
                trace_fn(ptr, visitor);
            }
        }.visit else null;
        return object;
    }

    /// Allocates storage without tracing its contents. Use `create` for objects
    /// with references, and mark nonempty buffer base pointers from their owner.
    /// Frees are ignored. Reallocated buffers must be rooted at their new address.
    pub fn allocator(self: *Heap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = raw_alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = std.mem.Allocator.noFree,
        } };
    }

    fn raw_alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        const block = self.allocate(len, alignment.toByteUnits()) catch return null;
        return @ptrFromInt(@intFromPtr(block) + block.payload_offset);
    }

    fn allocate(self: *Heap, len: usize, alignment: usize) error{OutOfMemory}!*Block {
        assert(!self.collecting);
        const payload_alignment = @max(alignment, @alignOf(*Block));
        var cursor: ?*Block = self.first;
        while (cursor) |block| : (cursor = block.next) {
            if (block.owner != null) continue;
            const base = @intFromPtr(block);
            const payload = std.mem.alignForward(usize, base + minimum_block_size, payload_alignment);
            const offset = payload - base;
            if (offset > block.size or len > block.size - offset) continue;
            const required = std.mem.alignForward(usize, offset + len, block_alignment);
            if (required > block.size) continue;

            if (block.size - required >= minimum_block_size) {
                const remainder: *Block = @ptrFromInt(base + required);
                remainder.* = .{ .size = block.size - required, .next = block.next };
                block.next = remainder;
                block.size = required;
            }
            const prefix: **Block = @ptrFromInt(payload - @sizeOf(*Block));
            prefix.* = block;
            block.owner = self;
            block.payload_offset = offset;
            self.bytes_used += block.size;
            self.object_count += 1;
            return block;
        }
        return error.OutOfMemory;
    }

    pub fn add_root(self: *Heap, root: *Root, value: ?*const anyopaque) void {
        assert(!self.collecting);
        assert(root.heap == null);
        if (value) |ptr| _ = self.block_for(ptr);
        root.* = .{ .heap = self, .next = self.roots, .value = value };
        self.roots = root;
    }

    /// Traces roots and reachable objects, then reclaims and coalesces free
    /// blocks. The intrusive worklist needs no separate marking allocation.
    pub fn collect(self: *Heap) void {
        assert(!self.collecting);
        self.collecting = true;
        defer self.collecting = false;
        var visitor = Visitor{ .heap = self };
        var root_cursor = self.roots;
        while (root_cursor) |root| : (root_cursor = root.next) visitor.mark(root.value);
        while (self.pending) |block| {
            self.pending = block.pending_next;
            block.pending_next = null;
            if (block.trace) |trace| trace(block, &visitor);
        }

        var cursor: ?*Block = self.first;
        while (cursor) |block| : (cursor = block.next) {
            if (block.owner != null) {
                if (block.marked) {
                    block.marked = false;
                } else {
                    self.bytes_used -= block.size;
                    self.object_count -= 1;
                    block.owner = null;
                    block.trace = null;
                    block.payload_offset = 0;
                }
            }
        }
        cursor = self.first;
        while (cursor) |block| {
            if (block.owner == null) {
                if (block.next) |next| {
                    if (next.owner == null) {
                        block.size += next.size;
                        block.next = next.next;
                        continue;
                    }
                }
            }
            cursor = block.next;
        }
    }

    fn block_for(self: *Heap, ptr: *const anyopaque) *Block {
        const address = @intFromPtr(ptr);
        const start = @intFromPtr(self.memory.ptr);
        assert(address >= start + minimum_block_size and address <= start + self.memory.len);
        assert(std.mem.isAligned(address, @alignOf(*Block)));
        const prefix: *const *Block = @ptrFromInt(address - @sizeOf(*Block));
        const block = prefix.*;
        assert(block.owner == self);
        assert(@intFromPtr(block) + block.payload_offset == address);
        return block;
    }
};

const TestNode = struct {
    value: usize,
    left: ?*TestNode = null,
    right: ?*TestNode = null,

    fn trace(self: *const TestNode, visitor: *Heap.Visitor) void {
        visitor.mark(self.left);
        visitor.mark(self.right);
    }
};

test "reachable graphs survive and unreachable cycles are reclaimed" {
    var memory: [4096]u8 = undefined;
    var heap = try Heap.init(&memory);
    const child = try heap.create(TestNode, .{ .value = 1 }, TestNode.trace);
    const parent = try heap.create(TestNode, .{ .value = 2, .left = child, .right = child }, TestNode.trace);
    child.left = parent;
    var root: Heap.Root = .{};
    heap.add_root(&root, parent);
    defer root.deinit();

    const used = heap.bytes_used;
    heap.collect();
    heap.collect();
    try std.testing.expectEqual(@as(usize, 2), heap.object_count);
    try std.testing.expectEqual(used, heap.bytes_used);
    try std.testing.expectEqual(@as(usize, 1), parent.left.?.value);

    root.set(null);
    heap.collect();
    try std.testing.expectEqual(@as(usize, 0), heap.object_count);
    try std.testing.expectEqual(@as(usize, 0), heap.bytes_used);
}

test "roots can change and be removed in any order" {
    var memory: [4096]u8 = undefined;
    var heap = try Heap.init(&memory);
    const first = try heap.create(u32, 10, null);
    const second = try heap.create(u32, 20, null);
    var a: Heap.Root = .{};
    var b: Heap.Root = .{};
    var c: Heap.Root = .{};
    heap.add_root(&a, first);
    heap.add_root(&b, second);
    heap.add_root(&c, null);
    b.deinit();
    a.set(second);
    heap.collect();
    try std.testing.expectEqual(@as(usize, 1), heap.object_count);
    try std.testing.expectEqual(@as(u32, 20), second.*);
    a.deinit();
    c.deinit();
    heap.collect();
    try std.testing.expectEqual(@as(usize, 0), heap.object_count);
    try std.testing.expect(heap.roots == null);
}

test "exhaustion preserves roots and collection makes space reusable" {
    var memory: [1024]u8 = undefined;
    var heap = try Heap.init(&memory);
    const kept = try heap.create(u32, 42, null);
    var root: Heap.Root = .{};
    heap.add_root(&root, kept);
    defer root.deinit();
    while (true) {
        _ = heap.create([32]u8, @splat(0), null) catch break;
    }
    const used = heap.bytes_used;
    try std.testing.expectError(error.OutOfMemory, heap.create([1024]u8, @splat(0), null));
    try std.testing.expectEqual(used, heap.bytes_used);
    heap.collect();
    try std.testing.expectEqual(@as(u32, 42), kept.*);
    _ = try heap.create([512]u8, @splat(0), null);
    try std.testing.expect(heap.bytes_used <= heap.memory.len);
}

test "adjacent swept blocks coalesce around a live object" {
    var memory: [4096]u8 = undefined;
    var heap = try Heap.init(&memory);
    _ = try heap.create([128]u8, @splat(0), null);
    const middle = try heap.create(u8, 7, null);
    _ = try heap.create([128]u8, @splat(0), null);
    var root: Heap.Root = .{};
    heap.add_root(&root, middle);
    heap.collect();
    try std.testing.expectEqual(@as(u8, 7), middle.*);
    root.deinit();
    heap.collect();
    try std.testing.expect(heap.first.next == null);
    _ = try heap.create([3000]u8, @splat(0), null);
}

test "overaligned objects and unaligned heap regions" {
    const Aligned = struct { bytes: [33]u8 align(256) };
    var memory: [4097]u8 align(256) = undefined;
    var heap = try Heap.init(memory[1..]);
    const object = try heap.create(Aligned, .{ .bytes = @splat(9) }, null);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(object), 256));
    var root: Heap.Root = .{};
    heap.add_root(&root, object);
    defer root.deinit();
    heap.collect();
    try std.testing.expectEqual(@as(u8, 9), object.bytes[32]);
}

test "small regions fail and zero sized objects are distinct" {
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.OutOfMemory, Heap.init(&tiny));
    var memory: [1024]u8 = undefined;
    var heap = try Heap.init(&memory);
    const first = try heap.create(struct {}, .{}, null);
    const second = try heap.create(struct {}, .{}, null);
    try std.testing.expect(@intFromPtr(first) != @intFromPtr(second));
    heap.collect();
    try std.testing.expectEqual(@as(usize, 0), heap.object_count);
}

test "deep graphs use a worklist and repeated allocation stays bounded" {
    var memory: [512 * 1024]u8 = undefined;
    var heap = try Heap.init(&memory);
    var root: Heap.Root = .{};
    heap.add_root(&root, null);
    defer root.deinit();
    var head: ?*TestNode = null;
    for (0..4000) |i| head = try heap.create(TestNode, .{ .value = i, .left = head }, TestNode.trace);
    root.set(head);
    heap.collect();
    try std.testing.expectEqual(@as(usize, 4000), heap.object_count);
    root.set(null);
    heap.collect();
    for (0..1000) |i| {
        const node = try heap.create(TestNode, .{ .value = i }, TestNode.trace);
        root.set(node);
        heap.collect();
        try std.testing.expectEqual(@as(usize, 1), heap.object_count);
        try std.testing.expectEqual(i, node.value);
    }
}

test "allocator buffers are traced by their owner and reallocations can be rooted" {
    const Buffer = struct {
        bytes: []u8,

        fn trace(self: *const @This(), visitor: *Heap.Visitor) void {
            if (self.bytes.len != 0) visitor.mark(self.bytes.ptr);
        }
    };
    var memory: [4096]u8 = undefined;
    var heap = try Heap.init(&memory);
    const allocator = heap.allocator();
    const buffer = try heap.create(Buffer, .{ .bytes = try allocator.dupe(u8, "hello") }, Buffer.trace);
    var root: Heap.Root = .{};
    heap.add_root(&root, buffer);
    defer root.deinit();
    heap.collect();
    try std.testing.expectEqualStrings("hello", buffer.bytes);
    try std.testing.expectEqual(@as(usize, 2), heap.object_count);

    buffer.bytes = try allocator.realloc(buffer.bytes, 32);
    heap.collect();
    try std.testing.expectEqualStrings("hello", buffer.bytes[0..5]);
    try std.testing.expectEqual(@as(usize, 2), heap.object_count);
    allocator.free(buffer.bytes);
    root.set(null);
    heap.collect();
    try std.testing.expectEqual(@as(usize, 0), heap.bytes_used);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
}

test "separate heaps have independent roots and capacity" {
    var first_memory: [1024]u8 = undefined;
    var second_memory: [1024]u8 = undefined;
    var first = try Heap.init(&first_memory);
    var second = try Heap.init(&second_memory);
    const kept = try first.create(u32, 42, null);
    _ = try second.create(u32, 7, null);
    var root: Heap.Root = .{};
    first.add_root(&root, kept);
    defer root.deinit();
    second.collect();
    first.collect();
    try std.testing.expectEqual(@as(usize, 0), second.object_count);
    try std.testing.expectEqual(@as(usize, 1), first.object_count);
    try std.testing.expectEqual(@as(u32, 42), kept.*);
}

test "allocation and sweeping stay within the supplied region" {
    var guarded: [1026]u8 = @splat(0xa5);
    var heap = try Heap.init(guarded[1 .. guarded.len - 1]);
    for (0..10) |_| {
        while (true) {
            _ = heap.create([17]u8, @splat(0), null) catch break;
        }
        heap.collect();
    }
    try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), guarded[guarded.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), heap.bytes_used);
}
