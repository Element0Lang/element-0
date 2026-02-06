const std = @import("std");
const mem = std.mem;

pub const c = @cImport({
    @cInclude("gc.h");
});

fn gcAlloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    _ = ctx;
    // Use GC_memalign for proper alignment, but ensure it's configured to scan.
    const res = c.GC_memalign(mem.Alignment.toByteUnits(alignment), len);
    if (res == null) return null;
    return @ptrCast(res);
}

fn gcResize(ctx: *anyopaque, buf: []u8, buf_align: mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    return false;
}

fn gcRemap(ctx: *anyopaque, buf: []u8, buf_align: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn gcFree(ctx: *anyopaque, buf: []u8, buf_align: mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = ret_addr;
}

/// Allocates memory that is not subject to garbage collection.
pub fn allocUncollectable(len: usize) ?*anyopaque {
    return c.GC_malloc_uncollectable(len);
}

const GcAllocator = struct {
    vtable: mem.Allocator.VTable = .{
        .alloc = gcAlloc,
        .resize = gcResize,
        .remap = gcRemap,
        .free = gcFree,
    },
};

var gc_allocator_instance = GcAllocator{};

/// A `std.mem.Allocator` that uses the Boehm-Demers-Weiser garbage collector.
/// All memory allocated with this allocator is subject to garbage collection.
pub const allocator: mem.Allocator = .{
    .ptr = &gc_allocator_instance,
    .vtable = &gc_allocator_instance.vtable,
};

/// Initializes the garbage collector.
pub fn init() void {
    c.GC_init();
    // Enable recognition of all interior pointers to ensure HashMap internals are scanned
    c.GC_set_all_interior_pointers(1);
}

/// Adds a memory region to the set of roots for garbage collection.
pub fn add_roots(start: usize, end: usize) void {
    c.GC_add_roots(@ptrFromInt(start), @ptrFromInt(end));
}

/// `GcArrayList` is a generic struct that provides a dynamic array.
/// It uses the C allocator.
pub fn GcArrayList(comptime T: type) type {
    return struct {
        items: []T,
        capacity: usize,
        allocator: mem.Allocator,

        const Self = @This();

        /// Initializes a new `GcArrayList`.
        pub fn init(alloc: mem.Allocator) Self {
            return .{
                .items = &[_]T{},
                .capacity = 0,
                .allocator = alloc,
            };
        }

        /// Appends an item to the end of the array.
        pub fn append(self: *Self, item: T) !void {
            if (self.items.len == self.capacity) {
                const new_capacity = if (self.capacity == 0) 4 else self.capacity * 2;
                const old_mem = self.items.ptr[0..self.capacity];
                const new_mem = try self.allocator.realloc(old_mem, new_capacity);
                self.items.ptr = new_mem.ptr;
                self.capacity = new_capacity;
            }
            // Extend the slice to include the new item
            self.items = self.items.ptr[0 .. self.items.len + 1];
            self.items[self.items.len - 1] = item;
        }

        /// Gets the item at the specified index.
        pub fn get(self: Self, index: usize) T {
            return self.items[index];
        }

        /// Sets the item at the specified index.
        pub fn set(self: Self, index: usize, value: T) void {
            self.items[index] = value;
        }

        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.items.ptr[0..self.capacity]);
            }
        }
    };
}
