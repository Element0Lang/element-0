const std = @import("std");
const fs = std.fs;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- GC dependency ---
    const gc_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const gc = b.addLibrary(.{
        .name = "gc",
        .root_module = gc_module,
    });
    {
        var cflags: std.ArrayListUnmanaged([]const u8) = .{};
        var src_files: std.ArrayListUnmanaged([]const u8) = .{};
        defer cflags.deinit(b.allocator);
        defer src_files.deinit(b.allocator);

        cflags.appendSlice(b.allocator, &.{
            "-DNO_EXECUTE_PERMISSION",
            "-DGC_THREADS", // Enable threading support
            "-DGC_BUILTIN_ATOMIC", // Use the compiler's built-in atomic functions
        }) catch unreachable;

        if (optimize != .Debug) {
            cflags.append(b.allocator, "-DNDEBUG") catch unreachable;
        }

        // Add base GC source files
        src_files.appendSlice(b.allocator, &.{
            "alloc.c",    "reclaim.c", "allchblk.c", "misc.c",     "mach_dep.c", "os_dep.c",
            "mark_rts.c", "headers.c", "mark.c",     "blacklst.c", "finalize.c", "new_hblk.c",
            "dbg_mlc.c",  "malloc.c",  "dyn_load.c", "typd_mlc.c", "ptr_chck.c", "mallocx.c",
            "obj_map.c",
        }) catch unreachable;

        // Add platform-specific source files for threading
        switch (target.query.os_tag orelse .linux) {
            .windows => {
                cflags.append(b.allocator, "-D_WIN32") catch unreachable;
                src_files.appendSlice(b.allocator, &.{ "win32_threads.c", "pthread_support.c" }) catch unreachable;
                gc.linkSystemLibrary("user32");
            },
            .macos => {
                cflags.append(b.allocator, "-D_DARWIN_C_SOURCE") catch unreachable;
                cflags.append(b.allocator, "-DMISSING_MACH_O_GETSECT_H") catch unreachable;
                cflags.append(b.allocator, "-DNO_MPROTECT_VDB") catch unreachable;
                src_files.appendSlice(b.allocator, &.{ "darwin_stop_world.c", "pthread_support.c", "pthread_start.c" }) catch unreachable;
            },
            else => { // Assume other POSIX-like systems
                src_files.appendSlice(b.allocator, &.{ "pthread_stop_world.c", "pthread_support.c", "pthread_start.c" }) catch unreachable;
            },
        }

        gc.linkLibC();
        // Use bdwgc from Zig dependencies
        const bdwgc_dep = b.dependency("bdwgc", .{});
        gc.addIncludePath(bdwgc_dep.path("include"));
        for (src_files.items) |src| {
            gc.addCSourceFile(.{ .file = bdwgc_dep.path(src), .flags = cflags.items });
        }
    }

    // --- Library Setup ---
    const lib_source = b.path("src/lib.zig");

    const lib_module = b.createModule(.{
        .root_source_file = lib_source,
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "elz",
        .root_module = lib_module,
    });
    // Use bdwgc from Zig dependencies
    const bdwgc_dep_lib = b.dependency("bdwgc", .{});
    lib.addIncludePath(bdwgc_dep_lib.path("include"));
    lib.linkLibrary(gc);
    lib.linkSystemLibrary("c");
    b.installArtifact(lib);

    // Export the module so downstream projects can use it
    _ = b.addModule("elz", .{
        .root_source_file = lib_source,
        .target = target,
        .optimize = optimize,
    });

    // --- REPL Executable ---
    const repl_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    repl_module.addImport("elz", lib_module);

    const repl_exe = b.addExecutable(.{
        .name = "elz-repl",
        .root_module = repl_module,
    });

    // --- Linenoise dependency (for POSIX only) ---
    if (target.query.os_tag orelse .linux != .windows) {
        const linenoise_dep = b.dependency("linenoise", .{});
        repl_exe.addIncludePath(linenoise_dep.path(""));
        repl_exe.addCSourceFile(.{ .file = linenoise_dep.path("linenoise.c") });
    }
    repl_exe.linkSystemLibrary("c");

    // Add dependency on 'chilli' library
    const chilli_dep = b.dependency("chilli", .{});
    const chilli_module = b.createModule(.{ .root_source_file = chilli_dep.path("src/lib.zig") });
    repl_exe.root_module.addImport("chilli", chilli_module);

    b.installArtifact(repl_exe);

    const run_repl_cmd = b.addRunArtifact(repl_exe);
    const run_repl_step = b.step("repl", "Run the REPL");
    run_repl_step.dependOn(&run_repl_cmd.step);

    // --- Docs Setup ---
    const docs_step = b.step("docs", "Generate API documentation");
    const doc_install_path = "docs/api";

    // Create docs directory if it doesn't exist
    fs.cwd().makePath("docs") catch {};

    const gen_docs_cmd = b.addSystemCommand(&[_][]const u8{
        b.graph.zig_exe,
        "build-lib",
        "src/lib.zig",
        "-femit-docs=" ++ doc_install_path,
    });
    docs_step.dependOn(&gen_docs_cmd.step);

    // --- Test Setup ---
    const test_module = b.createModule(.{
        .root_source_file = lib_source,
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    // Use bdwgc from Zig dependencies for tests
    const bdwgc_dep_test = b.dependency("bdwgc", .{});
    lib_unit_tests.addIncludePath(bdwgc_dep_test.path("include"));
    lib_unit_tests.linkLibrary(gc);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // --- Example Setup ---
    const examples_path = "examples/zig";
    var examples_dir = fs.cwd().openDir(examples_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        @panic("Can't open 'examples/zig' directory");
    };
    defer examples_dir.close();

    var dir_iter = examples_dir.iterate();
    while (dir_iter.next() catch @panic("Failed to iterate examples")) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const exe_name = fs.path.stem(entry.name);
        const exe_path = b.fmt("{s}/{s}", .{ examples_path, entry.name });

        const exe_module = b.createModule(.{
            .root_source_file = b.path(exe_path),
            .target = target,
            .optimize = optimize,
        });
        exe_module.addImport("elz", lib_module);

        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = exe_module,
        });
        exe.linkSystemLibrary("c");
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step_name = b.fmt("run-{s}", .{exe_name});
        const run_step_desc = b.fmt("Run the {s} example", .{exe_name});
        const run_step = b.step(run_step_name, run_step_desc);
        run_step.dependOn(&run_cmd.step);
    }

    // --- Run Element 0 Standard Library Tests ---
    const test_elz_step = b.step("test-elz", "Run the Element 0 language tests");
    const run_elz_tests_cmd = b.addRunArtifact(repl_exe);
    run_elz_tests_cmd.addArg("--file");
    run_elz_tests_cmd.addArg("tests/test_stdlib.elz");
    test_elz_step.dependOn(&run_elz_tests_cmd.step);
}
