//! This module provides the Foreign Function Interface (FFI) for Element 0.
//! It allows Zig functions to be called from Element 0 code.

const std = @import("std");
const core = @import("core.zig");
const ElzError = @import("errors.zig").ElzError;

/// `Caster` is a generic struct that provides a `cast` function to convert a `core.Value`
/// to a specified Zig type `T`. This is a core component of the FFI mechanism, used
/// to marshal data from the Elz world to the Zig world.
///
/// Parameters:
/// - `T`: The Zig type to cast to. Supported types are `.float` and `.int`.
pub fn Caster(comptime T: type) type {
    return struct {
        /// Casts a `core.Value` to the specified Zig type `T`.
        ///
        /// Parameters:
        /// - `v`: The `core.Value` to cast.
        ///
        /// Returns:
        /// The casted value of type `T`, or `ElzError.InvalidArgument` if the `core.Value`
        /// is of an incompatible type or out of range.
        pub fn cast(v: core.Value) ElzError!T {
            return switch (@typeInfo(T)) {
                .float => switch (v) {
                    .number => |n| @floatCast(n),
                    else => ElzError.InvalidArgument,
                },
                .int => |int_info| switch (v) {
                    .number => |n| {
                        if (std.math.isNan(n) or std.math.isInf(n)) {
                            return ElzError.InvalidArgument;
                        }
                        if (@floor(n) != n) {
                            return ElzError.InvalidArgument;
                        }
                        const min_val: f64 = if (int_info.signedness == .signed)
                            -@as(f64, @floatFromInt(@as(i128, 1) << int_info.bits - 1))
                        else
                            0;
                        const max_val: f64 = @floatFromInt((@as(u128, 1) << int_info.bits) - 1);
                        if (n < min_val or n > max_val) {
                            return ElzError.InvalidArgument;
                        }
                        return @intFromFloat(n);
                    },
                    else => ElzError.InvalidArgument,
                },
                .bool => switch (v) {
                    .boolean => |b| b,
                    else => ElzError.InvalidArgument,
                },
                .pointer => |ptr_info| {
                    if (ptr_info.size == .Slice and ptr_info.child == u8) {
                        // []const u8 - extract from string value
                        return switch (v) {
                            .string => |s| s,
                            .symbol => |s| s,
                            else => ElzError.InvalidArgument,
                        };
                    } else {
                        @compileError("Unsupported pointer type for FFI casting: " ++ @typeName(T));
                    }
                },
                .optional => |opt_info| {
                    if (v == .nil) return null;
                    const InnerCaster = Caster(opt_info.child);
                    return InnerCaster.cast(v) catch return ElzError.InvalidArgument;
                },
                else => @compileError("Unsupported type for FFI casting: " ++ @typeName(T)),
            };
        }
    };
}

/// `makeForeignFunc` wraps a Zig function into an Elz foreign procedure.
/// This function uses comptime reflection to generate a wrapper based on the
/// signature of the provided Zig function. The wrapper handles the conversion
/// of arguments from Elz `Value`s to Zig types and the conversion of the
/// return value from a Zig type to an Elz `Value`.
///
/// Supported function signatures are:
/// - Functions with 0, 1, or 2 arguments of type `f64` or integer.
/// - Variadic functions that take `std.mem.Allocator` and `[]const core.Value` as arguments.
///
/// Parameters:
/// - `F`: The Zig function to wrap. This must be a comptime-known value.
///
/// Returns:
/// A pointer to the wrapped function, which is compatible with `core.Value.foreign_procedure`.
pub fn makeForeignFunc(comptime F: anytype) *const fn (env: *core.Environment, args: core.ValueList) anyerror!core.Value {
    const FInfo = @typeInfo(@TypeOf(F)).@"fn";

    if (FInfo.params.len == 2 and
        FInfo.params[0].type.? == std.mem.Allocator and
        FInfo.params[1].type.? == []const core.Value)
    {
        return ffi_wrap_variadic(F, FInfo);
    }

    return switch (FInfo.params.len) {
        0 => ffi_wrap_0(F, FInfo),
        1 => ffi_wrap_1(F, FInfo),
        2 => ffi_wrap_2(F, FInfo),
        else => @compileError("Unsupported number of arguments for FFI function. Only 0, 1, 2 or variadic slice are supported."),
    };
}

/// Wraps a Zig function with zero arguments.
/// This is a helper function for `makeForeignFunc`.
///
/// - `F`: The Zig function to wrap.
/// - `FInfo`: The function type information.
/// - `return`: A pointer to the wrapped function.
fn ffi_wrap_0(comptime F: anytype, comptime FInfo: std.builtin.Type.Fn) *const fn (env: *core.Environment, args: core.ValueList) anyerror!core.Value {
    const call = struct {
        fn call(env: *core.Environment, args: core.ValueList) anyerror!core.Value {
            if (args.items.len != 0) return ElzError.WrongArgumentCount;
            const ReturnTypeInfo = @typeInfo(FInfo.return_type.?);
            if (comptime ReturnTypeInfo == .error_union) {
                const result = F() catch |err| return err;
                return valueFromNative(env.allocator, result);
            } else {
                const result = F();
                return valueFromNative(env.allocator, result);
            }
        }
    }.call;
    return &call;
}

/// Wraps a Zig function with one argument.
/// This is a helper function for `makeForeignFunc`.
///
/// - `F`: The Zig function to wrap.
/// - `FInfo`: The function type information.
/// - `return`: A pointer to the wrapped function.
fn ffi_wrap_1(comptime F: anytype, comptime FInfo: std.builtin.Type.Fn) *const fn (env: *core.Environment, args: core.ValueList) anyerror!core.Value {
    const P1 = FInfo.params[0].type.?;
    const call = struct {
        fn call(env: *core.Environment, args: core.ValueList) anyerror!core.Value {
            if (args.items.len != 1) return ElzError.WrongArgumentCount;
            const p1 = try Caster(P1).cast(args.items[0]);
            const ReturnTypeInfo = @typeInfo(FInfo.return_type.?);
            if (comptime ReturnTypeInfo == .error_union) {
                const result = F(p1) catch |err| return err;
                return valueFromNative(env.allocator, result);
            } else {
                const result = F(p1);
                return valueFromNative(env.allocator, result);
            }
        }
    }.call;
    return &call;
}

/// Wraps a Zig function with two arguments.
/// This is a helper function for `makeForeignFunc`.
///
/// - `F`: The Zig function to wrap.
/// - `FInfo`: The function type information.
/// - `return`: A pointer to the wrapped function.
fn ffi_wrap_2(comptime F: anytype, comptime FInfo: std.builtin.Type.Fn) *const fn (env: *core.Environment, args: core.ValueList) anyerror!core.Value {
    const P1 = FInfo.params[0].type.?;
    const P2 = FInfo.params[1].type.?;
    const call = struct {
        fn call(env: *core.Environment, args: core.ValueList) anyerror!core.Value {
            if (args.items.len != 2) return ElzError.WrongArgumentCount;
            const p1 = try Caster(P1).cast(args.items[0]);
            const p2 = try Caster(P2).cast(args.items[1]);
            const ReturnTypeInfo = @typeInfo(FInfo.return_type.?);
            if (comptime ReturnTypeInfo == .error_union) {
                const result = F(p1, p2) catch |err| return err;
                return valueFromNative(env.allocator, result);
            } else {
                const result = F(p1, p2);
                return valueFromNative(env.allocator, result);
            }
        }
    }.call;
    return &call;
}

/// Wraps a variadic Zig function.
/// This is a helper function for `makeForeignFunc`.
///
/// - `F`: The Zig function to wrap.
/// - `FInfo`: The function type information.
/// - `return`: A pointer to the wrapped function.
fn ffi_wrap_variadic(comptime F: anytype, comptime FInfo: std.builtin.Type.Fn) *const fn (env: *core.Environment, args: core.ValueList) anyerror!core.Value {
    const call = struct {
        fn call(env: *core.Environment, args: core.ValueList) anyerror!core.Value {
            const ReturnTypeInfo = @typeInfo(FInfo.return_type.?);
            if (comptime ReturnTypeInfo == .error_union) {
                const result = F(env.allocator, args.items) catch |err| return err;
                return valueFromNative(env.allocator, result);
            } else {
                const result = F(env.allocator, args.items);
                return valueFromNative(env.allocator, result);
            }
        }
    }.call;
    return &call;
}

/// Converts a native Zig value to a `core.Value`.
///
/// - `allocator`: The memory allocator to use.
/// - `value`: The native Zig value to convert.
/// - `return`: The converted `core.Value`.
fn valueFromNative(allocator: std.mem.Allocator, value: anytype) core.Value {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .void => core.Value.nil,
        .float, .comptime_float => core.Value{ .number = @floatCast(value) },
        .int, .comptime_int => core.Value{ .number = @floatFromInt(value) },
        .bool => core.Value{ .boolean = value },
        .pointer => |ptr_info| {
            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                return core.Value{ .string = allocator.dupe(u8, value) catch return core.Value.nil };
            } else {
                @compileError("Unsupported pointer return type for FFI: " ++ @typeName(T));
            }
        },
        .optional => {
            if (value) |v| {
                return valueFromNative(allocator, v);
            } else {
                return core.Value.nil;
            }
        },
        .@"union" => {
            if (T == core.Value) {
                return value;
            } else {
                @compileError("Unsupported union return type for FFI: " ++ @typeName(T));
            }
        },
        else => @compileError("Unsupported return type for FFI: " ++ @typeName(T)),
    };
}

test "Caster float from number" {
    const result = try Caster(f32).cast(core.Value{ .number = 3.14 });
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), result, 0.001);
}

test "Caster float from non-number" {
    const result = Caster(f32).cast(core.Value{ .boolean = true });
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "Caster int from valid number" {
    const result = try Caster(i32).cast(core.Value{ .number = 42 });
    try std.testing.expectEqual(@as(i32, 42), result);
}

test "Caster int from negative number" {
    const result = try Caster(i32).cast(core.Value{ .number = -100 });
    try std.testing.expectEqual(@as(i32, -100), result);
}

test "Caster int from fractional number" {
    const result = Caster(i32).cast(core.Value{ .number = 3.14 });
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "Caster int from NaN" {
    const result = Caster(i32).cast(core.Value{ .number = std.math.nan(f64) });
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "Caster int from Infinity" {
    const result = Caster(i32).cast(core.Value{ .number = std.math.inf(f64) });
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "Caster u8 out of range" {
    // 256 is out of range for u8
    const result = Caster(u8).cast(core.Value{ .number = 256 });
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "Caster u8 negative" {
    // Negative is out of range for u8
    const result = Caster(u8).cast(core.Value{ .number = -1 });
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "Caster u8 valid" {
    const result = try Caster(u8).cast(core.Value{ .number = 255 });
    try std.testing.expectEqual(@as(u8, 255), result);
}

// Test makeForeignFunc with a simple function
fn testAdd(a: f64, b: f64) f64 {
    return a + b;
}

test "makeForeignFunc with 2-arg function" {
    const wrapped = makeForeignFunc(testAdd);
    const allocator = std.testing.allocator;

    // Create environment
    const env = try allocator.create(core.Environment);
    env.* = .{
        .bindings = std.StringHashMap(core.Value).init(allocator),
        .outer = null,
        .allocator = allocator,
    };
    defer allocator.destroy(env);
    defer env.bindings.deinit();

    // Create args list
    var args = core.ValueList.init(allocator);
    defer args.deinit(allocator);
    try args.append(allocator, core.Value{ .number = 3 });
    try args.append(allocator, core.Value{ .number = 4 });

    const result = try wrapped(env, args);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 7), result.number);
}

fn testSquare(x: f64) f64 {
    return x * x;
}

test "Caster bool from boolean" {
    const result = try Caster(bool).cast(core.Value{ .boolean = true });
    try std.testing.expect(result == true);

    const result2 = try Caster(bool).cast(core.Value{ .boolean = false });
    try std.testing.expect(result2 == false);
}

test "Caster bool from non-boolean" {
    const result = Caster(bool).cast(core.Value{ .number = 1 });
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "Caster string from string value" {
    const result = try Caster([]const u8).cast(core.Value{ .string = "hello" });
    try std.testing.expectEqualStrings("hello", result);
}

test "Caster string from symbol value" {
    const result = try Caster([]const u8).cast(core.Value{ .symbol = "foo" });
    try std.testing.expectEqualStrings("foo", result);
}

test "Caster string from non-string" {
    const result = Caster([]const u8).cast(core.Value{ .number = 42 });
    try std.testing.expectError(ElzError.InvalidArgument, result);
}

test "Caster optional from value" {
    const result = try Caster(?f64).cast(core.Value{ .number = 42 });
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 42), result.?);
}

test "Caster optional from nil" {
    const result = try Caster(?f64).cast(core.Value.nil);
    try std.testing.expect(result == null);
}

test "valueFromNative string" {
    const allocator = std.testing.allocator;
    const result = valueFromNative(allocator, @as([]const u8, "hello"));
    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("hello", result.string);
    allocator.free(result.string);
}

test "valueFromNative optional some" {
    const allocator = std.testing.allocator;
    const result = valueFromNative(allocator, @as(?f64, 42.0));
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 42), result.number);
}

test "valueFromNative optional null" {
    const allocator = std.testing.allocator;
    const result = valueFromNative(allocator, @as(?f64, null));
    try std.testing.expect(result == .nil);
}

test "makeForeignFunc with 1-arg function" {
    const wrapped = makeForeignFunc(testSquare);
    const allocator = std.testing.allocator;

    const env = try allocator.create(core.Environment);
    env.* = .{
        .bindings = std.StringHashMap(core.Value).init(allocator),
        .outer = null,
        .allocator = allocator,
    };
    defer allocator.destroy(env);
    defer env.bindings.deinit();

    var args = core.ValueList.init(allocator);
    defer args.deinit(allocator);
    try args.append(allocator, core.Value{ .number = 5 });

    const result = try wrapped(env, args);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 25), result.number);
}
