const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

/// WebAssembly has no way to scan the native stack, which the Boehm collector
/// depends on, so wasm builds fall back to an arena that never frees. Scripts
/// that run to completion work unchanged; a long-lived interpreter grows
/// without bound until `deinit`.
pub const uses_arena = builtin.cpu.arch.isWasm();

/// The Boehm collector's C API. Only present in native builds.
pub const c = if (uses_arena) struct {} else @cImport({
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

const GcAllocator = struct {
    vtable: mem.Allocator.VTable = .{
        .alloc = gcAlloc,
        .resize = gcResize,
        .remap = gcRemap,
        .free = gcFree,
    },
};

var gc_allocator_instance = GcAllocator{};

/// The arena behind wasm builds. Frees are ignored, matching the collector's
/// allocator contract, and the memory comes back only at `deinit`.
var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn arenaAlloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    return arena_instance.allocator().rawAlloc(len, alignment, ret_addr);
}

fn arenaResize(ctx: *anyopaque, buf: []u8, buf_align: mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    return arena_instance.allocator().rawResize(buf, buf_align, new_len, ret_addr);
}

fn arenaRemap(ctx: *anyopaque, buf: []u8, buf_align: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    return arena_instance.allocator().rawRemap(buf, buf_align, new_len, ret_addr);
}

var arena_vtable: mem.Allocator.VTable = .{
    .alloc = arenaAlloc,
    .resize = arenaResize,
    .remap = arenaRemap,
    .free = gcFree,
};

/// Allocates memory that is not subject to garbage collection.
pub fn allocUncollectable(len: usize) ?*anyopaque {
    if (uses_arena) {
        const bytes = arena_instance.allocator().alignedAlloc(u8, .@"16", len) catch return null;
        return @ptrCast(bytes.ptr);
    }
    return c.GC_malloc_uncollectable(len);
}

/// A `std.mem.Allocator` whose memory is reclaimed by the collector. Values,
/// environments, and everything else a script can reach are allocated here.
/// On wasm this is the arena described above.
pub const allocator: mem.Allocator = if (uses_arena) .{
    .ptr = &arena_instance,
    .vtable = &arena_vtable,
} else .{
    .ptr = &gc_allocator_instance,
    .vtable = &gc_allocator_instance.vtable,
};

/// Initializes the garbage collector.
pub fn init() void {
    if (uses_arena) return;
    c.GC_init();
    // Enable recognition of all interior pointers to ensure HashMap internals are scanned
    c.GC_set_all_interior_pointers(1);
}

/// Adds a memory region to the set of roots for garbage collection. A no-op
/// under the arena, which never collects.
pub fn add_roots(start: usize, end: usize) void {
    if (uses_arena) return;
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

        /// Resets the list to empty without releasing the backing allocation. Mirrors the
        /// `std.ArrayList` method of the same name.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.items = self.items.ptr[0..0];
        }
    };
}
