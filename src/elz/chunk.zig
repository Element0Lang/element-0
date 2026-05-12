const std = @import("std");
const core = @import("core.zig");
const Value = core.Value;

pub const OpCode = enum(u8) {
    // --- Constants ---
    load_const, // bx = constants index
    load_nil,
    load_true,
    load_false,
    load_unspecified,

    // --- Variables ---
    load_local, // a = stack slot relative to frame base
    store_local, // a = stack slot (leaves value on stack)
    load_upval, // a = upvalue index in closure
    store_upval, // a = upvalue index (leaves value on stack)
    load_global, // bx = constant index of name string
    store_global, // bx = constant index of name string (leaves value on stack)
    define_global, // bx = constant index of name string (pops value)

    // --- Control flow ---
    jump, // offset = signed relative offset from *next* instruction
    jump_if_false, // offset = signed relative; pops condition

    // --- Calls & return ---
    call, // a = argc; callee is at stack[top - argc - 1]
    tail_call, // a = argc; tail-call optimised
    return_val, // returns top of stack, pops call frame

    // --- Stack manipulation ---
    pop, // discard top of stack
    dup, // duplicate top of stack
    swap, // swap top two stack values

    // --- Pair / list ---
    cons, // pops cdr then car (car pushed first), pushes pair
    car_op, // replace top with car
    cdr_op, // replace top with cdr

    // --- Closures & upvalues ---
    make_closure, // bx = sub_proto index; followed by `b` CAPTURE instructions
    capture_local, // a = local slot  — arg to make_closure
    capture_upval, // a = upvalue index — arg to make_closure
    close_upval, // a = local slot; lift to heap before it goes out of scope

    // --- Aggregate constructors ---
    make_list, // a = count; pops count items (first item pushed last), pushes list
    make_vector, // a = count; pops count items, pushes vector

    // --- Quasiquote helpers ---
    append_lists, // pops two lists, pushes appended list (for splicing)

    // --- Multiple values ---
    values_pack, // a = count; pops count items, pushes multi_values
};

/// One bytecode instruction. Fixed 4 bytes.
/// `a` and `b` are 8-bit unsigned operands.
/// `bx` is a 16-bit unsigned operand (wider constant/slot index).
/// `offset` is a signed 16-bit jump offset.
pub const Instruction = struct {
    op: OpCode,
    a: u8 = 0,
    b: u8 = 0,
    bx: u16 = 0,
    offset: i16 = 0,

    pub fn init_op(op: OpCode) Instruction {
        return .{ .op = op };
    }

    pub fn init_a(op: OpCode, a: u8) Instruction {
        return .{ .op = op, .a = a };
    }

    pub fn init_bx(op: OpCode, bx: u16) Instruction {
        return .{ .op = op, .bx = bx };
    }

    pub fn init_offset(op: OpCode, offset: i16) Instruction {
        return .{ .op = op, .offset = offset };
    }
};

/// Describes how a closure captures one upvalue from its enclosing scope.
/// `is_local = true`: capture the local at `index` in the *immediately* enclosing function.
/// `is_local = false`: re-capture upvalue `index` from the *immediately* enclosing closure.
pub const UpvalDesc = struct {
    is_local: bool,
    index: u8,
};

/// A compiled function (the static, shareable part of a closure).
pub const FuncProto = struct {
    /// Debug name (usually the `define` name or "<lambda>").
    name: []const u8,
    /// Number of fixed positional parameters.
    arity: u8,
    /// If true, the last parameter collects remaining arguments as a list.
    variadic: bool,
    /// Bytecode instructions.
    instructions: std.ArrayList(Instruction),
    /// Constant pool (literals, symbol names used as globals, nested FuncProtos).
    constants: std.ArrayList(Value),
    /// Upvalue capture descriptors, one per upvalue used by this function.
    upval_descs: std.ArrayList(UpvalDesc),
    /// Number of local variable slots needed (excluding parameters).
    local_count: u8,
    /// Nested function prototypes compiled inside this one.
    sub_protos: std.ArrayList(*FuncProto),
    /// Allocator used for all dynamic storage above.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) FuncProto {
        return .{
            .name = name,
            .arity = 0,
            .variadic = false,
            .instructions = .empty,
            .constants = .empty,
            .upval_descs = .empty,
            .local_count = 0,
            .sub_protos = .empty,
            .allocator = allocator,
        };
    }

    /// Append an instruction and return its index.
    pub fn emit(self: *FuncProto, instr: Instruction) !usize {
        const idx = self.instructions.items.len;
        try self.instructions.append(self.allocator, instr);
        return idx;
    }

    /// Add a constant to the pool and return its index. Reuses existing equal constants.
    pub fn addConst(self: *FuncProto, val: Value) !u16 {
        // Cheap deduplication for symbols and strings only (common case).
        for (self.constants.items, 0..) |c, i| {
            if (c == .symbol and val == .symbol and
                std.mem.eql(u8, c.symbol, val.symbol)) return @intCast(i);
            if (c == .string and val == .string and
                std.mem.eql(u8, c.string, val.string)) return @intCast(i);
        }
        const idx: u16 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, val);
        return idx;
    }

    /// Patch a previously emitted jump instruction's offset.
    pub fn patchJump(self: *FuncProto, jump_idx: usize) void {
        const target: i16 = @intCast(self.instructions.items.len - jump_idx - 1);
        self.instructions.items[jump_idx].offset = target;
    }

    pub fn deinit(self: *FuncProto) void {
        for (self.sub_protos.items) |sp| {
            sp.deinit();
            self.allocator.destroy(sp);
        }
        self.instructions.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.upval_descs.deinit(self.allocator);
        self.sub_protos.deinit(self.allocator);
    }
};

test "chunk basic emit and patch" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var proto = FuncProto.init(alloc, "test");
    defer proto.deinit();

    const idx = try proto.emit(Instruction.init_offset(.jump, 0));
    _ = try proto.emit(Instruction.init_op(.load_nil));
    proto.patchJump(idx);

    try testing.expectEqual(@as(i16, 1), proto.instructions.items[0].offset);
    try testing.expectEqual(OpCode.load_nil, proto.instructions.items[1].op);
}
