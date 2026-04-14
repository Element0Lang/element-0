const std = @import("std");
const core = @import("../core.zig");
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `current_time` returns the current Unix timestamp in seconds.
/// Syntax: (current-time)
/// Returns the number of seconds since the Unix epoch (1970-01-01 00:00:00 UTC).
pub fn current_time(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return core.Value{ .number = @floatFromInt(ts.sec) };
}

/// `current_time_ms` returns the current time in milliseconds since epoch.
/// Syntax: (current-time-ms)
/// Returns the number of milliseconds since the Unix epoch.
pub fn current_time_ms(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const timestamp_ms = @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
    return core.Value{ .number = @floatFromInt(timestamp_ms) };
}

/// `time_to_components` converts a Unix timestamp to date/time components.
/// Syntax: (time->components timestamp)
/// Returns a list: (year month day hour minute second)
/// Month is 1-12, day is 1-31.
pub fn time_to_components(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const ts_val = args.items[0];
    if (ts_val != .number) return ElzError.InvalidArgument;

    const timestamp: i64 = @intFromFloat(ts_val.number);

    // Convert timestamp to epoch seconds
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year = year_day.year;
    const month = @as(u8, @intFromEnum(month_day.month)); // 1-12
    const day = month_day.day_index + 1; // 1-31
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    // Build list: (year month day hour minute second)
    // We build it in reverse order
    const pair6 = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
    pair6.* = .{ .car = core.Value{ .number = @floatFromInt(second) }, .cdr = .nil };

    const pair5 = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
    pair5.* = .{ .car = core.Value{ .number = @floatFromInt(minute) }, .cdr = core.Value{ .pair = pair6 } };

    const pair4 = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
    pair4.* = .{ .car = core.Value{ .number = @floatFromInt(hour) }, .cdr = core.Value{ .pair = pair5 } };

    const pair3 = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
    pair3.* = .{ .car = core.Value{ .number = @floatFromInt(day) }, .cdr = core.Value{ .pair = pair4 } };

    const pair2 = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
    pair2.* = .{ .car = core.Value{ .number = @floatFromInt(month) }, .cdr = core.Value{ .pair = pair3 } };

    const pair1 = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
    pair1.* = .{ .car = core.Value{ .number = @floatFromInt(year) }, .cdr = core.Value{ .pair = pair2 } };

    return core.Value{ .pair = pair1 };
}

/// `sleep_ms` pauses execution for the specified number of milliseconds.
/// Syntax: (sleep-ms milliseconds)
/// Returns unspecified.
pub fn sleep_ms(_: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const ms_val = args.items[0];
    if (ms_val != .number) return ElzError.InvalidArgument;

    const ms = ms_val.number;
    if (ms < 0 or @floor(ms) != ms) return ElzError.InvalidArgument;

    const ns: u64 = @intFromFloat(ms * 1_000_000);
    const req: std.c.timespec = .{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = std.c.nanosleep(&req, null);

    return core.Value.unspecified;
}

test "current_time returns number" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    const args = core.ValueList.init(interp.allocator);
    const result = try current_time(&interp, interp.root_env, args, undefined);

    try testing.expect(result == .number);
    // Should be a reasonable Unix timestamp (after year 2020)
    try testing.expect(result.number > 1577836800); // 2020-01-01
}

test "current_time_ms returns number" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    const args = core.ValueList.init(interp.allocator);
    const result = try current_time_ms(&interp, interp.root_env, args, undefined);

    try testing.expect(result == .number);
    // Should be a reasonable timestamp in milliseconds
    try testing.expect(result.number > 1577836800000); // 2020-01-01 in ms
}

test "time_to_components returns list" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    // Test with a known timestamp: 2024-01-15 12:30:45 UTC
    // Unix timestamp for this is approximately 1705321845
    var args = core.ValueList.init(interp.allocator);
    try args.append(interp.allocator, core.Value{ .number = 1705321845 });

    const result = try time_to_components(&interp, interp.root_env, args, undefined);

    try testing.expect(result == .pair);

    // First element should be the year (2024)
    const year = result.pair.car;
    try testing.expect(year == .number);
    try testing.expect(year.number == 2024);
}
