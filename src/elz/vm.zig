/// Elz bytecode virtual machine.
///
/// Executes FuncProto bytecode produced by compiler.zig. The VM is
/// stack-based with explicit call frames and upvalue support.
///
/// Primitives (`.procedure`, `.foreign_procedure`) are invoked by building
/// a ValueList from the stack and calling the native function directly.
const std = @import("std");
const core = @import("core.zig");
const chunk = @import("chunk.zig");
const Value = core.Value;
const ElzError = core.ElzError;
const FuncProto = chunk.FuncProto;
const OpCode = chunk.OpCode;

// Upvalue, VmClosure, and CallFrame are defined in core.zig so that the Value
// union can reference VmClosure without importing the execution engine.
const Upvalue = core.Upvalue;
const VmClosure = core.VmClosure;
const CallFrame = core.CallFrame;

// ---------------------------------------------------------------------------
// VM
// ---------------------------------------------------------------------------

/// Upper bounds for the value stack and the call stack. Both start small and
/// grow on demand, so a VM borrowed for a primitive callback costs little.
const STACK_SIZE = 65536;
const FRAMES_SIZE = 65536;
const INITIAL_STACK_SIZE = 1024;
const INITIAL_FRAMES_SIZE = 128;

pub const VM = struct {
    interp: *@import("interpreter.zig").Interpreter,
    stack: []Value,
    stack_top: usize,
    frames: []CallFrame,
    frame_count: usize,
    /// Linked list of open upvalues (sorted by stack slot, innermost first).
    open_upvalues: ?*Upvalue,
    /// Optional fuel counter: decremented each instruction; returns ExecutionBudgetExceeded when 0.
    fuel: ?*u64 = null,
    /// Highest stack height reached, so a pooled VM only has to clear the part
    /// of the stack it actually used.
    high_water: usize = 0,
    /// Active reset prompts, innermost last. Per-VM, so a shift cannot see a
    /// prompt across a native (nested VM) boundary.
    prompts: std.ArrayListUnmanaged(Prompt) = .empty,

    pub const Prompt = struct {
        /// Stack height where the reset expression's value belongs.
        stack_base: usize,
        /// Frame count at the prompt; the delimited extent lives above it.
        boundary_frames: usize,
    };

    pub fn init(interp: *@import("interpreter.zig").Interpreter) !VM {
        const alloc = interp.allocator;
        const stack = try alloc.alloc(Value, INITIAL_STACK_SIZE);
        const frames = try alloc.alloc(CallFrame, INITIAL_FRAMES_SIZE);
        return .{
            .interp = interp,
            .stack = stack,
            .stack_top = 0,
            .frames = frames,
            .frame_count = 0,
            .open_upvalues = null,
        };
    }

    /// Clears the execution state so the instance can be reused. The used part
    /// of the value stack is cleared as well, so stale values do not keep
    /// objects reachable for the collector.
    pub fn reset(self: *VM) void {
        // An error may have unwound the run with upvalues still open on this
        // stack; closing them first copies the values into their cells so the
        // closure keeps working after the stack is cleared and reused.
        self.closeUpvaluesAbove(0);
        @memset(self.stack[0..@max(self.high_water, self.stack_top)], Value.unspecified);
        self.high_water = 0;
        self.stack_top = 0;
        self.frame_count = 0;
        self.open_upvalues = null;
        self.fuel = null;
        self.prompts.clearRetainingCapacity();
    }

    pub fn deinit(self: *VM) void {
        self.interp.allocator.free(self.stack);
        self.interp.allocator.free(self.frames);
        self.prompts.deinit(self.interp.allocator);
    }

    // -----------------------------------------------------------------------
    // Stack helpers
    // -----------------------------------------------------------------------

    pub fn push(self: *VM, val: Value) ElzError!void {
        if (self.stack_top >= self.stack.len) try self.ensureStack(self.stack_top + 1);
        self.stack[self.stack_top] = val;
        self.stack_top += 1;
        if (self.stack_top > self.high_water) self.high_water = self.stack_top;
    }

    /// Grows the value stack so that `needed` slots are addressable. Open
    /// upvalues point directly into the stack, so they are rebased onto the
    /// new buffer.
    fn ensureStack(self: *VM, needed: usize) ElzError!void {
        if (needed <= self.stack.len) return;
        if (needed > STACK_SIZE) return ElzError.StackOverflow;
        var new_len = self.stack.len * 2;
        while (new_len < needed) new_len *= 2;
        if (new_len > STACK_SIZE) new_len = STACK_SIZE;
        const new_stack = self.interp.allocator.alloc(Value, new_len) catch return ElzError.OutOfMemory;
        @memcpy(new_stack[0..self.stack.len], self.stack);
        @memset(new_stack[self.stack.len..], Value.unspecified);
        const old_base = @intFromPtr(self.stack.ptr);
        var cur = self.open_upvalues;
        while (cur) |u| : (cur = u.next) {
            switch (u.state) {
                .open => |ptr| {
                    const idx = (@intFromPtr(ptr) - old_base) / @sizeOf(Value);
                    u.state = .{ .open = &new_stack[idx] };
                },
                .closed => {},
            }
        }
        self.interp.allocator.free(self.stack);
        self.stack = new_stack;
    }

    /// Grows the call stack so that `needed` frames fit.
    fn ensureFrames(self: *VM, needed: usize) ElzError!void {
        if (needed <= self.frames.len) return;
        if (needed > FRAMES_SIZE) return ElzError.StackOverflow;
        var new_len = self.frames.len * 2;
        while (new_len < needed) new_len *= 2;
        if (new_len > FRAMES_SIZE) new_len = FRAMES_SIZE;
        const new_frames = self.interp.allocator.alloc(CallFrame, new_len) catch return ElzError.OutOfMemory;
        @memcpy(new_frames[0..self.frame_count], self.frames[0..self.frame_count]);
        self.interp.allocator.free(self.frames);
        self.frames = new_frames;
    }

    fn pop(self: *VM) Value {
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    fn peek(self: *VM, offset: usize) Value {
        return self.stack[self.stack_top - 1 - offset];
    }

    fn peekPtr(self: *VM, offset: usize) *Value {
        return &self.stack[self.stack_top - 1 - offset];
    }

    // -----------------------------------------------------------------------
    // Upvalue management
    // -----------------------------------------------------------------------

    fn captureUpvalue(self: *VM, slot: usize) !*Upvalue {
        // Walk the sorted list to find or insert at the right position.
        // List is sorted descending by pointer address (via slot index) so innermost
        // (highest) slots come first.
        const ptr = &self.stack[slot];
        var prev: ?*Upvalue = null;
        var cur = self.open_upvalues;
        while (cur) |u| {
            switch (u.state) {
                .open => |p| {
                    if (p == ptr) return u; // already captured
                    // Compare pointers to maintain sorted order (higher addresses first).
                    if (@intFromPtr(p) < @intFromPtr(ptr)) break;
                    prev = u;
                    cur = u.next;
                },
                .closed => {
                    prev = u;
                    cur = u.next;
                },
            }
        }
        const new_uv = try self.interp.allocator.create(Upvalue);
        new_uv.* = .{ .state = .{ .open = ptr }, .next = cur };
        if (prev) |p| {
            p.next = new_uv;
        } else {
            self.open_upvalues = new_uv;
        }
        return new_uv;
    }

    /// Points `uv` at `slot` of this stack and places it in the open list,
    /// removing any earlier entry for it first.
    fn reopenUpvalue(self: *VM, uv: *Upvalue, slot: usize) void {
        var prev: ?*Upvalue = null;
        var cur = self.open_upvalues;
        while (cur) |u| {
            if (u == uv) {
                if (prev) |p| p.next = u.next else self.open_upvalues = u.next;
                break;
            }
            prev = u;
            cur = u.next;
        }
        const ptr = &self.stack[slot];
        uv.state = .{ .open = ptr };
        prev = null;
        cur = self.open_upvalues;
        while (cur) |u| {
            switch (u.state) {
                .open => |p| {
                    if (@intFromPtr(p) < @intFromPtr(ptr)) break;
                },
                .closed => {},
            }
            prev = u;
            cur = u.next;
        }
        uv.next = cur;
        if (prev) |p| p.next = uv else self.open_upvalues = uv;
    }

    fn closeUpvaluesAbove(self: *VM, slot: usize) void {
        // Walk the full list and close all open upvalues that point to stack slots >= threshold.
        // `slot` may equal the buffer length, so compute the address instead of indexing.
        const threshold: usize = @intFromPtr(self.stack.ptr) + slot * @sizeOf(Value);
        var prev: ?*Upvalue = null;
        var cur = self.open_upvalues;
        while (cur) |u| {
            const next = u.next;
            switch (u.state) {
                .open => |ptr| if (@intFromPtr(ptr) >= threshold) {
                    u.close();
                    // Remove from list.
                    if (prev) |p| {
                        p.next = next;
                    } else {
                        self.open_upvalues = next;
                    }
                    cur = next;
                    continue;
                },
                else => {},
            }
            prev = u;
            cur = next;
        }
    }

    // -----------------------------------------------------------------------
    // Calling a value
    // -----------------------------------------------------------------------

    fn callValue(self: *VM, callee: Value, argc: u8, tail: bool) ElzError!void {
        switch (callee) {
            .vm_closure => |cl| {
                try self.callVmClosure(cl, argc, tail);
            },
            .procedure => |prim| {
                var args = try self.buildArgList(argc); // pops args + callee
                defer args.deinit();
                // A primitive that calls back into Elz (map, apply, ...) runs
                // the callee under the same fuel budget as this VM.
                var unlimited: u64 = std.math.maxInt(u64);
                const fuel_ptr: *u64 = self.fuel orelse &unlimited;
                const result = try prim(self.interp, self.interp.root_env, args, fuel_ptr);
                try self.push(result);
            },
            .foreign_procedure => |ff| {
                var args = try self.buildArgList(argc);
                defer args.deinit();
                const ffi_mod = @import("ffi.zig");
                const prev = ffi_mod.active_interp;
                ffi_mod.active_interp = self.interp;
                defer ffi_mod.active_interp = prev;
                const result = ff(self.interp.root_env, args) catch |err| {
                    self.interp.last_error_message = @errorName(err);
                    return ElzError.ForeignFunctionError;
                };
                try self.push(result);
            },
            .continuation => |cont| {
                if (argc != 1) return ElzError.WrongArgumentCount;
                const v = self.pop();
                _ = self.pop(); // the continuation value itself
                const base = self.stack_top;
                try self.ensureStack(base + cont.stack.len + 1);
                try self.ensureFrames(self.frame_count + cont.frames.len);
                // Reinstating the segment installs a fresh prompt around it.
                self.prompts.append(self.interp.allocator, .{
                    .stack_base = base,
                    .boundary_frames = self.frame_count,
                }) catch return ElzError.OutOfMemory;
                @memcpy(self.stack[base .. base + cont.stack.len], cont.stack);
                self.stack_top = base + cont.stack.len;
                if (self.stack_top > self.high_water) self.high_water = self.stack_top;
                for (cont.frames) |fr| {
                    var nf = fr;
                    nf.stack_base += base;
                    self.frames[self.frame_count] = nf;
                    self.frame_count += 1;
                }
                // Closures created inside the segment hold the cells that were
                // closed at capture time. Re-open them onto the new copy so the
                // resumed frames and those closures share one location again;
                // the cell carries the latest value across invocations.
                for (cont.upvals) |cu| {
                    const slot = base + cu.offset;
                    self.stack[slot] = cu.upvalue.get();
                    self.reopenUpvalue(cu.upvalue, slot);
                }
                // The resume value becomes the value of the original shift.
                try self.push(v);
            },
            .escape => |esc| {
                if (argc != 1) return ElzError.WrongArgumentCount;
                const v = self.pop();
                _ = self.pop(); // the escape procedure itself
                if (!esc.active) {
                    self.interp.last_error_message = "escape continuation invoked outside its dynamic extent";
                    return ElzError.InvalidArgument;
                }
                self.interp.cps.escape_value = v;
                self.interp.cps.escape_id = esc.id;
                return ElzError.EscapeContinuationInvoked;
            },
            .syntax_rules, .macro => {
                // Macros should have been expanded at compile time.
                return ElzError.NotAFunction;
            },
            else => {
                self.interp.last_error_message = "attempt to call a non-procedure";
                return ElzError.NotAFunction;
            },
        }
    }

    pub fn callVmClosure(self: *VM, cl: *VmClosure, argc: u8, tail: bool) ElzError!void {
        const proto = cl.proto;
        const expected = proto.arity;
        const variadic = proto.variadic;

        if (!variadic and argc != expected) return ElzError.WrongArgumentCount;
        if (variadic and argc < expected) return ElzError.WrongArgumentCount;

        if (tail and self.frame_count > 0) {
            // Tail call: reuse current frame.
            const frame = &self.frames[self.frame_count - 1];
            // Close upvalues for the current frame before reuse.
            self.closeUpvaluesAbove(frame.stack_base);
            // Slide args down to the ORIGINAL frame base, not callee_pos.
            // This ensures return_val restores stack_top to the correct position
            // for the outer caller, regardless of how deep in the frame the callee
            // was found (e.g. a letrec-bound variable at slot N).
            const callee_pos = self.stack_top - argc - 1;
            const new_base = frame.stack_base;
            for (0..argc) |i| {
                self.stack[new_base + i] = self.stack[callee_pos + 1 + i];
            }
            self.stack_top = new_base + argc;
            // Handle variadic rest argument.
            if (variadic) {
                try self.buildRestArg(expected, argc, new_base);
            }
            // Pad only to arity (parameters); body code initialises any extra locals.
            while (self.stack_top < new_base + expected) {
                try self.push(.unspecified);
            }
            frame.closure = cl;
            frame.ip = 0;
            frame.stack_base = new_base;
        } else {
            try self.ensureFrames(self.frame_count + 1);
            // Non-tail call: push new frame.
            const callee_pos = self.stack_top - argc - 1;
            const stack_base = callee_pos;
            // Slide args to replace callee slot.
            for (0..argc) |i| {
                self.stack[callee_pos + i] = self.stack[callee_pos + 1 + i];
            }
            self.stack_top = callee_pos + argc;
            // Handle variadic rest argument.
            if (variadic) {
                try self.buildRestArg(expected, argc, callee_pos);
            }
            // Pad only to arity (parameters); body code initialises any extra locals.
            while (self.stack_top < stack_base + expected) {
                try self.push(.unspecified);
            }
            self.frames[self.frame_count] = .{
                .closure = cl,
                .ip = 0,
                .stack_base = stack_base,
            };
            self.frame_count += 1;
        }
    }

    fn buildRestArg(self: *VM, arity: u8, argc: u8, base: usize) !void {
        // Build a list from args[arity..argc] and store at stack[base + arity].
        var rest: Value = .nil;
        var i = argc;
        while (i > arity) {
            i -= 1;
            const pair = try self.interp.allocator.create(core.Pair);
            pair.* = .{ .car = self.stack[base + i], .cdr = rest };
            rest = Value{ .pair = pair };
        }
        try self.ensureStack(base + arity + 1);
        self.stack_top = base + arity + 1;
        if (self.stack_top > self.high_water) self.high_water = self.stack_top;
        self.stack[base + arity] = rest;
    }

    fn buildArgList(self: *VM, argc: u8) !core.ValueList {
        var args = core.ValueList.init(self.interp.allocator);
        const start = self.stack_top - argc;
        for (start..self.stack_top) |i| {
            try args.append(self.stack[i]);
        }
        // Pop args and callee from stack.
        self.stack_top -= @as(usize, argc) + 1;
        return args;
    }

    // -----------------------------------------------------------------------
    // Main execution loop
    // -----------------------------------------------------------------------

    pub fn run(self: *VM) ElzError!Value {
        while (true) {
            if (self.frame_count == 0) return self.pop();
            const frame = &self.frames[self.frame_count - 1];
            const proto = frame.closure.proto;

            if (frame.ip >= proto.instructions.items.len) {
                return ElzError.InvalidArgument; // Should not happen with return_val
            }

            const instr = proto.instructions.items[frame.ip];
            frame.ip += 1;

            // Time budget check — delegates to the shared implementation on Interpreter.
            try self.interp.checkTimeBudget();

            // Step-count fuel check.
            if (self.fuel) |f| {
                if (f.* == 0) return ElzError.ExecutionBudgetExceeded;
                f.* -= 1;
            }

            switch (instr.op) {
                // --- Constants ---
                .load_nil => try self.push(.nil),
                .load_true => try self.push(.{ .boolean = true }),
                .load_false => try self.push(.{ .boolean = false }),
                .load_unspecified => try self.push(.unspecified),
                .load_const => {
                    const val = proto.constants.items[instr.bx];
                    try self.push(val);
                },

                // --- Variables ---
                .load_local => {
                    try self.push(self.stack[frame.stack_base + instr.a]);
                },
                .store_local => {
                    self.stack[frame.stack_base + instr.a] = self.peek(0);
                },
                .load_upval => {
                    const uv = frame.closure.upvals[instr.a];
                    try self.push(uv.get());
                },
                .store_upval => {
                    const uv = frame.closure.upvals[instr.a];
                    uv.set(self.peek(0));
                },
                .load_global => {
                    const name_val = proto.constants.items[instr.bx];
                    if (name_val != .symbol) return ElzError.InvalidArgument;
                    const val = self.interp.root_env.lookup(name_val.symbol) orelse blk: {
                        // A hygiene-renamed identifier that never got a binding
                        // of its own is a free reference to the original name,
                        // possibly through several levels of renaming.
                        var name = name_val.symbol;
                        while (@import("macros.zig").hygieneBase(name)) |base| {
                            name = base;
                            if (self.interp.root_env.lookup(name)) |v| break :blk v;
                        }
                        break :blk try self.interp.root_env.get(name_val.symbol, self.interp);
                    };
                    try self.push(val);
                },
                .store_global => {
                    const name_val = proto.constants.items[instr.bx];
                    if (name_val != .symbol) return ElzError.InvalidArgument;
                    // `set!` requires an existing binding: `update` reports
                    // SymbolNotFound rather than quietly creating a global.
                    var name = name_val.symbol;
                    while (!self.interp.root_env.contains(name)) {
                        name = @import("macros.zig").hygieneBase(name) orelse break;
                    }
                    if (!self.interp.root_env.contains(name)) name = name_val.symbol;
                    try self.interp.root_env.update(self.interp, name, self.peek(0));
                },
                .define_global => {
                    const name_val = proto.constants.items[instr.bx];
                    if (name_val != .symbol) return ElzError.InvalidArgument;
                    const val = self.pop();
                    try self.interp.root_env.set(self.interp, name_val.symbol, val);
                    try self.push(.unspecified);
                },

                // --- Control flow ---
                .jump => {
                    frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + instr.offset);
                },
                .jump_if_false => {
                    const cond = self.pop();
                    if (!isTruthy(cond)) {
                        frame.ip = @intCast(@as(i64, @intCast(frame.ip)) + instr.offset);
                    }
                },

                // --- Calls ---
                .call => {
                    const argc = instr.a;
                    const callee = self.peek(argc);
                    try self.callValue(callee, argc, false);
                },
                .tail_call => {
                    const argc = instr.a;
                    const callee = self.peek(argc);
                    switch (callee) {
                        .vm_closure => |cl| try self.callVmClosure(cl, argc, true),
                        else => try self.callValue(callee, argc, false),
                    }
                },
                .return_val => {
                    const result = self.pop();
                    // Close upvalues for this frame.
                    self.closeUpvaluesAbove(frame.stack_base);
                    // Pop frame.
                    self.frame_count -= 1;
                    // Restore stack to just before this frame's callee slot.
                    self.stack_top = frame.stack_base;
                    if (self.frame_count == 0) {
                        return result;
                    }
                    try self.push(result);
                    // Returning into the frame that pushed a prompt ends its extent.
                    while (self.prompts.items.len > 0 and
                        self.prompts.items[self.prompts.items.len - 1].boundary_frames >= self.frame_count)
                    {
                        _ = self.prompts.pop();
                    }
                },

                .reset_prompt => {
                    const thunk = self.pop();
                    try self.prompts.append(self.interp.allocator, .{
                        .stack_base = self.stack_top,
                        .boundary_frames = self.frame_count,
                    });
                    try self.push(thunk);
                    try self.callValue(thunk, 0, false);
                },

                .shift_capture => {
                    const handler = self.pop();
                    if (self.prompts.items.len == 0) {
                        self.interp.last_error_message = "shift: no enclosing reset in this extent (prompts do not cross native frames)";
                        return ElzError.InvalidArgument;
                    }
                    const p = self.prompts.items[self.prompts.items.len - 1];
                    const alloc = self.interp.allocator;
                    // Remember which upvalues are open into the captured region,
                    // then close them so closures keep working while the
                    // segment is not on the stack. Reinstating re-opens them.
                    var captured: std.ArrayListUnmanaged(core.Continuation.CapturedUpvalue) = .empty;
                    {
                        const threshold: usize = @intFromPtr(self.stack.ptr) + p.stack_base * @sizeOf(Value);
                        var cur = self.open_upvalues;
                        while (cur) |u| : (cur = u.next) {
                            switch (u.state) {
                                .open => |ptr| if (@intFromPtr(ptr) >= threshold) {
                                    const offset = (@intFromPtr(ptr) - threshold) / @sizeOf(Value);
                                    captured.append(alloc, .{ .upvalue = u, .offset = offset }) catch return ElzError.OutOfMemory;
                                },
                                .closed => {},
                            }
                        }
                    }
                    self.closeUpvaluesAbove(p.stack_base);
                    const seg_stack = alloc.dupe(Value, self.stack[p.stack_base..self.stack_top]) catch return ElzError.OutOfMemory;
                    const seg_frames = alloc.dupe(CallFrame, self.frames[p.boundary_frames..self.frame_count]) catch return ElzError.OutOfMemory;
                    for (seg_frames) |*fr| fr.stack_base -= p.stack_base;
                    const cont = alloc.create(core.Continuation) catch return ElzError.OutOfMemory;
                    cont.* = .{
                        .stack = seg_stack,
                        .frames = seg_frames,
                        .upvals = captured.toOwnedSlice(alloc) catch return ElzError.OutOfMemory,
                    };
                    // Unwind to the prompt; the prompt stays for the handler body.
                    self.stack_top = p.stack_base;
                    self.frame_count = p.boundary_frames;
                    try self.push(handler);
                    try self.push(Value{ .continuation = cont });
                    try self.callValue(handler, 1, false);
                },

                // --- Stack ---
                .pop => _ = self.pop(),
                .dup => try self.push(self.peek(0)),
                .swap => {
                    const a = self.pop();
                    const b = self.pop();
                    try self.push(a);
                    try self.push(b);
                },

                // --- Pairs ---
                .cons => {
                    const cdr = self.pop();
                    const car = self.pop();
                    const pair = try self.interp.allocator.create(core.Pair);
                    pair.* = .{ .car = car, .cdr = cdr };
                    try self.push(Value{ .pair = pair });
                },
                .car_op => {
                    const v = self.pop();
                    if (v != .pair) return ElzError.InvalidArgument;
                    try self.push(v.pair.car);
                },
                .cdr_op => {
                    const v = self.pop();
                    if (v != .pair) return ElzError.InvalidArgument;
                    try self.push(v.pair.cdr);
                },

                // --- Closures ---
                .make_closure => {
                    const sub_proto = proto.sub_protos.items[instr.bx];
                    const upval_count = sub_proto.upval_descs.items.len;
                    const cl = try self.interp.allocator.create(VmClosure);
                    const upvals = try self.interp.allocator.alloc(*Upvalue, upval_count);
                    cl.* = .{ .proto = sub_proto, .upvals = upvals };
                    try self.push(Value{ .vm_closure = cl });
                },
                .capture_local => {
                    // Follows make_closure: a=local_slot, b=upvalue_fill_index.
                    const cl = self.peek(0).vm_closure;
                    const slot = frame.stack_base + instr.a;
                    const uv = try self.captureUpvalue(slot);
                    cl.upvals[instr.b] = uv;
                },
                .capture_upval => {
                    // Follows make_closure: a=parent_upval_index, b=upvalue_fill_index.
                    const cl = self.peek(0).vm_closure;
                    const parent_uv = frame.closure.upvals[instr.a];
                    cl.upvals[instr.b] = parent_uv;
                },
                .close_upval => {
                    self.closeUpvaluesAbove(frame.stack_base + instr.a);
                },

                // --- Aggregate constructors ---
                .make_list => {
                    var result: Value = .nil;
                    var i = instr.a;
                    while (i > 0) {
                        i -= 1;
                        const item = self.stack[self.stack_top - instr.a + i];
                        const pair = try self.interp.allocator.create(core.Pair);
                        pair.* = .{ .car = item, .cdr = result };
                        result = Value{ .pair = pair };
                    }
                    self.stack_top -= instr.a;
                    try self.push(result);
                },
                .make_vector => {
                    const count = instr.a;
                    const vec = try self.interp.allocator.create(core.Vector);
                    const items = try self.interp.allocator.alloc(Value, count);
                    var i: u8 = count;
                    while (i > 0) {
                        i -= 1;
                        items[i] = self.pop();
                    }
                    vec.* = .{ .items = items };
                    try self.push(Value{ .vector = vec });
                },
                .list_to_vector => {
                    const list = self.pop();
                    var count: usize = 0;
                    var cur = list;
                    while (cur == .pair) : (cur = cur.pair.cdr) count += 1;
                    if (cur != .nil) return ElzError.InvalidArgument;
                    const vec = try self.interp.allocator.create(core.Vector);
                    const items = try self.interp.allocator.alloc(Value, count);
                    cur = list;
                    var i: usize = 0;
                    while (cur == .pair) : (cur = cur.pair.cdr) {
                        items[i] = cur.pair.car;
                        i += 1;
                    }
                    vec.* = .{ .items = items };
                    try self.push(Value{ .vector = vec });
                },
                .append_lists => {
                    const second = self.pop();
                    const first = self.pop();
                    const result = try appendLists(self.interp.allocator, first, second);
                    try self.push(result);
                },
                .values_pack => {
                    const count = instr.a;
                    const mv = try self.interp.allocator.create(core.MultiValues);
                    const items = try self.interp.allocator.alloc(Value, count);
                    var i: u8 = count;
                    while (i > 0) {
                        i -= 1;
                        items[i] = self.pop();
                    }
                    mv.* = .{ .items = items };
                    try self.push(Value{ .multi_values = mv });
                },
            }
        }
    }

    // -----------------------------------------------------------------------
    // Execute a top-level FuncProto
    // -----------------------------------------------------------------------

    fn recordBacktrace(self: *VM) void {
        const interp = self.interp;
        const max = @import("interpreter.zig").MAX_BACKTRACE_FRAMES;
        var i = self.frame_count;
        while (i > 0 and interp.backtrace.items.len < max) {
            i -= 1;
            const fr = self.frames[i];
            const ip = if (fr.ip > 0) fr.ip - 1 else 0;
            const lines = fr.closure.proto.lines.items;
            interp.backtrace.append(interp.allocator, .{
                .name = fr.closure.proto.name,
                .file = fr.closure.proto.source_file,
                .line = if (ip < lines.len) lines[ip] else 0,
            }) catch return;
        }
    }

    pub fn runProto(self: *VM, proto: *FuncProto, fuel: ?*u64) ElzError!Value {
        self.fuel = fuel;
        const cl = try self.interp.allocator.create(VmClosure);
        cl.* = .{ .proto = proto, .upvals = &.{} };
        self.frames[0] = .{ .closure = cl, .ip = 0, .stack_base = 0 };
        self.frame_count = 1;
        self.prompts.clearRetainingCapacity();
        // Start with an empty working stack. The body code is responsible for
        // initialising its own locals (letrec emits load_false, let pushes init values).
        self.stack_top = 0;
        const result = self.run() catch |err| {
            // Record the source location of the failing instruction. Keep the
            // innermost location when nested VM runs propagate the error.
            if (self.frame_count > 0 and self.interp.last_error_line == null) {
                const fr = self.frames[self.frame_count - 1];
                const ip = if (fr.ip > 0) fr.ip - 1 else 0;
                const lines = fr.closure.proto.lines.items;
                if (ip < lines.len and lines[ip] != 0) {
                    self.interp.last_error_line = lines[ip];
                    self.interp.last_error_file = fr.closure.proto.source_file;
                }
            }
            // Nested VM runs unwind innermost first, so appending here keeps
            // the whole backtrace ordered from the failure outwards.
            if (self.interp.collect_backtrace) self.recordBacktrace();
            self.closeUpvaluesAbove(0);
            return err;
        };
        // Close all open upvalues before the stack is freed: this copies any open
        // upvalue values into the cell so subsequent accesses via the closed pointer
        // (from callProc or runFromEval) see valid values.
        self.closeUpvaluesAbove(0);
        return result;
    }
};

// ---------------------------------------------------------------------------
// VM pool
//
// A primitive that calls back into Elz (`map`, `apply`, `dynamic-wind`, ...)
// runs the callee on a nested VM. Allocating one per call would hand the
// collector a fresh multi-megabyte stack for every list element, so idle
// instances are kept on the interpreter and reused.
// ---------------------------------------------------------------------------

/// Deepest nesting of VM runs through primitive callbacks (`map`, `apply`,
/// `call/cc`, `guard`, ...). Each level uses several native stack frames.
const MAX_NATIVE_DEPTH: u32 = 600;

/// Maximum number of idle VMs retained. Deeper nesting still works; the extra
/// instances are simply not pooled.
const VM_POOL_LIMIT = 8;

fn acquireVm(interp: *@import("interpreter.zig").Interpreter) ElzError!*VM {
    if (interp.vm_pool.pop()) |machine| {
        machine.reset();
        return machine;
    }
    const machine = interp.allocator.create(VM) catch return ElzError.OutOfMemory;
    machine.* = VM.init(interp) catch return ElzError.OutOfMemory;
    return machine;
}

fn releaseVm(interp: *@import("interpreter.zig").Interpreter, machine: *VM) void {
    machine.reset();
    if (interp.vm_pool.items.len >= VM_POOL_LIMIT) {
        machine.deinit();
        interp.allocator.destroy(machine);
        return;
    }
    interp.vm_pool.append(interp.allocator, machine) catch {
        machine.deinit();
        interp.allocator.destroy(machine);
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn isTruthy(v: Value) bool {
    return switch (v) {
        .boolean => |b| b,
        else => true,
    };
}

fn appendLists(allocator: std.mem.Allocator, list1: Value, list2: Value) !Value {
    if (list1 != .pair) return list2;
    var head: ?*core.Pair = null;
    var tail: ?*core.Pair = null;
    var cur = list1;
    while (cur == .pair) : (cur = cur.pair.cdr) {
        const new_pair = try allocator.create(core.Pair);
        new_pair.* = .{ .car = cur.pair.car, .cdr = .nil };
        if (tail) |t| t.cdr = Value{ .pair = new_pair } else head = new_pair;
        tail = new_pair;
    }
    tail.?.cdr = list2;
    return Value{ .pair = head.? };
}

/// Entry point that can be used to run a vm_closure with a given argument list.
pub fn runFromEval(interp: *@import("interpreter.zig").Interpreter, cl: *VmClosure, args: core.ValueList) core.ElzError!Value {
    const vm_inst = try acquireVm(interp);
    defer releaseVm(interp, vm_inst);
    try vm_inst.push(Value{ .vm_closure = cl });
    for (args.items) |arg| try vm_inst.push(arg);
    try vm_inst.callVmClosure(cl, @intCast(args.items.len), false);
    const result = vm_inst.run();
    // Close all open upvalues before the stack is reused.
    vm_inst.closeUpvaluesAbove(0);
    return result;
}

/// Call any Elz value as a procedure with the given argument list.
/// Used by primitives that need to call back into Elz (e.g., `apply`, `map`,
/// `dynamic-wind`, `for-each`).
///
/// Because upvalues now store a direct `*Value` pointer into the owning VM's stack,
/// they remain valid across multiple VMs: the pointer still addresses the live stack
/// memory of the outer VM (which is suspended in a primitive call).  When the outer
/// VM's frame eventually exits, `closeUpvaluesAbove` will overwrite the open state
/// with a closed copy — leaving the pointer dangling but the cell valid.
pub fn callProc(interp: *@import("interpreter.zig").Interpreter, proc: Value, args: core.ValueList, fuel: ?*u64) ElzError!Value {
    // Native callees need no VM frame, and this path has no argument limit.
    switch (proc) {
        .procedure => |prim| {
            var unlimited: u64 = std.math.maxInt(u64);
            return prim(interp, interp.root_env, args, fuel orelse &unlimited);
        },
        .foreign_procedure => |ff| {
            const ffi_mod = @import("ffi.zig");
            const prev = ffi_mod.active_interp;
            ffi_mod.active_interp = interp;
            defer ffi_mod.active_interp = prev;
            return ff(interp.root_env, args) catch |err| {
                interp.last_error_message = @errorName(err);
                return ElzError.ForeignFunctionError;
            };
        },
        else => {},
    }
    // Each nested VM run consumes native stack; bound the nesting so deep
    // recursion through a primitive callback reports StackOverflow instead
    // of crashing the host.
    if (interp.native_depth >= MAX_NATIVE_DEPTH) return ElzError.StackOverflow;
    interp.native_depth += 1;
    defer interp.native_depth -= 1;
    const machine = try acquireVm(interp);
    defer releaseVm(interp, machine);
    machine.fuel = fuel;
    try machine.push(proc);
    if (args.items.len > std.math.maxInt(u8)) {
        // Only a variadic closure can take this many arguments: pass the
        // fixed parameters on the stack and the remainder as the rest list.
        if (proc != .vm_closure) return ElzError.TooManyLocals;
        const cl = proc.vm_closure;
        if (!cl.proto.variadic or args.items.len < cl.proto.arity) return ElzError.WrongArgumentCount;
        const fixed: usize = cl.proto.arity;
        for (args.items[0..fixed]) |arg| try machine.push(arg);
        var rest: Value = .nil;
        var i = args.items.len;
        while (i > fixed) {
            i -= 1;
            const pair = try interp.allocator.create(core.Pair);
            pair.* = .{ .car = args.items[i], .cdr = rest };
            rest = Value{ .pair = pair };
        }
        try machine.push(rest);
        // Enter the closure as if it had been called with arity + 1 values,
        // where the last one is already the rest list.
        try machine.ensureFrames(machine.frame_count + 1);
        const callee_pos = machine.stack_top - fixed - 2;
        for (0..fixed + 1) |k| machine.stack[callee_pos + k] = machine.stack[callee_pos + 1 + k];
        machine.stack_top = callee_pos + fixed + 1;
        machine.frames[machine.frame_count] = .{ .closure = cl, .ip = 0, .stack_base = callee_pos };
        machine.frame_count += 1;
    } else {
        for (args.items) |arg| try machine.push(arg);
        const argc: u8 = @intCast(args.items.len);
        try machine.callValue(machine.peek(argc), argc, false);
    }
    const result = machine.run();
    // Close all open upvalues before the stack is reused.
    machine.closeUpvaluesAbove(0);
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "vm basic execution" {
    const testing = std.testing;
    const compiler_mod = @import("compiler.zig");
    const interp_mod = @import("interpreter.zig");

    var interp = try interp_mod.Interpreter.init(.{});
    defer interp.deinit();

    const allocator = interp.allocator;
    const source = "(+ 1 2)";
    const parsed = try @import("parser.zig").read(source, allocator);
    const forms = [_]Value{parsed};

    var fuel: u64 = 1_000_000;
    const proto = try compiler_mod.Compiler.compileTopLevel(allocator, &interp, &forms, interp.root_env, &fuel);
    defer {
        proto.deinit();
        allocator.destroy(proto);
    }

    var vm = try VM.init(&interp);
    defer vm.deinit();

    const result = try vm.runProto(proto, null);
    try testing.expect(result == .exact_integer);
    try testing.expectEqual(@as(i64, 3), result.exact_integer);
}
