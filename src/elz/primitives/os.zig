const std = @import("std");
const core = @import("../core.zig");
const ElzError = @import("../errors.zig").ElzError;
const interpreter = @import("../interpreter.zig");

/// `getenv` returns the value of an environment variable.
/// Syntax: (getenv "VAR")
/// Returns the value as a string, or #f if the variable is not set.
pub fn getenv(_: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const name_val = args.items[0];
    if (name_val != .string) return ElzError.InvalidArgument;

    const name = name_val.string;

    const name_z = env.allocator.dupeZ(u8, name) catch return ElzError.OutOfMemory;
    defer env.allocator.free(name_z);

    if (std.c.getenv(name_z.ptr)) |value_ptr| {
        const value = std.mem.span(value_ptr);
        const duped = env.allocator.dupe(u8, value) catch return ElzError.OutOfMemory;
        return core.Value{ .string = duped };
    } else {
        return core.Value{ .boolean = false };
    }
}

/// `file_exists` checks if a file exists.
/// Syntax: (file-exists? "path")
/// Returns #t if the file exists, #f otherwise.
pub fn file_exists(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const path_val = args.items[0];
    if (path_val != .string) return ElzError.InvalidArgument;

    const path = path_val.string;

    const stat = std.Io.Dir.cwd().statFile(interp.io, path, .{});
    if (stat) |_| {
        return core.Value{ .boolean = true };
    } else |_| {
        return core.Value{ .boolean = false };
    }
}

/// `delete_file` deletes a file.
/// Syntax: (delete-file "path")
/// Returns unspecified, or raises an error if deletion fails.
pub fn delete_file(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const path_val = args.items[0];
    if (path_val != .string) return ElzError.InvalidArgument;

    const path = path_val.string;

    std.Io.Dir.cwd().deleteFile(interp.io, path) catch |err| {
        interp.last_error_message = std.fmt.allocPrint(interp.allocator, "Failed to delete file '{s}': {s}", .{ path, @errorName(err) }) catch null;
        return ElzError.ForeignFunctionError;
    };

    return core.Value.unspecified;
}

/// `current_directory` returns the current working directory.
/// Syntax: (current-directory)
/// Returns the path as a string.
pub fn current_directory(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 0) return ElzError.WrongArgumentCount;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(interp.io, &buf) catch return ElzError.ForeignFunctionError;

    const result = env.allocator.dupe(u8, buf[0..n]) catch return ElzError.OutOfMemory;
    return core.Value{ .string = result };
}

/// `directory_list` returns a list of filenames in a directory.
/// Syntax: (directory-list "path")
/// Returns a list of strings (filenames).
pub fn directory_list(interp: *interpreter.Interpreter, env: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 1) return ElzError.WrongArgumentCount;

    const path_val = args.items[0];
    if (path_val != .string) return ElzError.InvalidArgument;

    const path = path_val.string;

    var dir = std.Io.Dir.cwd().openDir(interp.io, path, .{ .iterate = true }) catch return ElzError.FileNotFound;
    defer dir.close(interp.io);

    // Build a list of filenames
    var result: ?*core.Pair = null;
    var last: ?*core.Pair = null;

    var iter = dir.iterate();
    while (iter.next(interp.io) catch return ElzError.ForeignFunctionError) |entry| {
        const name = env.allocator.dupe(u8, entry.name) catch return ElzError.OutOfMemory;
        const name_val = core.Value{ .string = name };

        const new_pair = env.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
        new_pair.* = .{ .car = name_val, .cdr = .nil };

        if (last) |l| {
            l.cdr = core.Value{ .pair = new_pair };
        } else {
            result = new_pair;
        }
        last = new_pair;
    }

    if (result) |r| {
        return core.Value{ .pair = r };
    } else {
        return core.Value.nil;
    }
}

/// `rename_file` renames or moves a file.
/// Syntax: (rename-file "old-path" "new-path")
/// Returns unspecified, or raises an error if renaming fails.
pub fn rename_file(interp: *interpreter.Interpreter, _: *core.Environment, args: core.ValueList, _: *u64) ElzError!core.Value {
    if (args.items.len != 2) return ElzError.WrongArgumentCount;

    const old_val = args.items[0];
    const new_val = args.items[1];
    if (old_val != .string or new_val != .string) return ElzError.InvalidArgument;

    const old_path = old_val.string;
    const new_path = new_val.string;

    std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), new_path, interp.io) catch |err| {
        interp.last_error_message = std.fmt.allocPrint(interp.allocator, "Failed to rename '{s}' to '{s}': {s}", .{ old_path, new_path, @errorName(err) }) catch null;
        return ElzError.ForeignFunctionError;
    };

    return core.Value.unspecified;
}

test "getenv returns value or false" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    // Test getting a known env var (PATH should always exist)
    var args = core.ValueList.init(interp.allocator);
    try args.append(core.Value{ .string = "PATH" });

    const result = try getenv(&interp, interp.root_env, args, undefined);
    // PATH should return a string
    try testing.expect(result == .string or result == .boolean);
}

test "file_exists returns boolean" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    // Test with existing file
    var args1 = core.ValueList.init(interp.allocator);
    try args1.append(core.Value{ .string = "build.zig" });

    const result1 = try file_exists(&interp, interp.root_env, args1, undefined);
    try testing.expect(result1 == .boolean);
    try testing.expect(result1.boolean == true);

    // Test with non-existing file
    var args2 = core.ValueList.init(interp.allocator);
    try args2.append(core.Value{ .string = "nonexistent_file_12345.xyz" });

    const result2 = try file_exists(&interp, interp.root_env, args2, undefined);
    try testing.expect(result2 == .boolean);
    try testing.expect(result2.boolean == false);
}

test "current_directory returns string" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    const args = core.ValueList.init(interp.allocator);
    const result = try current_directory(&interp, interp.root_env, args, undefined);

    try testing.expect(result == .string);
    try testing.expect(result.string.len > 0);
}

test "directory_list returns list" {
    const testing = std.testing;
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();

    var args = core.ValueList.init(interp.allocator);
    try args.append(core.Value{ .string = "." });

    const result = try directory_list(&interp, interp.root_env, args, undefined);

    // Should be a list (pair or nil)
    try testing.expect(result == .pair or result == .nil);
}
