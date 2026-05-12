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

const STACK_SIZE = 4096;
const FRAMES_SIZE = 256;

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

    pub fn init(interp: *@import("interpreter.zig").Interpreter) !VM {
        const alloc = interp.allocator;
        const stack = try alloc.alloc(Value, STACK_SIZE);
        const frames = try alloc.alloc(CallFrame, FRAMES_SIZE);
        return .{
            .interp = interp,
            .stack = stack,
            .stack_top = 0,
            .frames = frames,
            .frame_count = 0,
            .open_upvalues = null,
        };
    }

    pub fn deinit(self: *VM) void {
        self.interp.allocator.free(self.stack);
        self.interp.allocator.free(self.frames);
    }

    // -----------------------------------------------------------------------
    // Stack helpers
    // -----------------------------------------------------------------------

    pub fn push(self: *VM, val: Value) ElzError!void {
        if (self.stack_top >= STACK_SIZE) return ElzError.StackOverflow;
        self.stack[self.stack_top] = val;
        self.stack_top += 1;
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

    fn closeUpvaluesAbove(self: *VM, slot: usize) void {
        // Walk the full list and close all open upvalues that point to stack slots >= threshold.
        const threshold = &self.stack[slot];
        var prev: ?*Upvalue = null;
        var cur = self.open_upvalues;
        while (cur) |u| {
            const next = u.next;
            switch (u.state) {
                .open => |ptr| if (@intFromPtr(ptr) >= @intFromPtr(threshold)) {
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
                // Use max fuel so only the wall-clock time limit (checkTimeBudget) bounds execution.
                var prim_fuel: u64 = std.math.maxInt(u64);
                const result = try prim(self.interp, self.interp.root_env, args, &prim_fuel);
                args.deinit();
                try self.push(result);
            },
            .foreign_procedure => |ff| {
                var args = try self.buildArgList(argc);
                const ffi_mod = @import("ffi.zig");
                const prev = ffi_mod.active_interp;
                ffi_mod.active_interp = self.interp;
                defer ffi_mod.active_interp = prev;
                const result = ff(self.interp.root_env, args) catch |err| {
                    self.interp.last_error_message = @errorName(err);
                    return ElzError.ForeignFunctionError;
                };
                args.deinit();
                try self.push(result);
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
            if (self.frame_count >= FRAMES_SIZE) return ElzError.StackOverflow;
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
        self.stack_top = base + arity + 1;
        self.stack[base + arity] = rest;
    }

    fn buildArgList(self: *VM, argc: u8) !core.ValueList {
        var args = core.ValueList.init(self.interp.allocator);
        const start = self.stack_top - argc;
        for (start..self.stack_top) |i| {
            try args.append(self.stack[i]);
        }
        // Pop args and callee from stack.
        self.stack_top -= argc + 1;
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
                std.debug.print("[VM DEBUG] ip={} past end of proto '{s}' (len={}), frame_count={}\n", .{
                    frame.ip, proto.name, proto.instructions.items.len, self.frame_count,
                });
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
                    const val = try self.interp.root_env.get(name_val.symbol, self.interp);
                    try self.push(val);
                },
                .store_global => {
                    const name_val = proto.constants.items[instr.bx];
                    if (name_val != .symbol) return ElzError.InvalidArgument;
                    try self.interp.root_env.set(self.interp, name_val.symbol, self.peek(0));
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
                    // Capture args BEFORE the call (buildArgList pops them)
                    const dbg_stack_top_before = self.stack_top;
                    self.callValue(callee, argc, false) catch |e| {
                        std.debug.print("[VM DEBUG] call error={s} callee_tag={s} proto='{s}' ip={} argc={}\n", .{
                            @errorName(e), @tagName(callee), proto.name, frame.ip - 1, argc,
                        });
                        // Args were at stack[stack_top-argc..stack_top] before call
                        const arg_start = dbg_stack_top_before - argc;
                        for (arg_start..dbg_stack_top_before) |si| {
                            std.debug.print("  arg[{}] tag={s}\n", .{ si - arg_start, @tagName(self.stack[si]) });
                        }
                        // Print proto constants to identify what's being called
                        std.debug.print("  proto constants ({}):\n", .{proto.constants.items.len});
                        for (proto.constants.items, 0..) |c, ci| {
                            switch (c) {
                                .symbol => |s| std.debug.print("    [{}] symbol '{s}'\n", .{ ci, s }),
                                .boolean => |b| std.debug.print("    [{}] boolean {}\n", .{ ci, b }),
                                .exact_integer => |i| std.debug.print("    [{}] integer {}\n", .{ ci, i }),
                                .nil => std.debug.print("    [{}] nil\n", .{ci}),
                                else => std.debug.print("    [{}] other:{s}\n", .{ ci, @tagName(c) }),
                            }
                        }
                        // Print proto instructions around ip
                        const start_ip = if (frame.ip >= 5) frame.ip - 5 else 0;
                        std.debug.print("  proto instructions [{}..{}]:\n", .{ start_ip, frame.ip });
                        for (proto.instructions.items[start_ip..@min(frame.ip, proto.instructions.items.len)], start_ip..) |ins, iip| {
                            std.debug.print("    [{}] op={s} a={} b={} bx={}\n", .{ iip, @tagName(ins.op), ins.a, ins.b, ins.bx });
                        }
                        var fi = self.frame_count;
                        while (fi > 0) {
                            fi -= 1;
                            std.debug.print("  frame[{}] proto='{s}' ip={}\n", .{ fi, self.frames[fi].closure.proto.name, self.frames[fi].ip });
                        }
                        return e;
                    };
                },
                .tail_call => {
                    const argc = instr.a;
                    const callee = self.peek(argc);
                    switch (callee) {
                        .vm_closure => |cl| self.callVmClosure(cl, argc, true) catch |e| {
                            std.debug.print("[VM DEBUG] tail_call error={s} proto='{s}' ip={}\n", .{
                                @errorName(e), proto.name, frame.ip - 1,
                            });
                            return e;
                        },
                        else => self.callValue(callee, argc, false) catch |e| {
                            std.debug.print("[VM DEBUG] tail_call(other) error={s} callee_tag={s} proto='{s}' ip={}\n", .{
                                @errorName(e), @tagName(callee), proto.name, frame.ip - 1,
                            });
                            return e;
                        },
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
                    if (v != .pair) {
                        std.debug.print("[VM DEBUG] car_op on non-pair: tag={s} proto='{s}' ip={}\n", .{
                            @tagName(v), proto.name, frame.ip - 1,
                        });
                        return ElzError.InvalidArgument;
                    }
                    try self.push(v.pair.car);
                },
                .cdr_op => {
                    const v = self.pop();
                    if (v != .pair) {
                        std.debug.print("[VM DEBUG] cdr_op on non-pair: tag={s} proto='{s}' ip={}\n", .{
                            @tagName(v), proto.name, frame.ip - 1,
                        });
                        return ElzError.InvalidArgument;
                    }
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
                    // DEBUG: check for wrong proto (boolean at expected-integer slot)
                    if (std.mem.eql(u8, sub_proto.name, "loop") or std.mem.eql(u8, sub_proto.name, "<let>")) {
                        if (sub_proto.constants.items.len > 1) {
                            const c1 = sub_proto.constants.items[1];
                            if (c1 == .boolean) {
                                std.debug.print("[VM DEBUG] make_closure proto='{s}' bx={} has boolean at const[1]! parent='{s}' ip={}\n", .{
                                    sub_proto.name, instr.bx, proto.name, frame.ip - 1,
                                });
                                std.debug.print("  sub_proto constants:\n", .{});
                                for (sub_proto.constants.items, 0..) |c, ci| {
                                    switch (c) {
                                        .symbol => |s| std.debug.print("    [{}] symbol '{s}'\n", .{ ci, s }),
                                        .boolean => |b| std.debug.print("    [{}] boolean {}\n", .{ ci, b }),
                                        .exact_integer => |i| std.debug.print("    [{}] integer {}\n", .{ ci, i }),
                                        else => std.debug.print("    [{}] other\n", .{ci}),
                                    }
                                }
                            }
                        }
                    }
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

    pub fn runProto(self: *VM, proto: *FuncProto, fuel: ?*u64) ElzError!Value {
        self.fuel = fuel;
        const cl = try self.interp.allocator.create(VmClosure);
        cl.* = .{ .proto = proto, .upvals = &.{} };
        self.frames[0] = .{ .closure = cl, .ip = 0, .stack_base = 0 };
        self.frame_count = 1;
        // Start with an empty working stack. The body code is responsible for
        // initialising its own locals (letrec emits load_false, let pushes init values).
        self.stack_top = 0;
        const result = self.run();
        // Close all open upvalues before the stack is freed: this copies any open
        // upvalue values into the cell so subsequent accesses via the closed pointer
        // (from callProc or runFromEval) see valid values.
        self.closeUpvaluesAbove(0);
        return result;
    }
};

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
    if (list1 == .nil) return list2;
    if (list1 != .pair) return list2;
    const new_pair = try allocator.create(core.Pair);
    new_pair.* = .{
        .car = list1.pair.car,
        .cdr = try appendLists(allocator, list1.pair.cdr, list2),
    };
    return Value{ .pair = new_pair };
}

/// Entry point that can be used to run a vm_closure with a given argument list.
pub fn runFromEval(interp: *@import("interpreter.zig").Interpreter, cl: *VmClosure, args: core.ValueList) core.ElzError!Value {
    var vm_inst = VM.init(interp) catch return core.ElzError.OutOfMemory;
    defer vm_inst.deinit();
    try vm_inst.push(Value{ .vm_closure = cl });
    for (args.items) |arg| try vm_inst.push(arg);
    try vm_inst.callVmClosure(cl, @intCast(args.items.len), false);
    const result = vm_inst.run();
    // Close all open upvalues before the stack is freed by deinit().
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
    var machine = try VM.init(interp);
    defer machine.deinit();
    machine.fuel = fuel;
    try machine.push(proc);
    for (args.items) |arg| try machine.push(arg);
    const argc: u8 = @intCast(args.items.len);
    try machine.callValue(machine.peek(argc), argc, false);
    const result = machine.run();
    // Close all open upvalues before the stack is freed by deinit().
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
