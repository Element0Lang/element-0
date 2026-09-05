/// Internal record primitives backing define-record-type (defined in std.elz).
const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `%make-record-type` creates a record type descriptor.
/// Syntax: (%make-record-type name-symbol field-names-list)
pub fn make_record_type(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .symbol) return interp.fail(ElzError.InvalidArgument, "%make-record-type: expected a symbol, got {s}", .{core.typeName(args.items[0])});

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(env.allocator);
    var cur = args.items[1];
    while (cur == .pair) {
        if (cur.pair.car != .symbol) return ElzError.InvalidArgument;
        try names.append(env.allocator, try env.allocator.dupe(u8, cur.pair.car.symbol));
        cur = cur.pair.cdr;
    }
    if (cur != .nil) return interp.fail(ElzError.InvalidArgument, "%make-record-type: expected the empty list, got {s}", .{core.typeName(cur)});

    const rtd = env.allocator.create(core.RecordType) catch return ElzError.OutOfMemory;
    rtd.* = .{
        .name = try env.allocator.dupe(u8, args.items[0].symbol),
        .field_names = try names.toOwnedSlice(env.allocator),
    };
    return Value{ .record_type = rtd };
}

/// `%make-record` creates a record instance from a full list of field values.
/// Syntax: (%make-record rtd values-list)
pub fn make_record(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[0] != .record_type) return interp.fail(ElzError.InvalidArgument, "%make-record: expected a record type, got {s}", .{core.typeName(args.items[0])});
    const rtd = args.items[0].record_type;

    const fields = env.allocator.alloc(Value, rtd.field_names.len) catch return ElzError.OutOfMemory;
    var cur = args.items[1];
    for (fields) |*slot| {
        if (cur != .pair) return ElzError.WrongArgumentCount;
        slot.* = cur.pair.car;
        cur = cur.pair.cdr;
    }
    if (cur != .nil) return ElzError.WrongArgumentCount;

    const rec = env.allocator.create(core.Record) catch return ElzError.OutOfMemory;
    rec.* = .{ .rtd = rtd, .fields = fields };
    return Value{ .record = rec };
}

/// `%record-of-type?` reports whether a value is a record of the given type.
/// Syntax: (%record-of-type? x rtd)
pub fn record_of_type_p(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;
    if (args.items[1] != .record_type) return interp.fail(ElzError.InvalidArgument, "%record-of-type?: expected a record type, got {s}", .{core.typeName(args.items[1])});
    const v = args.items[0];
    return Value{ .boolean = v == .record and v.record.rtd == args.items[1].record_type };
}

fn checkedRecord(interp: *interpreter.Interpreter, args: core.ValueList) ElzError!*core.Record {
    if (args.items[0] != .record_type) return ElzError.InvalidArgument;
    const rtd = args.items[0].record_type;
    if (args.items[1] != .record or args.items[1].record.rtd != rtd) {
        return interp.fail(ElzError.InvalidArgument, "not a record of type {s}", .{rtd.name});
    }
    if (args.items[2] != .exact_integer) return ElzError.InvalidArgument;
    const idx = args.items[2].exact_integer;
    if (idx < 0 or idx >= @as(i64, @intCast(args.items[1].record.fields.len))) return ElzError.InvalidArgument;
    return args.items[1].record;
}

/// `%record-ref` reads a field by index, checking the record's type.
/// Syntax: (%record-ref rtd record index)
pub fn record_ref(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 3) return ElzError.WrongArgumentCount;
    const rec = try checkedRecord(interp, args);
    return rec.fields[@intCast(args.items[2].exact_integer)];
}

/// `%record-set!` writes a field by index, checking the record's type.
/// Syntax: (%record-set! rtd record index value)
pub fn record_set_bang(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 4) return ElzError.WrongArgumentCount;
    const rec = try checkedRecord(interp, args);
    rec.fields[@intCast(args.items[2].exact_integer)] = args.items[3];
    return Value.unspecified;
}
