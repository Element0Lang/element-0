/// Bytevector primitives (R7RS section 6.9).
const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

fn newBytevector(allocator: std.mem.Allocator, items: []u8) ElzError!Value {
    const bv = allocator.create(core.Bytevector) catch return ElzError.OutOfMemory;
    bv.* = .{ .items = items };
    return Value{ .bytevector = bv };
}

fn byteArg(v: Value) ElzError!u8 {
    if (v != .exact_integer or v.exact_integer < 0 or v.exact_integer > 255) return ElzError.InvalidArgument;
    return @intCast(v.exact_integer);
}

/// Resolves optional [start [end]] arguments against a length.
fn rangeArgs(args: []const Value, len: usize) ElzError!struct { start: usize, end: usize } {
    var start: usize = 0;
    var end: usize = len;
    if (args.len >= 1) {
        if (args[0] != .exact_integer or args[0].exact_integer < 0) return ElzError.InvalidArgument;
        start = @intCast(args[0].exact_integer);
    }
    if (args.len >= 2) {
        if (args[1] != .exact_integer or args[1].exact_integer < 0) return ElzError.InvalidArgument;
        end = @intCast(args[1].exact_integer);
    }
    if (args.len > 2) return ElzError.WrongArgumentCount;
    if (start > end or end > len) return ElzError.InvalidArgument;
    return .{ .start = start, .end = end };
}

/// Syntax: (bytevector byte ...)
pub fn bytevector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    const items = env.allocator.alloc(u8, args.items.len) catch return ElzError.OutOfMemory;
    for (args.items, items) |arg, *slot| slot.* = try byteArg(arg);
    return newBytevector(env.allocator, items);
}

/// Syntax: (make-bytevector k) or (make-bytevector k fill)
pub fn make_bytevector(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1 or args.items.len > 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .exact_integer or args.items[0].exact_integer < 0) return ElzError.InvalidArgument;
    const len: usize = @intCast(args.items[0].exact_integer);
    const fill: u8 = if (args.items.len == 2) try byteArg(args.items[1]) else 0;
    const items = env.allocator.alloc(u8, len) catch return ElzError.OutOfMemory;
    @memset(items, fill);
    return newBytevector(env.allocator, items);
}

/// Syntax: (bytevector? obj)
pub fn bytevector_p(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    return Value{ .boolean = args.items[0] == .bytevector };
}

/// Syntax: (bytevector-length bv)
pub fn bytevector_length(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector) return ElzError.InvalidArgument;
    return Value{ .exact_integer = @intCast(args.items[0].bytevector.items.len) };
}

/// Syntax: (bytevector-u8-ref bv k)
pub fn bytevector_u8_ref(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector or args.items[1] != .exact_integer) return ElzError.InvalidArgument;
    const items = args.items[0].bytevector.items;
    const k = args.items[1].exact_integer;
    if (k < 0 or k >= @as(i64, @intCast(items.len))) return ElzError.InvalidArgument;
    return Value{ .exact_integer = items[@intCast(k)] };
}

/// Syntax: (bytevector-u8-set! bv k byte)
pub fn bytevector_u8_set_bang(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector or args.items[1] != .exact_integer) return ElzError.InvalidArgument;
    const items = args.items[0].bytevector.items;
    const k = args.items[1].exact_integer;
    if (k < 0 or k >= @as(i64, @intCast(items.len))) return ElzError.InvalidArgument;
    items[@intCast(k)] = try byteArg(args.items[2]);
    return Value.unspecified;
}

/// Syntax: (bytevector-copy bv [start [end]])
pub fn bytevector_copy(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector) return ElzError.InvalidArgument;
    const src = args.items[0].bytevector.items;
    const r = try rangeArgs(args.items[1..], src.len);
    const items = env.allocator.dupe(u8, src[r.start..r.end]) catch return ElzError.OutOfMemory;
    return newBytevector(env.allocator, items);
}

/// Syntax: (bytevector-copy! to at from [start [end]])
pub fn bytevector_copy_bang(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 3) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector or args.items[1] != .exact_integer or args.items[2] != .bytevector) return ElzError.InvalidArgument;
    const to = args.items[0].bytevector.items;
    if (args.items[1].exact_integer < 0) return ElzError.InvalidArgument;
    const at: usize = @intCast(args.items[1].exact_integer);
    const from = args.items[2].bytevector.items;
    const r = try rangeArgs(args.items[3..], from.len);
    const count = r.end - r.start;
    if (at + count > to.len) return ElzError.InvalidArgument;
    // memmove semantics: correct for overlapping ranges within one bytevector.
    if (at <= r.start) {
        std.mem.copyForwards(u8, to[at .. at + count], from[r.start..r.end]);
    } else {
        std.mem.copyBackwards(u8, to[at .. at + count], from[r.start..r.end]);
    }
    return Value.unspecified;
}

/// Syntax: (bytevector-append bv ...)
pub fn bytevector_append(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    var total: usize = 0;
    for (args.items) |arg| {
        if (arg != .bytevector) return ElzError.InvalidArgument;
        total += arg.bytevector.items.len;
    }
    const items = env.allocator.alloc(u8, total) catch return ElzError.OutOfMemory;
    var offset: usize = 0;
    for (args.items) |arg| {
        const src = arg.bytevector.items;
        @memcpy(items[offset .. offset + src.len], src);
        offset += src.len;
    }
    return newBytevector(env.allocator, items);
}

/// Syntax: (utf8->string bv [start [end]])
pub fn utf8_to_string(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .bytevector) return ElzError.InvalidArgument;
    const src = args.items[0].bytevector.items;
    const r = try rangeArgs(args.items[1..], src.len);
    const slice = src[r.start..r.end];
    if (!std.unicode.utf8ValidateSlice(slice)) return ElzError.InvalidArgument;
    const copy = env.allocator.dupe(u8, slice) catch return ElzError.OutOfMemory;
    return (try core.makeString(env.allocator, copy));
}

/// Syntax: (string->utf8 str [start [end]])
/// start and end are character indexes, per R7RS.
pub fn string_to_utf8(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len < 1) return ElzError.WrongArgumentCount;
    if (args.items[0] != .string) return ElzError.InvalidArgument;
    const str = args.items[0].string.bytes;
    const char_len = std.unicode.utf8CountCodepoints(str) catch return ElzError.InvalidArgument;
    const r = try rangeArgs(args.items[1..], char_len);

    var byte_start: usize = 0;
    var byte_end: usize = str.len;
    var char_index: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (char_index == r.start) byte_start = i;
        if (char_index == r.end) {
            byte_end = i;
            break;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(str[i]) catch return ElzError.InvalidArgument;
        i += seq_len;
        char_index += 1;
    }
    if (char_index < r.end) byte_end = str.len;
    if (r.start == char_len) byte_start = str.len;

    const items = env.allocator.dupe(u8, str[byte_start..byte_end]) catch return ElzError.OutOfMemory;
    return newBytevector(env.allocator, items);
}
