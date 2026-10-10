# Garbage Collection

`src/elz/managed_heap.zig` implements the precise, non-moving collector used by
Element 0 on native and WASI targets. `src/elz/gc.zig` describes the interpreter's
typed references and roots. Neither module depends on Boehm.

Each interpreter owns a fixed heap, with a default limit of 64 MiB. Collection
runs between VM instructions. Compilation and native calls pause collection to
protect their temporary Zig values. Hosts use `elz.Root` and
`Interpreter.protect` for values retained across evaluation or collection. See
the [Embedding Guide](embedding.md#the-interpreter).

The lower-level `Heap` API below also works independently of the interpreter.

## Heap and Roots

The caller supplies a memory region and owns its lifetime. The heap stores object
headers, a block-location bitmap, and a marking worklist in that region.
Allocation splits free blocks.
Manual collection traces explicit roots, sweeps unreachable objects, and joins
adjacent free blocks. Objects stay at the same addresses.

`bytes_used` counts occupied blocks, including headers, pointer prefixes,
alignment padding, and tails too small to split. Leading and trailing bytes used
to align the region and the bitmap storage are excluded from `heap.memory`.
Root records belong to the
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

## Remaining MCU Work

Typed tracing covers parser values, compiled prototypes, environments, VM stacks,
upvalues, continuations, records, ports, and interpreter state. Rooted native
values are traced through their declared Zig types. Raw buffers have no reference
tracing of their own, so their owners describe their initialized contents.

The collector does not scan native stacks or collect inside an allocation.
Native calls defer collection, except that the rooted `force` primitive may
collect between promise-chain iterations. `OutOfMemory` remains possible during a long
native operation. The full MCU interpreter port still needs replacements for
host I/O, clock, and environment calls, and a memory budget for the standard
library and compiler.

## Pico Hardware Test

The initial standalone collector passed nine checks on a Pico 2 WH with a 128 KiB heap
and Zig 0.17.0 safety checks enabled. The checks cover cycles, roots, exhaustion,
coalescing, alignment, buffers, a 1,500-object chain, 10,000 collection cycles,
and heap boundaries. The harness is in `tools/pico-gc`, with build and flash
instructions in its `README.md`. It uses the Pico SDK and does not run the
Element 0 interpreter.
That hardware run predates interpreter integration and the block-location bitmap.
