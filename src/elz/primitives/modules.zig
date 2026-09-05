const std = @import("std");
const core = @import("../core.zig");
const Value = core.Value;
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `module_ref` is the implementation of the `module-ref` primitive function.
/// It retrieves an exported value from a module.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
/// - `args`: A `ValueList` containing two elements: the module object and the symbol to look up.
///
/// Returns:
/// The value of the exported symbol, or an error if the symbol is not found or the arguments are invalid.
pub fn module_ref(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const module_val = args.items[0];
    const symbol_val = args.items[1];

    if (module_val != .module) {
        return interp.failWith(ElzError.InvalidArgument, "First argument to module-ref must be a module object.");
    }
    if (symbol_val != .symbol) {
        return interp.failWith(ElzError.InvalidArgument, "Second argument to module-ref must be a symbol.");
    }

    const module = module_val.module;
    const name = symbol_val.symbol;

    if (module.exports.get(name)) |value| {
        return value;
    } else {
        return interp.fail(ElzError.SymbolNotFound, "Module does not export symbol '{s}'.", .{name});
    }
}

test "module primitives" {
    const allocator = std.testing.allocator;
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // Test module-ref
    var module = try allocator.create(core.Module);
    defer allocator.destroy(module);
    module.* = .{ .exports = std.StringHashMap(Value).init(allocator) };
    defer module.exports.deinit();
    try module.exports.put("x", Value{ .number = 42 });

    var args = core.ValueList.init(allocator);
    defer args.deinit();
    try args.append(Value{ .module = module });
    try args.append(Value{ .symbol = "x" });

    const result = try module_ref(&interp, interp.root_env, args, &fuel);
    try testing.expectEqual(@as(f64, 42), result.number);

    // Test symbol not found
    args.clearRetainingCapacity();
    try args.append(Value{ .module = module });
    try args.append(Value{ .symbol = "y" });
    const err = module_ref(&interp, interp.root_env, args, &fuel);
    try testing.expectError(ElzError.SymbolNotFound, err);
}
