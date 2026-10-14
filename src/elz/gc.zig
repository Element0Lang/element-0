const std = @import("std");
const mem = std.mem;
const core = @import("core.zig");
const Interpreter = @import("interpreter.zig").Interpreter;
const VM = @import("vm.zig").VM;
const Heap = @import("managed_heap.zig").Heap;

/// A native root describes a typed Zig local. Keep both at stable addresses
/// until `deinit`, and keep the interpreter alive for the whole root scope.
pub const Root = struct {
    state: ?*State = null,
    next: ?*Root = null,
    context: *const anyopaque = undefined,
    trace: *const fn (*const anyopaque, *Heap.Visitor) void = undefined,

    pub fn deinit(self: *Root) void {
        const state = self.state.?;
        var link = &state.roots;
        while (link.* != self) link = &link.*.?.next;
        link.* = self.next;
        self.* = .{};
    }
};

/// Each interpreter owns one precise heap, including its marking worklist.
pub const State = struct {
    heap: Heap,
    memory: []u8,
    roots: ?*Root = null,
    // Weak references keep file handles available for cleanup without retaining ports.
    file_ports: std.ArrayList(*core.Port) = .empty,
    paused: usize = 0,
    next_collection: usize = 1024 * 1024,
    collections: usize = 0,
    collect_every_instruction: bool = false,

    pub fn init(limit: usize) !*State {
        const backing = std.heap.page_allocator;
        const state = try backing.create(State);
        errdefer backing.destroy(state);
        const memory = try backing.alloc(u8, limit);
        errdefer backing.free(memory);
        state.* = .{ .heap = try Heap.init(memory), .memory = memory };
        return state;
    }

    pub fn deinit(self: *State) void {
        std.debug.assert(self.roots == null);
        for (self.file_ports.items) |port| port.close();
        self.file_ports.deinit(std.heap.page_allocator);
        std.heap.page_allocator.free(self.memory);
        std.heap.page_allocator.destroy(self);
    }

    pub fn protect(self: *State, root: *Root, ptr: anytype) void {
        const T = @typeInfo(@TypeOf(ptr)).pointer.child;
        std.debug.assert(root.state == null);
        root.* = .{ .state = self, .next = self.roots, .context = @ptrCast(ptr), .trace = struct {
            fn trace(context: *const anyopaque, visitor: *Heap.Visitor) void {
                const value: *const T = @ptrCast(@alignCast(context));
                visitor.mark_buffer(context);
                visit(value.*, visitor);
            }
        }.trace };
        self.roots = root;
    }

    pub fn collect(self: *State, interp: *Interpreter) void {
        std.debug.assert(self.paused == 0);
        self.heap.collect_with_roots(interp, trace_interpreter);
        // Sweep leaves payload bytes intact until the next allocation.
        var port_index: usize = 0;
        while (port_index < self.file_ports.items.len) {
            const port = self.file_ports.items[port_index];
            if (self.heap.is_reclaimed(port)) {
                port.close();
                _ = self.file_ports.swapRemove(port_index);
            } else port_index += 1;
        }
        var locations = interp.compiler.source_locations.iterator();
        while (locations.next()) |entry| {
            if (self.heap.is_reclaimed(@ptrFromInt(entry.key_ptr.*))) {
                _ = interp.compiler.source_locations.remove(entry.key_ptr.*);
            }
        }
        self.collections += 1;
        const threshold_limit = self.heap.memory.len - self.heap.memory.len / 4;
        self.next_collection = @min(threshold_limit, @max(self.heap.bytes_used * 2, self.heap.bytes_used + 256 * 1024));
    }

    pub fn checkpoint(self: *State, interp: *Interpreter) void {
        if (self.paused == 0 and (self.collect_every_instruction or self.heap.bytes_used >= self.next_collection)) self.collect(interp);
    }

    /// A fully rooted primitive may yield between iterations. An enclosing
    /// native call or compiler scope still prevents collection.
    pub fn checkpoint_native(self: *State, interp: *Interpreter) void {
        if (self.paused != 1) return;
        self.paused = 0;
        defer self.paused = 1;
        self.checkpoint(interp);
    }
};

fn trace_interpreter(interp: *Interpreter, visitor: *Heap.Visitor) void {
    visit(interp.root_env, visitor);
    visit(interp.command_line, visitor);
    visit(interp.last_error, visitor);
    visit(interp.compiler, visitor);
    visit(interp.runtime, visitor);
    var cursor = interp.gc_state.roots;
    while (cursor) |root| : (cursor = root.next) {
        visitor.mark_buffer(root);
        root.trace(root.context, visitor);
    }
}

/// Trace typed edges rather than scanning arbitrary bytes or native stacks.
fn visit(value: anytype, visitor: *Heap.Visitor) void {
    const T = @TypeOf(value);
    if (comptime T == std.mem.Allocator or T == std.Io or T == State or T == Interpreter) return;
    if (comptime T == VM) {
        visitor.mark_buffer(value.stack.ptr);
        visitor.mark_buffer(value.frames.ptr);
        visit(value.stack[0..value.stack_top], visitor);
        visit(value.frames[0..value.frame_count], visitor);
        visit(value.open_upvalues, visitor);
        visit(value.prompts, visitor);
        return;
    }
    if (comptime T == core.Upvalue) {
        switch (value.state) {
            .open => |ptr| {
                visitor.mark_buffer(ptr);
                visit(ptr.*, visitor);
            },
            .closed => |closed| visit(closed, visitor),
        }
        visit(value.next, visitor);
        return;
    }
    switch (@typeInfo(T)) {
        .pointer => |info| {
            if (comptime info.child == anyopaque or @typeInfo(info.child) == .@"fn" or @typeInfo(info.child) == .@"opaque") return;
            switch (info.size) {
                .one => visitor.mark_typed(info.child, value, struct {
                    fn trace(ptr: *const info.child, v: *Heap.Visitor) void {
                        visit(ptr.*, v);
                    }
                }.trace),
                .slice => {
                    if (value.len == 0) return;
                    visitor.mark_buffer(@ptrCast(value.ptr));
                    if (comptime @typeInfo(info.child) != .int and @typeInfo(info.child) != .float) {
                        for (value) |item| visit(item, visitor);
                    }
                },
                .many, .c => visitor.mark_buffer(value),
            }
        },
        .optional => if (value) |present| visit(present, visitor),
        .error_union => if (value) |present| visit(present, visitor) else |_| {},
        .array => |info| {
            if (comptime @typeInfo(info.child) != .int and @typeInfo(info.child) != .float) {
                for (value) |item| visit(item, visitor);
            }
        },
        .@"union" => |info| {
            if (comptime info.tag_type != null) switch (value) {
                inline else => |field| visit(field, visitor),
            };
        },
        .@"struct" => |info| {
            if (comptime @hasField(T, "items") and @hasField(T, "capacity")) {
                if (value.capacity != 0) visitor.mark_buffer(@ptrCast(value.items.ptr));
                visit(value.items, visitor);
            } else if (comptime @hasDecl(T, "iterator") and @hasDecl(T, "capacity")) {
                var map = value;
                if (comptime @hasField(T, "unmanaged")) {
                    visit(map.unmanaged, visitor);
                } else {
                    if (map.metadata) |metadata| visitor.mark_buffer(metadata);
                    var entries = map.iterator();
                    while (entries.next()) |entry| {
                        visit(entry.key_ptr.*, visitor);
                        visit(entry.value_ptr.*, visitor);
                    }
                }
            } else inline for (info.field_names) |name| visit(@field(value, name), visitor);
        },
        else => {},
    }
}

/// A growable list allocated from its owning interpreter.
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

        pub fn clearRetainingCapacity(self: *Self) void {
            self.items = self.items.ptr[0..0];
        }
    };
}
