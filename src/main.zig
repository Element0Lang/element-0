const std = @import("std");
const elz = @import("elz");
const chilli = @import("chilli");

const builtin = @import("builtin");
const linenoise = if (builtin.os.tag != .windows) @cImport({
    @cInclude("linenoise.h");
}) else struct {};

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

fn exec(interpreter: *elz.Interpreter, source: []const u8) !void {
    var forms = elz.parser.readAll(source, interpreter.allocator) catch |err| {
        std.debug.print("Parse Error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer forms.deinit(interpreter.allocator);
    if (forms.items.len == 0) return;

    var last_result: elz.Value = .nil;
    for (forms.items) |form| {
        var fuel: u64 = 1_000_000;
        last_result = elz.eval.eval(interpreter, &form, interpreter.root_env, &fuel) catch |err| {
            var buffer: [4096]u8 = undefined;
            const stdout_file = std.Io.File.stdout();
            var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
            const stdout = &stdout_writer.interface;
            try stdout.writeAll("--- Runtime Error ---\n");
            if (interpreter.last_error_message) |msg| {
                try stdout.print("Message: {s}\n", .{msg});
            } else {
                try stdout.print("Error: {s}\n", .{@errorName(err)});
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
    if (builtin.os.tag != .windows) {
        const history_path = "history.txt";
        _ = linenoise.linenoiseHistoryLoad(history_path);
        defer {
            _ = linenoise.linenoiseHistorySave(history_path);
        }

        while (true) {
            const line = linenoise.linenoise("> ");
            if (line == null) {
                return;
            }
            defer linenoise.linenoiseFree(line);

            const line_slice = std.mem.sliceTo(line, 0);

            if (line_slice.len == 0) {
                continue;
            }

            if (std.mem.eql(u8, line_slice, ".exit")) {
                return;
            }

            _ = linenoise.linenoiseHistoryAdd(line);

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
                    var fuel: u64 = 1_000_000;
                    last_result = elz.eval.eval(interpreter, &form, interpreter.root_env, &fuel) catch |err| {
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
    } else {
        // Windows: REPL not supported, use file execution mode with -f flag
        var buffer: [4096]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll("REPL mode is not available on Windows.\n");
        try stdout.writeAll("Please use file execution mode: elz-repl -f <filepath>\n");
        try stdout.flush();
        return;
    }
}

fn rootExec(ctx: chilli.CommandContext) !void {
    const interpreter = ctx.getContextData(elz.Interpreter).?;

    // Check verbose flag
    const verbose = if (ctx.command.getFlagValue("verbose")) |v| v.Bool else false;

    if (ctx.command.getFlagValue("file")) |flag_value| {
        if (flag_value.String.len > 0) {
            const filename = flag_value.String;

            if (verbose) {
                std.debug.print("[VERBOSE] Opening file: {s}\n", .{filename});
            }

            if (verbose) {
                std.debug.print("[VERBOSE] Reading file contents...\n", .{});
            }

            const source = std.Io.Dir.cwd().readFileAlloc(interpreter.io, filename, interpreter.allocator, .limited(1024 * 1024)) catch |err| {
                std.debug.print("Error: Failed to read file '{s}': {s}\n", .{ filename, @errorName(err) });
                return err;
            };
            defer interpreter.allocator.free(source);

            if (verbose) {
                std.debug.print("[VERBOSE] Executing {d} bytes of source code...\n", .{source.len});
            }

            try exec(interpreter, source);
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
    const interpreter_ptr = try elz.gc.allocator.create(elz.Interpreter);
    interpreter_ptr.* = try elz.Interpreter.init(.{});
    elz.gc.add_roots(@intFromPtr(interpreter_ptr), @intFromPtr(interpreter_ptr) + @sizeOf(elz.Interpreter));

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

    try root_cmd.run(init.args, interpreter_ptr);
}
