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

        // Add base GC source files (matching official bdwgc build)
        src_files.appendSlice(b.allocator, &.{
            "allchblk.c", "alloc.c",    "blacklst.c", "dbg_mlc.c",  "dyn_load.c",
            "finalize.c", "headers.c",  "mach_dep.c", "malloc.c",   "mallocx.c",
            "mark.c",     "mark_rts.c", "misc.c",     "new_hblk.c", "obj_map.c",
            "os_dep.c",   "ptr_chck.c", "reclaim.c",  "typd_mlc.c",
        }) catch unreachable;

        // Add platform-specific source files for threading
        // Note: Use target.result.os.tag (resolved target) instead of target.query.os_tag
        // because query.os_tag is null for native builds
        const os_tag = target.result.os.tag;
        switch (os_tag) {
            .windows => {
                cflags.append(b.allocator, "-D_WIN32") catch unreachable;
                src_files.appendSlice(b.allocator, &.{ "win32_threads.c", "pthread_support.c", "pthread_start.c" }) catch unreachable;
                gc.linkSystemLibrary("user32");
            },
            .macos => {
                // Required flags for POSIX/Darwin threading
                cflags.append(b.allocator, "-D_REENTRANT") catch unreachable;
                // Add threading source files (matching official bdwgc build)
                src_files.appendSlice(b.allocator, &.{ "gc_dlopen.c", "pthread_start.c", "pthread_support.c", "darwin_stop_world.c" }) catch unreachable;
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

    // --- Unit Test Setup ---
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

    // --- Property-Based and Integration Test Setup ---
    const test_prop_step = b.step("test-prop", "Run property-based tests");
    const test_integ_step = b.step("test-integ", "Run integration tests");
    const minish_dep = b.dependency("minish", .{});

    {
        const tests_path = "tests";
        var tests_dir = fs.cwd().openDir(tests_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                @panic("Can't open 'tests' directory");
            }
            @panic("Can't open 'tests' directory");
        };
        defer tests_dir.close();

        var test_iter = tests_dir.iterate();
        while (test_iter.next() catch @panic("Failed to iterate tests")) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

            const is_prop_test = std.mem.endsWith(u8, entry.name, "_prop_test.zig");
            const is_integ_test = std.mem.endsWith(u8, entry.name, "_integ_test.zig");

            if (!is_prop_test and !is_integ_test) continue;

            const test_path = b.fmt("{s}/{s}", .{ tests_path, entry.name });

            const t_module = b.createModule(.{
                .root_source_file = b.path(test_path),
                .target = target,
                .optimize = optimize,
            });
            t_module.addImport("elz", lib_module);

            if (is_prop_test) {
                t_module.addImport("minish", minish_dep.module("minish"));
            }

            const t = b.addTest(.{ .root_module = t_module });
            const bdwgc_dep_t = b.dependency("bdwgc", .{});
            t.addIncludePath(bdwgc_dep_t.path("include"));
            t.linkLibrary(gc);

            const run_t = b.addRunArtifact(t);
            if (is_prop_test) {
                test_prop_step.dependOn(&run_t.step);
            } else {
                test_integ_step.dependOn(&run_t.step);
            }
        }
    }

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

    // --- Run Element 0 Language Tests ---
    const test_elz_step = b.step("test-elz", "Run the Element 0 language tests");
    {
        const tests_path = "tests";
        var tests_dir = fs.cwd().openDir(tests_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                @panic("Can't open 'tests' directory");
            }
            @panic("Can't open 'tests' directory");
        };
        defer tests_dir.close();

        var test_iter = tests_dir.iterate();
        while (test_iter.next() catch @panic("Failed to iterate tests")) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "test_")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".elz")) continue;

            const run_elz_test_cmd = b.addRunArtifact(repl_exe);
            run_elz_test_cmd.addArg("--file");
            run_elz_test_cmd.addArg(b.fmt("{s}/{s}", .{ tests_path, entry.name }));
            test_elz_step.dependOn(&run_elz_test_cmd.step);
        }
    }

    // --- Run All Tests ---
    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(&run_lib_unit_tests.step);
    test_all_step.dependOn(test_prop_step);
    test_all_step.dependOn(test_integ_step);
    test_all_step.dependOn(test_elz_step);
}
