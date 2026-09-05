const std = @import("std");
const elz = @import("elz");
const chilli = @import("chilli");
const build_options = @import("build_options");

const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

/// Bestline is POSIX-only (it needs poll.h and termios), so the Windows build
/// reads lines from stdin without editing, history, or completion.
const bestline = if (is_windows) struct {} else @cImport({
    @cInclude("bestline.h");
});

const filetime_unix_offset: i64 = 116444736000000000;

fn currentTimeMs() i64 {
    if (comptime is_windows) {
        const filetime = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(filetime - filetime_unix_offset, 10_000);
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
    }
}

/// A buffered writer over stdout that is flushed when it goes out of scope.
const Out = struct {
    buffer: [4096]u8 = undefined,
    writer: std.Io.File.Writer = undefined,

    fn init(self: *Out, io: std.Io) *std.Io.Writer {
        self.writer = std.Io.File.stdout().writerStreaming(io, &self.buffer);
        return &self.writer.interface;
    }

    fn flush(self: *Out) void {
        self.writer.interface.flush() catch {};
    }
};

fn displayValue(_: *elz.Interpreter, value: elz.Value, writer: anytype) !void {
    switch (value) {
        .string => |ms| {
            const s = ms.bytes;
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

/// Prints the message, location, and backtrace of the error that
/// `interpreter` just raised, then clears them so they do not leak into the
/// next report.
fn reportError(interpreter: *elz.Interpreter, err: anyerror, writer: *std.Io.Writer) !void {
    if (interpreter.last_error.message) |msg| {
        try writer.print("Error: {s}\n", .{msg});
    } else {
        try writer.print("Error: {s}\n", .{@errorName(err)});
    }
    if (interpreter.last_error.line) |line| {
        const file = interpreter.last_error.file orelse "?";
        try writer.print("At: {s}:{d}\n", .{ file, line });
    }
    try writeBacktrace(interpreter, writer);
    interpreter.last_error.clear();
}

/// Prints the recorded call chain, innermost first, when there is more than
/// the top-level frame to show.
fn writeBacktrace(interpreter: *elz.Interpreter, writer: *std.Io.Writer) !void {
    const frames = interpreter.last_error.backtrace.items;
    if (frames.len < 2) return;
    try writer.writeAll("Backtrace:\n");
    for (frames, 0..) |frame, i| {
        const name = if (std.mem.eql(u8, frame.name, "<top>")) "<top level>" else frame.name;
        if (frame.line != 0) {
            const file = if (frame.file.len > 0) frame.file else "?";
            try writer.print("  {d}: {s}  ({s}:{d})\n", .{ i, name, file, frame.line });
        } else {
            try writer.print("  {d}: {s}\n", .{ i, name });
        }
    }
    if (frames.len >= elz.MAX_BACKTRACE_FRAMES) try writer.writeAll("  ...\n");
}

/// Runs `source` and reports the first runtime error. Returns false when a form
/// failed, so `--file` can exit with a non-zero status instead of hiding the
/// failure from callers such as `zig build test-elz`.
fn exec(interpreter: *elz.Interpreter, source: []const u8, source_name: []const u8) !bool {
    var forms = elz.parser.readAllTracked(source, interpreter.allocator, source_name, &interpreter.compiler.source_locations) catch |err| {
        std.debug.print("Parse Error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer forms.deinit(interpreter.allocator);
    if (forms.items.len == 0) return true;

    var out: Out = undefined;
    const stdout = out.init(interpreter.io);
    defer out.flush();

    var last_result: elz.Value = .nil;
    for (forms.items) |form| {
        var fuel: u64 = std.math.maxInt(u64);
        interpreter.last_error.clear();
        last_result = interpreter.evalForm(&form, &fuel) catch |err| {
            try stdout.writeAll("--- Runtime Error ---\n");
            try stdout.print("ErrorCode: {s}\n", .{@errorName(err)});
            if (interpreter.last_error.message) |msg| {
                try stdout.print("Message: {s}\n", .{msg});
            }
            if (interpreter.last_error.line) |line| {
                const file = interpreter.last_error.file orelse "?";
                try stdout.print("At: {s}:{d}\n", .{ file, line });
            }
            try stdout.writeAll("In form: ");
            try elz.write(form, stdout);
            try stdout.writeAll("\n");
            try writeBacktrace(interpreter, stdout);
            interpreter.last_error.clear();
            return false;
        };
    }

    if (last_result != .unspecified) {
        try displayValue(interpreter, last_result, stdout);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Line input
// ---------------------------------------------------------------------------

/// Why `readLine` returned null.
const LineEnd = enum { eof, interrupted };

/// Reads one line from the terminal. On POSIX this is bestline with history
/// and completion; on Windows it is a plain buffered read of stdin.
const LineReader = struct {
    stdin_buffer: [64 * 1024]u8 = undefined,
    stdin_reader: ?std.Io.File.Reader = null,
    current: ?[*:0]u8 = null,
    interactive: bool,
    history_path: ?[:0]const u8 = null,
    last_end: LineEnd = .eof,

    fn readLine(self: *LineReader, io: std.Io, prompt: [:0]const u8) !?[]const u8 {
        if (comptime is_windows) {
            if (self.stdin_reader == null) {
                self.stdin_reader = std.Io.File.stdin().reader(io, &self.stdin_buffer);
            }
            if (self.interactive) {
                var out: Out = undefined;
                const stdout = out.init(io);
                try stdout.writeAll(prompt);
                out.flush();
            }
            const line = try self.stdin_reader.?.interface.takeDelimiter('\n') orelse return null;
            return std.mem.trimEnd(u8, line, "\r");
        } else {
            self.release();
            // Bestline re-raises SIGINT after restoring the previous handler,
            // so install a no-op handler for the duration of the read. Ctrl-C
            // then cancels the current line instead of killing the process.
            var old_action: std.posix.Sigaction = undefined;
            const ignore_action = std.posix.Sigaction{
                .handler = .{ .handler = onSigint },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &ignore_action, &old_action);
            defer std.posix.sigaction(.INT, &old_action, null);

            const line = if (self.history_path) |path|
                bestline.bestlineWithHistory(prompt.ptr, path.ptr)
            else
                bestline.bestline(prompt.ptr);
            if (line == null) {
                const errno: std.posix.E = @enumFromInt(std.c._errno().*);
                self.last_end = if (errno == .INTR) .interrupted else .eof;
                return null;
            }
            self.current = line;
            return std.mem.sliceTo(line, 0);
        }
    }

    fn release(self: *LineReader) void {
        if (comptime !is_windows) {
            if (self.current) |line| bestline.bestlineFree(line);
            self.current = null;
        }
    }
};

const SigParam = if (is_windows) void else @typeInfo(@typeInfo(std.posix.Sigaction.handler_fn).pointer.child).@"fn".params[0].type.?;

fn onSigint(_: SigParam) callconv(.c) void {}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

/// The interpreter whose globals feed tab completion. Bestline callbacks take
/// no user data, so this is a file-level pointer set by `Repl.run`.
var completion_interp: ?*elz.Interpreter = null;

const symbol_delimiters = " \t\r\n()[]{}\"';`,";

/// Returns true for the `name__h12` aliases the hygienic expander creates.
fn isHygieneAlias(name: []const u8) bool {
    const idx = std.mem.lastIndexOf(u8, name, "__h") orelse return false;
    const digits = name[idx + 3 ..];
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Collects the global names and special forms that start with `prefix`,
/// sorted. The caller owns the returned slice; the strings are borrowed.
fn matchingNames(allocator: std.mem.Allocator, interp: *elz.Interpreter, prefix: []const u8) ![][]const u8 {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    errdefer names.deinit(allocator);

    for (elz.special_form_names) |name| {
        if (std.mem.startsWith(u8, name, prefix)) try names.append(allocator, name);
    }
    var it = interp.root_env.bindings.keyIterator();
    while (it.next()) |key| {
        const name = key.*;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (isHygieneAlias(name)) continue;
        try names.append(allocator, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return names.toOwnedSlice(allocator);
}

fn completionCallback(buf_ptr: [*c]const u8, pos_c: c_int, completions: [*c]bestline.bestlineCompletions) callconv(.c) void {
    const interp = completion_interp orelse return;
    const buf = std.mem.sliceTo(buf_ptr, 0);
    const pos: usize = @min(@as(usize, @intCast(@max(pos_c, 0))), buf.len);

    var start = pos;
    while (start > 0 and std.mem.indexOfScalar(u8, symbol_delimiters, buf[start - 1]) == null) start -= 1;
    const prefix = buf[start..pos];
    if (prefix.len == 0) return;

    const allocator = std.heap.c_allocator;
    const names = matchingNames(allocator, interp, prefix) catch return;
    defer allocator.free(names);

    // Bestline completions replace the whole line, so splice each candidate
    // into the text around the cursor.
    for (names) |name| {
        const line = std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}", .{ buf[0..start], name, buf[pos..] }, 0) catch continue;
        defer allocator.free(line);
        bestline.bestlineAddCompletion(completions, line.ptr);
    }
}

// ---------------------------------------------------------------------------
// The REPL
// ---------------------------------------------------------------------------

const repl_help =
    \\Commands (anything else is evaluated as Element 0 code):
    \\  .help              Show this help
    \\  .load <file>       Load and run a source file in the current session
    \\  .time <expr>       Evaluate an expression and report the wall-clock time
    \\  .apropos <prefix>  List the global names starting with <prefix>
    \\  .error             Show the last error report again
    \\  .clear             Clear the screen
    \\  .exit              Leave the REPL (Ctrl-D also works)
    \\
    \\The last three printed values are bound to $1, $2, and $3.
    \\Input with open parentheses, brackets, or strings continues on the next
    \\line. Press Tab to complete a global name, and Ctrl-C to discard the
    \\current input. ~/.elzrc is loaded on startup unless --no-rc is given.
    \\
;

const Repl = struct {
    interp: *elz.Interpreter,
    reader: LineReader,
    /// Lines of the form being entered, kept until it parses completely.
    pending: std.ArrayListUnmanaged(u8) = .empty,
    /// Backing storage for the history path.
    history_buffer: [std.fs.max_path_bytes]u8 = undefined,
    /// Backing storage for the numbered prompt.
    prompt_buffer: [32]u8 = undefined,
    /// Number of the next input, shown in the prompt.
    input_number: usize = 1,
    /// The last error report, for `.error`.
    last_report: ?[]u8 = null,
    quiet: bool,
    load_rc: bool,

    fn init(interp: *elz.Interpreter, quiet: bool, load_rc: bool) Repl {
        const interactive = std.Io.File.stdin().isTty(interp.io) catch false;
        return .{
            .interp = interp,
            .reader = .{ .interactive = interactive },
            .quiet = quiet,
            .load_rc = load_rc,
        };
    }

    fn deinit(self: *Repl) void {
        self.reader.release();
        self.pending.deinit(self.interp.allocator);
        if (self.last_report) |r| self.interp.allocator.free(r);
        completion_interp = null;
    }

    /// Builds `$HOME/<name>`, falling back to the working directory.
    fn homeFile(buffer: []u8, name: []const u8) ?[:0]const u8 {
        const home: []const u8 = if (comptime is_windows)
            ""
        else if (std.c.getenv("HOME")) |h|
            std.mem.span(h)
        else
            "";
        return if (home.len > 0)
            std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ home, name }) catch null
        else
            std.fmt.bufPrintZ(buffer, "{s}", .{name}) catch null;
    }

    /// Runs `~/.elzrc` when it exists. Errors are reported and do not stop
    /// the REPL from starting.
    fn loadRcFile(self: *Repl) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = homeFile(&path_buffer, ".elzrc") orelse return;
        const interp = self.interp;
        const source = std.Io.Dir.cwd().readFileAlloc(interp.io, path, interp.allocator, .limited(1024 * 1024)) catch return;
        defer interp.allocator.free(source);
        var out: Out = undefined;
        const stdout = out.init(interp.io);
        defer out.flush();
        try self.evalSource(source, path, stdout, false);
    }

    fn run(self: *Repl) !void {
        const io = self.interp.io;
        if (self.reader.interactive) {
            if (!self.quiet) {
                var out: Out = undefined;
                const stdout = out.init(io);
                try stdout.print("Element 0 (elz {s})\n", .{build_options.version});
                try stdout.writeAll("Type .help for help, .exit or Ctrl-D to quit.\n");
                out.flush();
            }

            self.reader.history_path = homeFile(&self.history_buffer, ".elz_history");
            if (comptime !is_windows) {
                completion_interp = self.interp;
                bestline.bestlineSetCompletionCallback(completionCallback);
            }
        }
        if (self.load_rc) try self.loadRcFile();

        while (true) {
            const prompt: [:0]const u8 = if (self.pending.items.len == 0)
                std.fmt.bufPrintZ(&self.prompt_buffer, "[{d}]> ", .{self.input_number}) catch "> "
            else
                "... ";
            const line = (try self.reader.readLine(io, prompt)) orelse {
                if (self.reader.last_end == .interrupted) {
                    // Ctrl-C: drop the partial form and start over.
                    self.pending.clearRetainingCapacity();
                    continue;
                }
                if (self.pending.items.len > 0) {
                    var out: Out = undefined;
                    const stdout = out.init(io);
                    defer out.flush();
                    try stdout.writeAll("Parse Error: input ended inside an unfinished form\n");
                }
                return;
            };

            if (self.pending.items.len == 0) {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                if (isCommand(trimmed)) {
                    if (!try self.runCommand(trimmed[1..])) return;
                    continue;
                }
            }

            try self.pending.appendSlice(self.interp.allocator, line);
            try self.pending.append(self.interp.allocator, '\n');
            if (try self.evalPending()) self.pending.clearRetainingCapacity();
        }
    }

    /// A REPL command is a dot followed by a letter, so numbers such as `.5`
    /// still evaluate as code.
    fn isCommand(line: []const u8) bool {
        return line.len >= 2 and line[0] == '.' and std.ascii.isAlphabetic(line[1]);
    }

    /// Parses the pending text. Returns false when the input is incomplete and
    /// more lines are needed; true when it was evaluated or rejected.
    fn evalPending(self: *Repl) !bool {
        const interp = self.interp;
        var out: Out = undefined;
        const stdout = out.init(interp.io);
        defer out.flush();

        // Name the input after its prompt number, so error locations and
        // backtraces read "[3]:2" for line 2 of input 3. Compiled code keeps
        // the name, so it must outlive this call.
        const source_name = try std.fmt.allocPrint(interp.allocator, "[{d}]", .{self.input_number});
        var forms = elz.parser.readAllTracked(self.pending.items, interp.allocator, source_name, &interp.compiler.source_locations) catch |err| switch (err) {
            error.UnmatchedOpenParen, error.UnexpectedEndOfInput, error.UnterminatedString => return false,
            else => {
                try stdout.print("Parse Error: {s}\n", .{@errorName(err)});
                return true;
            },
        };
        defer forms.deinit(interp.allocator);

        self.input_number += 1;
        try self.evalForms(forms.items, stdout, true);
        return true;
    }

    /// Parses and evaluates `source`, printing values when `print_values`.
    fn evalSource(self: *Repl, source: []const u8, name: []const u8, stdout: *std.Io.Writer, print_values: bool) !void {
        const interp = self.interp;
        var forms = elz.parser.readAllTracked(source, interp.allocator, name, &interp.compiler.source_locations) catch |err| {
            try stdout.print("Parse Error in {s}: {s}\n", .{ name, @errorName(err) });
            return;
        };
        defer forms.deinit(interp.allocator);
        try self.evalForms(forms.items, stdout, print_values);
    }

    /// Evaluates forms in order, stopping at the first error. Printed values
    /// shift into `$1`, `$2`, and `$3`.
    fn evalForms(self: *Repl, forms: []const elz.Value, stdout: *std.Io.Writer, print_values: bool) !void {
        const interp = self.interp;
        for (forms) |form| {
            var fuel: u64 = std.math.maxInt(u64);
            interp.last_error.clear();
            const result = interp.evalForm(&form, &fuel) catch |err| {
                try self.reportAndRemember(err, stdout);
                return;
            };
            if (print_values and result != .unspecified) {
                try elz.write(result, stdout);
                try stdout.writeAll("\n");
                self.rememberValue(result);
            }
        }
    }

    fn rememberValue(self: *Repl, value: elz.Value) void {
        const env = self.interp.root_env;
        if (env.lookup("$2")) |v| env.set("$3", v) catch {};
        if (env.lookup("$1")) |v| env.set("$2", v) catch {};
        env.set("$1", value) catch {};
    }

    /// Prints the error report and keeps a copy for `.error`.
    fn reportAndRemember(self: *Repl, err: anyerror, stdout: *std.Io.Writer) !void {
        const interp = self.interp;
        var report = std.Io.Writer.Allocating.init(interp.allocator);
        defer report.deinit();
        try reportError(interp, err, &report.writer);
        try stdout.writeAll(report.written());
        if (self.last_report) |old| interp.allocator.free(old);
        self.last_report = try report.toOwnedSlice();
    }

    /// Runs a dot command. Returns false when the REPL should exit.
    fn runCommand(self: *Repl, command: []const u8) !bool {
        const interp = self.interp;
        var out: Out = undefined;
        const stdout = out.init(interp.io);
        defer out.flush();

        var parts = std.mem.tokenizeAny(u8, command, " \t");
        const name = parts.next() orelse return true;
        const rest = std.mem.trim(u8, parts.rest(), " \t");

        if (std.mem.eql(u8, name, "exit") or std.mem.eql(u8, name, "quit")) {
            return false;
        } else if (std.mem.eql(u8, name, "help")) {
            try stdout.writeAll(repl_help);
        } else if (std.mem.eql(u8, name, "clear")) {
            try stdout.writeAll("\x1b[H\x1b[2J");
        } else if (std.mem.eql(u8, name, "error")) {
            if (self.last_report) |report| {
                try stdout.writeAll(report);
            } else {
                try stdout.writeAll("No error has been reported yet.\n");
            }
        } else if (std.mem.eql(u8, name, "load")) {
            if (rest.len == 0) {
                try stdout.writeAll("Usage: .load <file>\n");
                return true;
            }
            const source = std.Io.Dir.cwd().readFileAlloc(interp.io, rest, interp.allocator, .limited(1024 * 1024)) catch |err| {
                try stdout.print("Error: cannot read '{s}': {s}\n", .{ rest, @errorName(err) });
                return true;
            };
            defer interp.allocator.free(source);
            try self.evalSource(source, rest, stdout, false);
        } else if (std.mem.eql(u8, name, "time")) {
            if (rest.len == 0) {
                try stdout.writeAll("Usage: .time <expr>\n");
                return true;
            }
            const start = currentTimeMs();
            try self.evalSource(rest, "<time>", stdout, true);
            try stdout.print("; {d} ms\n", .{currentTimeMs() - start});
        } else if (std.mem.eql(u8, name, "apropos")) {
            const names = try matchingNames(interp.allocator, interp, rest);
            defer interp.allocator.free(names);
            if (names.len == 0) {
                try stdout.print("No global names start with '{s}'\n", .{rest});
                return true;
            }
            for (names) |n| try stdout.print("{s}\n", .{n});
        } else {
            try stdout.print("Unknown command .{s}. Type .help for the list of commands.\n", .{name});
        }
        return true;
    }
};

fn runRepl(interpreter: *elz.Interpreter, quiet: bool, load_rc: bool) !void {
    var repl = Repl.init(interpreter, quiet, load_rc);
    defer repl.deinit();
    try repl.run();
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

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

    const verbose = if (ctx.command.getFlagValue("verbose")) |v| v.Bool else false;
    const interactive = if (ctx.command.getFlagValue("interactive")) |v| v.Bool else false;
    const quiet = if (ctx.command.getFlagValue("quiet")) |v| v.Bool else false;
    const no_rc = if (ctx.command.getFlagValue("no-rc")) |v| v.Bool else false;
    const bench_iters: i64 = if (ctx.command.getFlagValue("bench")) |v| v.Int else 0;
    const eval_source: []const u8 = if (ctx.command.getFlagValue("eval")) |v| v.String else "";

    // The file may come from the positional argument or from --file.
    var filename: []const u8 = ctx.getArg("file", []const u8) catch "";
    if (filename.len == 0) {
        if (ctx.command.getFlagValue("file")) |v| filename = v.String;
    }

    // (command-line) is the script followed by its own arguments, or just the
    // program name when there is no script. The interpreter's flags are not
    // the script's business.
    try setCommandLine(interpreter, filename, ctx.getArgs("args"));

    if (eval_source.len > 0) {
        if (!try exec(interpreter, eval_source, "<eval>")) std.process.exit(1);
        if (filename.len == 0 and !interactive) return;
    }

    if (filename.len > 0) {
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

        if (!try exec(interpreter, source, filename)) {
            std.process.exit(1);
        }
        if (!interactive) return;
    }

    if (verbose) {
        std.debug.print("[VERBOSE] Starting REPL mode...\n", .{});
    }

    try runRepl(interpreter, quiet, !no_rc);
}

/// argv[0], kept for `(command-line)` when no script is given.
var program_name: []const u8 = "elz";

fn setCommandLine(interpreter: *elz.Interpreter, filename: []const u8, args: []const []const u8) !void {
    const allocator = elz.gc_allocator;
    var argv: elz.Value = .nil;
    var i = args.len;
    while (i > 0) {
        i -= 1;
        const link = try allocator.create(elz.core.Pair);
        link.* = .{ .car = try elz.core.makeString(allocator, try allocator.dupe(u8, args[i])), .cdr = argv };
        argv = elz.Value{ .pair = link };
    }
    const head = if (filename.len > 0) filename else program_name;
    const link = try allocator.create(elz.core.Pair);
    link.* = .{ .car = try elz.core.makeString(allocator, try allocator.dupe(u8, head)), .cdr = argv };
    interpreter.command_line = elz.Value{ .pair = link };
}

/// The main entry point for the `elz` executable.
/// This function initializes the interpreter and the command-line interface.
/// It can either start a REPL or execute a source file, based on the command-line arguments.
pub fn main(init: std.process.Init.Minimal) anyerror!void {
    const interpreter_ptr = try elz.gc_allocator.create(elz.Interpreter);
    interpreter_ptr.* = try elz.Interpreter.init(.{});
    elz.gc_add_roots(@intFromPtr(interpreter_ptr), @intFromPtr(interpreter_ptr) + @sizeOf(elz.Interpreter));

    interpreter_ptr.last_error.collect_backtrace = true;

    {
        var arg_it = try std.process.Args.Iterator.initAllocator(init.args, elz.gc_allocator);
        defer arg_it.deinit();
        if (arg_it.next()) |argv0| program_name = try elz.gc_allocator.dupe(u8, argv0);
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var root_cmd = try chilli.Command.init(gpa.allocator(), .{
        .name = "elz",
        .description = "Element 0 is a Lisp dialect implemented in Zig. Without a file, an interactive REPL starts.",
        .version = build_options.version,
        .exec = rootExec,
    });
    defer root_cmd.deinit();

    try root_cmd.addPositional(.{
        .name = "file",
        .description = "An Element 0 source file to execute",
        .is_required = false,
        .default_value = .{ .String = "" },
    });

    try root_cmd.addPositional(.{
        .name = "args",
        .description = "Arguments passed to the script through (command-line)",
        .is_required = false,
        .variadic = true,
        .default_value = .{ .String = "" },
    });

    try root_cmd.addFlag(.{
        .name = "file",
        .shortcut = 'f',
        .description = "The Element 0 source file to execute (same as the positional argument)",
        .type = .String,
        .default_value = .{ .String = "" },
    });

    try root_cmd.addFlag(.{
        .name = "eval",
        .shortcut = 'e',
        .description = "Evaluate the given source text and print the result",
        .type = .String,
        .default_value = .{ .String = "" },
    });

    try root_cmd.addFlag(.{
        .name = "interactive",
        .shortcut = 'i',
        .description = "Start the REPL after running the file or expression",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    try root_cmd.addFlag(.{
        .name = "quiet",
        .shortcut = 'q',
        .description = "Do not print the REPL banner",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    try root_cmd.addFlag(.{
        .name = "no-rc",
        .description = "Do not load ~/.elzrc when starting the REPL",
        .type = .Bool,
        .default_value = .{ .Bool = false },
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
