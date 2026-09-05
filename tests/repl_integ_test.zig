//! End-to-end tests for the `elz-repl` binary. Each test spawns the real
//! executable (its path comes from `build_options.repl_path`), feeds it input
//! on stdin or the command line, and checks stdout and the exit status.
//! The interactive features that need a terminal (line editing, completion,
//! Ctrl-C) are out of reach here; everything that works through a pipe is in.

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;
const io = testing.io;

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    status: u8,

    fn deinit(self: Result) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

/// Runs the REPL with `args`, writing `stdin_data` to its standard input, and
/// collects what it prints. The working directory is the child's own, so tests
/// that need files write them into a temp directory and pass absolute paths.
fn runRepl(args: []const []const u8, stdin_data: []const u8, cwd: std.process.Child.Cwd) !Result {
    // The build hands us a path relative to the project root; make it absolute
    // so it still resolves after the child changes directory.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.Io.Dir.cwd().realPathFile(io, build_options.repl_path, &exe_buf);
    const exe_path = exe_buf[0..exe_len];

    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, exe_path);
    try argv.append(testing.allocator, "--no-rc");
    try argv.appendSlice(testing.allocator, args);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = cwd,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.debug.print("could not spawn {s}: {s}\n", .{ exe_path, @errorName(err) });
        return err;
    };
    defer child.kill(io);

    // Write the whole input, then close the pipe so the REPL sees end of file.
    try child.stdin.?.writeStreamingAll(io, stdin_data);
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(testing.allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(4096, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer testing.allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .status = switch (term) {
            .exited => |code| code,
            else => 255,
        },
    };
}

/// The absolute path of a temp directory, for the child's working directory.
/// Passing the directory handle itself does not survive the spawn.
fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("did not expect to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedContains;
    }
}

// ---------------------------------------------------------------------------
// Piped sessions
// ---------------------------------------------------------------------------

test "a piped session prints each value with write" {
    const r = try runRepl(&.{}, "(+ 1 2)\n\"two\"\n#\\a\n(list 1 \"b\")\n", .inherit);
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("3\n\"two\"\n#\\a\n(1 \"b\")\n", r.stdout);
}

test "a form spread over several lines is read as one" {
    const r = try runRepl(&.{}, "(define (sq x)\n  (* x\n     x))\n(sq 12)\n", .inherit);
    defer r.deinit();
    try testing.expectEqualStrings("144\n", r.stdout);
}

test "unspecified results are not printed" {
    const r = try runRepl(&.{}, "(define x 1)\n(set! x 2)\n(if #f #f)\nx\n", .inherit);
    defer r.deinit();
    try testing.expectEqualStrings("2\n", r.stdout);
}

test "the last three values are bound to $1 $2 $3" {
    const r = try runRepl(&.{}, "1\n2\n3\n(list $1 $2 $3)\n(define y 9)\n$1\n", .inherit);
    defer r.deinit();
    // The define produced no value, so $1 is still the list.
    try testing.expectEqualStrings("1\n2\n3\n(3 2 1)\n(3 2 1)\n", r.stdout);
}

test "an error keeps the session alive and names the operation" {
    const r = try runRepl(&.{}, "(car 1)\n(+ 1 1)\n", .inherit);
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.status);
    try expectContains(r.stdout, "Error: car: expected a pair, got an integer\n");
    try expectContains(r.stdout, "At: [1]:1\n");
    try expectContains(r.stdout, "\n2\n");
}

test "an error inside procedures prints a backtrace" {
    const r = try runRepl(&.{}, "(define (g x) (car x))\n(define (f x)\n  (+ 1\n     (g x)))\n(f 5)\n", .inherit);
    defer r.deinit();
    try expectContains(r.stdout, "Backtrace:\n  0: g  ([1]:1)\n  1: f  ([2]:3)\n  2: <top level>  ([3]:1)\n");
}

test ".error repeats the last report" {
    const r = try runRepl(&.{}, "(car 1)\n.error\n", .inherit);
    defer r.deinit();
    const first = std.mem.indexOf(u8, r.stdout, "Error: car").?;
    const second = std.mem.indexOfPos(u8, r.stdout, first + 1, "Error: car");
    try testing.expect(second != null);
}

test "a caught error leaves no stale report" {
    const r = try runRepl(&.{}, "(try (car 1) (catch e 'caught))\n.error\n", .inherit);
    defer r.deinit();
    try testing.expectEqualStrings("caught\nNo error has been reported yet.\n", r.stdout);
}

test "an unfinished form at end of input is reported" {
    const r = try runRepl(&.{}, "(+ 1\n", .inherit);
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.status);
    try expectContains(r.stdout, "Parse Error: input ended inside an unfinished form\n");
}

test "a malformed form is rejected without ending the session" {
    const r = try runRepl(&.{}, ")\n(+ 2 2)\n", .inherit);
    defer r.deinit();
    try expectContains(r.stdout, "Parse Error: UnexpectedCloseParen\n");
    try expectContains(r.stdout, "\n4\n");
}

// ---------------------------------------------------------------------------
// Dot commands
// ---------------------------------------------------------------------------

test ".help lists the commands and unknown commands are reported" {
    const r = try runRepl(&.{}, ".help\n.bogus\n", .inherit);
    defer r.deinit();
    try expectContains(r.stdout, "  .load <file>");
    try expectContains(r.stdout, "  .apropos <prefix>");
    try expectContains(r.stdout, "Unknown command .bogus. Type .help for the list of commands.\n");
}

test ".exit ends the session before the remaining input" {
    const r = try runRepl(&.{}, "1\n.exit\n2\n", .inherit);
    defer r.deinit();
    try testing.expectEqualStrings("1\n", r.stdout);
}

test ".apropos lists matching globals in order" {
    const r = try runRepl(&.{}, ".apropos string-fo\n.apropos no-such-prefix-xyz\n", .inherit);
    defer r.deinit();
    try testing.expectEqualStrings("string-foldcase\nstring-for-each\nNo global names start with 'no-such-prefix-xyz'\n", r.stdout);
}

test ".time prints the value and a timing line" {
    const r = try runRepl(&.{}, ".time (* 6 7)\n", .inherit);
    defer r.deinit();
    try expectContains(r.stdout, "42\n; ");
    try expectContains(r.stdout, " ms\n");
}

test "a dot followed by a digit is a number, not a command" {
    const r = try runRepl(&.{}, ".5\n", .inherit);
    defer r.deinit();
    try testing.expectEqualStrings("0.5\n", r.stdout);
}

test ".load runs a file and keeps its definitions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.elz", .data = "(define (twice x) (* 2 x))\n(display \"loaded\")\n(newline)\n" });

    const r = try runRepl(&.{}, ".load lib.elz\n(twice 21)\n.load missing.elz\n", .{ .path = try tmpPath(&tmp, &path_buf) });
    defer r.deinit();
    try expectContains(r.stdout, "loaded\n42\n");
    try expectContains(r.stdout, "Error: cannot read 'missing.elz'");
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

test "--eval prints the value and exits" {
    const r = try runRepl(&.{ "--eval", "(expt 2 64)" }, "", .inherit);
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("18446744073709551616\n", r.stdout);
}

test "--eval with an error exits with status 1" {
    const r = try runRepl(&.{ "--eval", "(car 1)" }, "", .inherit);
    defer r.deinit();
    try testing.expectEqual(@as(u8, 1), r.status);
    try expectContains(r.stdout, "--- Runtime Error ---\n");
    try expectContains(r.stdout, "Message: car: expected a pair, got an integer\n");
}

test "a script sees itself and its arguments in command-line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "args.elz", .data = "(write (command-line))\n(newline)\n" });

    const r = try runRepl(&.{ "args.elz", "one", "--", "--two" }, "", .{ .path = try tmpPath(&tmp, &path_buf) });
    defer r.deinit();
    try testing.expectEqualStrings("(\"args.elz\" \"one\" \"--two\")\n", r.stdout);
}

test "without a script command-line is the program name" {
    const r = try runRepl(&.{}, "(length (command-line))\n", .inherit);
    defer r.deinit();
    try testing.expectEqualStrings("1\n", r.stdout);
}

test "a failing script reports the location and backtrace and exits 1" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.elz", .data = "(define (h) (vector-ref (vector) 3))\n(display \"before\")\n(h)\n(display \"after\")\n" });

    const r = try runRepl(&.{"bad.elz"}, "", .{ .path = try tmpPath(&tmp, &path_buf) });
    defer r.deinit();
    try testing.expectEqual(@as(u8, 1), r.status);
    try expectContains(r.stdout, "before--- Runtime Error ---\n");
    try expectContains(r.stdout, "At: bad.elz:1\n");
    try expectContains(r.stdout, "In form: (h)\n");
    try expectContains(r.stdout, "Backtrace:\n  0: h  (bad.elz:1)\n");
    try expectNotContains(r.stdout, "after");
}

test "--interactive runs the file and then reads stdin" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "defs.elz", .data = "(define answer 42)\n" });

    const r = try runRepl(&.{ "--interactive", "defs.elz" }, "answer\n", .{ .path = try tmpPath(&tmp, &path_buf) });
    defer r.deinit();
    try testing.expectEqualStrings("42\n", r.stdout);
}

test "--quiet is accepted and a piped session prints no banner" {
    const r = try runRepl(&.{"--quiet"}, "1\n", .inherit);
    defer r.deinit();
    try testing.expectEqualStrings("1\n", r.stdout);
}
