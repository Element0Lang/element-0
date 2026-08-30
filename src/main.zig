const std = @import("std");
const elz = @import("elz");
const chilli = @import("chilli");

const builtin = @import("builtin");
const bestline = @cImport({
    @cInclude("bestline.h");
});

const filetime_unix_offset: i64 = 116444736000000000;

fn currentTimeMs() i64 {
    if (comptime builtin.os.tag == .windows) {
        const filetime = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(filetime - filetime_unix_offset, 10_000);
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
    }
}

fn displayValue(_: *elz.Interpreter, value: elz.Value, writer: anytype) !void {
    switch (value) {
        .string => |s| {
            try writer.writeAll(s);
            if (s.len == 0 or s[s.len - 1] != '\n') {
                try writer.writeAll("\n");
            }
        },
        else => {
            try elz.write(value, writer);
            try writer.writeAll("\n");
        },
    }
}

fn exec(interpreter: *elz.Interpreter, source: []const u8, source_name: []const u8) !void {
    var forms = elz.parser.readAllTracked(source, interpreter.allocator, source_name, &interpreter.source_locations) catch |err| {
        std.debug.print("Parse Error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer forms.deinit(interpreter.allocator);
    if (forms.items.len == 0) return;

    var last_result: elz.Value = .nil;
    for (forms.items) |form| {
        var fuel: u64 = std.math.maxInt(u64);
        interpreter.last_error_message = null;
        last_result = interpreter.evalForm(&form, &fuel) catch |err| {
            var buffer: [4096]u8 = undefined;
            const stdout_file = std.Io.File.stdout();
            var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
            const stdout = &stdout_writer.interface;
            try stdout.writeAll("--- Runtime Error ---\n");
            try stdout.print("ErrorCode: {s}\n", .{@errorName(err)});
            if (interpreter.last_error_message) |msg| {
                try stdout.print("Message: {s}\n", .{msg});
            }
            if (interpreter.last_error_line) |line| {
                const file = interpreter.last_error_file orelse "?";
                try stdout.print("At: {s}:{d}\n", .{ file, line });
                interpreter.last_error_line = null;
                interpreter.last_error_file = null;
            }
            try stdout.writeAll("In form: ");
            try elz.write(form, stdout);
            try stdout.writeAll("\n");
            try stdout.flush();
            return;
        };
    }

    var buffer: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
    const stdout = &stdout_writer.interface;
    if (last_result != .unspecified) {
        try displayValue(interpreter, last_result, stdout);
        try stdout.flush();
    }
}

fn repl(interpreter: *elz.Interpreter) !void {
    while (true) {
        const line = bestline.bestlineWithHistory("> ", "history.txt");
        if (line == null) return;
        defer bestline.bestlineFree(line);

        const line_slice = std.mem.sliceTo(line, 0);
        if (line_slice.len == 0) continue;
        if (std.mem.eql(u8, line_slice, ".exit")) return;

        eval_line: {
            var forms = elz.parser.readAll(line_slice, interpreter.allocator) catch |err| {
                var buffer: [4096]u8 = undefined;
                const stdout_file = std.Io.File.stdout();
                var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
                const stdout = &stdout_writer.interface;
                try stdout.print("Parse Error: {s}\n", .{@errorName(err)});
                try stdout.flush();
                break :eval_line;
            };
            defer forms.deinit(interpreter.allocator);

            if (forms.items.len == 0) break :eval_line;

            var last_result: elz.Value = .nil;
            for (forms.items) |form| {
                var fuel: u64 = std.math.maxInt(u64);
                interpreter.last_error_message = null;
                last_result = interpreter.evalForm(&form, &fuel) catch |err| {
                    var buffer: [4096]u8 = undefined;
                    const stdout_file = std.Io.File.stdout();
                    var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
                    const stdout = &stdout_writer.interface;
                    if (interpreter.last_error_message) |msg| {
                        try stdout.print("Error: {s}\n", .{msg});
                    } else {
                        try stdout.print("Error: {s}\n", .{@errorName(err)});
                    }
                    try stdout.flush();
                    break :eval_line;
                };
            }
            var buffer: [4096]u8 = undefined;
            const stdout_file = std.Io.File.stdout();
            var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
            const stdout = &stdout_writer.interface;
            if (last_result != .unspecified) {
                try displayValue(interpreter, last_result, stdout);
                try stdout.flush();
            }
        }
    }
}

fn runBench(source: []const u8, filename: []const u8, iters: usize, gpa: std.mem.Allocator) !void {
    const times = try gpa.alloc(i64, iters);
    defer gpa.free(times);

    for (times) |*t| {
        var interp = try elz.Interpreter.init(.{});
        defer interp.deinit();
        const start = currentTimeMs();
        var fuel: u64 = std.math.maxInt(u64);
        _ = interp.evalString(source, &fuel) catch {};
        t.* = currentTimeMs() - start;
    }

    std.mem.sort(i64, times, {}, std.sort.asc(i64));
    const best = times[0];
    const worst = times[times.len - 1];
    const median = times[times.len / 2];
    const p95 = times[@min(times.len - 1, times.len * 95 / 100)];

    const name = std.fs.path.stem(std.fs.path.basename(filename));
    std.debug.print("{s}:  best {d}ms  median {d}ms  p95 {d}ms  worst {d}ms\n", .{ name, best, median, p95, worst });
}

fn rootExec(ctx: chilli.CommandContext) !void {
    const interpreter = ctx.getContextData(elz.Interpreter).?;

    // Check verbose flag
    const verbose = if (ctx.command.getFlagValue("verbose")) |v| v.Bool else false;

    const bench_iters: i64 = if (ctx.command.getFlagValue("bench")) |v| v.Int else 0;

    if (ctx.command.getFlagValue("file")) |flag_value| {
        if (flag_value.String.len > 0) {
            const filename = flag_value.String;

            if (verbose) {
                std.debug.print("[VERBOSE] Opening file: {s}\n", .{filename});
            }

            const source = std.Io.Dir.cwd().readFileAlloc(interpreter.io, filename, interpreter.allocator, .limited(1024 * 1024)) catch |err| {
                std.debug.print("Error: Failed to read file '{s}': {s}\n", .{ filename, @errorName(err) });
                return err;
            };
            defer interpreter.allocator.free(source);

            if (bench_iters > 0) {
                var gpa: std.heap.DebugAllocator(.{}) = .init;
                defer _ = gpa.deinit();
                try runBench(source, filename, @intCast(bench_iters), gpa.allocator());
                return;
            }

            if (verbose) {
                std.debug.print("[VERBOSE] Executing {d} bytes of source code...\n", .{source.len});
            }

            try exec(interpreter, source, filename);
            return;
        }
    }

    if (verbose) {
        std.debug.print("[VERBOSE] Starting REPL mode...\n", .{});
    }

    try repl(interpreter);
}

/// The main entry point for the `elz` executable.
/// This function initializes the interpreter and the command-line interface.
/// It can either start a REPL or execute a source file, based on the command-line arguments.
pub fn main(init: std.process.Init.Minimal) anyerror!void {
    const interpreter_ptr = try elz.gc_allocator.create(elz.Interpreter);
    interpreter_ptr.* = try elz.Interpreter.init(.{});
    elz.gc_add_roots(@intFromPtr(interpreter_ptr), @intFromPtr(interpreter_ptr) + @sizeOf(elz.Interpreter));

    // Capture argv for (command-line), in order.
    {
        var arg_it = try std.process.Args.Iterator.initAllocator(init.args, elz.gc_allocator);
        defer arg_it.deinit();
        var argv_list = std.ArrayListUnmanaged(elz.core.Value).empty;
        defer argv_list.deinit(elz.gc_allocator);
        while (arg_it.next()) |arg| {
            const copy = try elz.gc_allocator.dupe(u8, arg);
            try argv_list.append(elz.gc_allocator, elz.core.Value{ .string = copy });
        }
        var argv: elz.core.Value = .nil;
        var i = argv_list.items.len;
        while (i > 0) {
            i -= 1;
            const link = try elz.gc_allocator.create(elz.core.Pair);
            link.* = .{ .car = argv_list.items[i], .cdr = argv };
            argv = elz.core.Value{ .pair = link };
        }
        interpreter_ptr.command_line = argv;
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var root_cmd = try chilli.Command.init(gpa.allocator(), .{
        .name = "elz",
        .description = "Element 0 is a Lisp dialect implemented in Zig",
        .version = "0.1.0-alpha.5",
        .exec = rootExec,
    });
    defer root_cmd.deinit();

    try root_cmd.addFlag(.{
        .name = "file",
        .shortcut = 'f',
        .description = "The Element 0 source file to execute",
        .type = .String,
        .default_value = .{ .String = "" },
    });

    try root_cmd.addFlag(.{
        .name = "verbose",
        .shortcut = 'v',
        .description = "Enable verbose output for debugging",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    try root_cmd.addFlag(.{
        .name = "bench",
        .shortcut = 'b',
        .description = "Run the file N times and print timing statistics (best/median/p95/worst)",
        .type = .Int,
        .default_value = .{ .Int = 0 },
    });

    try root_cmd.run(init.args, interpreter_ptr);
}
