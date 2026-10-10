# Standalone Garbage Collector

`src/elz/managed_heap.zig` contains the first step toward a precise collector for
Element 0. It is an internal module. The interpreter still uses Boehm on native
targets and the existing arena on WebAssembly.

## Heap and Roots

The caller supplies a memory region and owns its lifetime. The heap stores object
headers and a marking worklist in that region. Allocation splits free blocks.
Manual collection traces explicit roots, sweeps unreachable objects, and joins
adjacent free blocks. Objects stay at the same addresses.

`bytes_used` counts occupied blocks, including headers, pointer prefixes,
alignment padding, and tails too small to split. Leading and trailing bytes used
to align the region are excluded from `heap.memory`. Root records belong to the
caller and use additional memory outside the region. The collector allocates
nothing during marking or sweeping.

Use `create` to initialize an object with its tracing callback. Pass null for an
object without managed references. A callback marks every referenced object
through `Visitor.mark`. Cycles and shared references are supported.

Place each `Root` at a stable address before calling `add_root`. Remove it with
`deinit` before its scope ends. `Root.set` changes the protected object. Null
protects no object. The heap itself must also stay at a stable address after its
first allocation or root registration.

Allocation never collects. Before calling `collect`, protect every native local
that must survive. Roots and callbacks accept only null or exact base pointers
returned by the same heap. Interior pointers and pointers from other allocators
are invalid. Tracing callbacks must not allocate, collect, or change roots.

## Example

Save this example as `tmp/collector_example.zig` and run it from the project root.

```zig
const std = @import("std");
const Heap = @import("managed_heap").Heap;

const Node = struct {
    next: ?*Node = null,

    fn trace(self: *const Node, visitor: *Heap.Visitor) void {
        visitor.mark(self.next);
    }
};

pub fn main() !void {
    var memory: [4096]u8 = undefined;
    var heap = try Heap.init(&memory);
    const node = try heap.create(Node, .{}, Node.trace);
    node.next = node;

    var root: Heap.Root = .{};
    heap.add_root(&root, node);
    defer root.deinit();

    heap.collect();
    std.debug.assert(heap.object_count == 1);
    root.set(null);
    heap.collect();
    std.debug.assert(heap.bytes_used == 0);
}
```

```bash
zig run --dep managed_heap -Mroot=tmp/collector_example.zig -Mmanaged_heap=src/elz/managed_heap.zig
```

## Buffers and Limits

`heap.allocator()` implements `std.mem.Allocator` for reference-free storage.
Its allocations have no tracing callback. An owning object must mark each
nonempty buffer's base pointer and trace any managed references stored in it.
Using this allocator to create an object does not register its references.

Frees are ignored, and unreachable buffers are reclaimed by collection.
Reallocation copies into a new block. Update the owner or root to the returned
address before collecting. Empty allocations from `std.mem.Allocator` do not
create managed blocks and must not be marked.

Allocation returns `OutOfMemory` when no free block fits. It does not collect or
expand the region. Rooted objects survive allocation failure. A non-moving heap
can run out of contiguous space even when its total free space would be enough.
Objects that own external resources need explicit cleanup. Finalizers are not
implemented.

## Remaining Integration

The next step is to describe all references in parser, compiler, and runtime
objects, then register interpreter, VM, and native temporary roots. Automatic
collection needs safe allocation and publication rules. Boehm can be removed
only after tests force collection throughout those paths. The MCU port also
needs replacements for the host I/O, clock, and environment calls.
