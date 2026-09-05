const std = @import("std");
const builtin = @import("builtin");
const core = @import("./core.zig");
const env_setup = @import("./env_setup.zig");
const parser = @import("./parser.zig");
const gc = @import("gc.zig");
const compiler = @import("./compiler.zig");
const vm = @import("./vm.zig");

var gc_initialized = std.atomic.Value(bool).init(false);

const filetime_unix_offset: i64 = 116444736000000000;

pub fn currentTimeMs() i64 {
    if (comptime builtin.os.tag == .windows) {
        const filetime = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(filetime - filetime_unix_offset, 10_000);
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
    }
}

fn ensureGcInitialized() void {
    if (gc_initialized.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
        gc.init();
    }
}

/// `SandboxFlags` controls which built-in capabilities are available to the Elz scripting engine.
/// Pass it to `Interpreter.init` to restrict I/O, math, or other feature groups.
pub const SandboxFlags = struct {
    /// Enables or disables mathematical functions.
    enable_math: bool = true,
    /// Enables or disables list manipulation functions.
    enable_lists: bool = true,
    /// Enables or disables predicate functions (e.g., `null?`, `pair?`).
    enable_predicates: bool = true,
    /// Enables or disables string manipulation functions.
    enable_strings: bool = true,
    /// Enables or disables I/O functions (e.g., `display`, `load`).
    enable_io: bool = true,
    /// Enables or disables filesystem access: file ports, `load`, `include`,
    /// module imports, and the file operations in `os`.
    enable_filesystem: bool = true,
    /// Enables or disables process access: `exit` and environment variables.
    enable_process: bool = true,
    /// Maximum wall-clock execution time in milliseconds. Null means no limit.
    time_limit_ms: ?u64 = null,
};

/// Escape-continuation and dynamic-wind state.
/// Only primitives/control.zig should read or write these fields.
pub const CpsState = struct {
    /// Value carried by the most recently invoked escape continuation.
    escape_value: ?core.Value = null,
    /// Identity of the escape continuation that carried `escape_value`, so the
    /// `call/ec` frame that created it can tell whether the jump is its own.
    escape_id: u64 = 0,
    /// Counter handing out escape continuation identities.
    escape_counter: u64 = 0,
    /// Innermost active dynamic-wind frame, null when none is in effect.
    winders: ?*core.Winder = null,
};

/// `Interpreter` is the top-level handle for the Elz scripting engine.
/// It holds the root environment, module cache, and VM configuration.
pub const Interpreter = struct {
    /// Allocator used for environment bindings and the module cache.
    allocator: std.mem.Allocator,
    /// The I/O implementation used for file operations, sleeping, etc.
    io: std.Io,
    /// The root environment, containing all built-in functions and global variables.
    root_env: *core.Environment,
    /// A message describing the last error that occurred, if any.
    last_error_message: ?[]const u8 = null,
    /// A cache for loaded modules to avoid redundant parsing and evaluation.
    module_cache: std.StringHashMap(*core.Module),
    /// Counter for generating unique symbols via `gensym` (one per `Interpreter` instance).
    gensym_counter: u64 = 0,
    /// Maximum wall-clock execution time in milliseconds (null = no limit).
    time_limit_ms: ?u64 = null,
    /// Whether filesystem access is permitted. Checked by the compiler for
    /// `include` and by `importModule`, which read files at compile time.
    enable_filesystem: bool = true,
    /// Timestamp (ms) when the current evaluation started.
    eval_start_ms: ?i64 = null,
    /// Step counter for throttling time checks (check every N steps).
    time_check_counter: u64 = 0,
    /// Escape-continuation and dynamic-wind state.
    /// Only primitives/control.zig should read or write these fields.
    cps: CpsState = .{},
    /// The current input port. Populated lazily on first reference.
    stdin_port: ?*core.Port = null,
    /// The current output port. Populated lazily on first reference.
    stdout_port: ?*core.Port = null,
    stderr_port: ?*core.Port = null,
    /// The value raised by `raise`/`raise-continuable`/`error`, carried
    /// alongside the Zig error until a catch site consumes it.
    current_exception: ?core.Value = null,
    /// Handlers installed by with-exception-handler, innermost last.
    exception_handlers: std.ArrayListUnmanaged(core.Value) = .empty,
    /// The built-in record type used for error objects (set by env_setup).
    error_rtd: ?*core.RecordType = null,
    /// The process argument list for (command-line), set by the host.
    command_line: ?core.Value = null,
    /// Libraries registered by define-library, keyed by the canonical
    /// space-joined library name (e.g. "my lib").
    library_registry: std.StringHashMapUnmanaged(*core.Module) = .empty,
    /// Source locations of parsed forms, keyed by pair pointer.
    source_locations: parser.FormLocations = .empty,
    /// Idle VM instances kept for primitive callbacks. Creating a VM allocates
    /// a large value stack and frame array, so `vm.callProc` borrows from here
    /// instead of allocating one per call (`map` calls it once per element).
    vm_pool: std.ArrayListUnmanaged(*vm.VM) = .empty,
    /// Top-level names the current compilation unit will define. A macro
    /// template may reference one before its `define` has run, so hygiene
    /// renaming must leave these alone.
    pending_globals: std.StringHashMapUnmanaged(void) = .empty,
    /// Location of the most recent uncaught runtime error, when known.
    last_error_file: ?[]const u8 = null,
    last_error_line: ?u32 = null,
    /// Nesting depth of evalString/evalForm calls. The time-limit clock starts
    /// with the outermost call only, so nested evaluation (macro expansion,
    /// `eval`, `load`) cannot extend the budget.
    eval_depth: u32 = 0,
    /// Current expression nesting depth inside the compiler.
    compile_depth: u32 = 0,
    /// Current nesting of VM runs started by primitive callbacks.
    native_depth: u32 = 0,
    /// Files currently being loaded by `include`, `import`, or `load`, so a
    /// file that includes itself is reported instead of recursing forever.
    loading_files: std.StringHashMapUnmanaged(void) = .empty,

    /// Initializes a new `Interpreter` instance.
    /// Sets up the GC, creates the root environment, populates it with primitives
    /// according to `flags`, and loads the standard library.
    ///
    /// Parameters:
    /// - `flags`: A `SandboxFlags` struct specifying which capabilities to enable.
    ///
    /// Returns:
    /// An initialized `Interpreter`, or an error if initialization fails.
    pub fn init(flags: SandboxFlags) !Interpreter {
        ensureGcInitialized();
        const allocator = gc.allocator;

        var self: Interpreter = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .root_env = undefined,
            .last_error_message = null,
            .module_cache = std.StringHashMap(*core.Module).init(allocator),
            .time_limit_ms = flags.time_limit_ms,
            .enable_filesystem = flags.enable_filesystem,
        };

        const root_env = try allocator.create(core.Environment);
        root_env.* = .{
            .bindings = std.StringHashMap(core.Value).init(allocator),
            .outer = null,
            .allocator = allocator,
        };
        try root_env.bindings.ensureTotalCapacity(8);
        gc.add_roots(@intFromPtr(root_env), @intFromPtr(root_env) + @sizeOf(core.Environment));
        self.root_env = root_env;

        try root_env.set(&self, "nil", core.Value.nil);

        if (flags.enable_math) {
            try env_setup.populate_math(&self);
        }
        if (flags.enable_lists) {
            try env_setup.populate_lists(&self);
        }
        if (flags.enable_predicates) {
            try env_setup.populate_predicates(&self);
        }
        if (flags.enable_strings) {
            try env_setup.populate_strings(&self);
        }
        if (flags.enable_io) {
            try env_setup.populate_io(&self, flags);
        }
        try env_setup.populate_control(&self, flags);
        try env_setup.populate_modules(&self);
        try env_setup.populate_process(&self, flags);
        try env_setup.populate_vectors(&self);
        try env_setup.populate_hashmaps(&self);
        try env_setup.populate_ports(&self, flags);
        try env_setup.populate_os(&self, flags);
        try env_setup.populate_datetime(&self);
        try env_setup.populate_format(&self);
        try env_setup.populate_json(&self);
        try env_setup.populate_regex(&self);

        const std_lib_source = @embedFile("../stdlib/std.elz");
        var std_lib_forms = try parser.readAllTracked(std_lib_source, allocator, "<stdlib>", &self.source_locations);
        defer std_lib_forms.deinit(allocator);

        if (std_lib_forms.items.len > 0) {
            var fuel: u64 = std.math.maxInt(u64);
            const proto = try @import("./compiler.zig").Compiler.compileTopLevel(allocator, &self, std_lib_forms.items, self.root_env, &fuel);
            // Protos are GC-allocated and may be referenced by closures stored in the environment.
            // Do NOT call proto.deinit() — the GC collects sub-protos when closures are released.
            var machine = try @import("./vm.zig").VM.init(&self);
            defer machine.deinit();
            _ = try machine.runProto(proto, null);
        }

        return self;
    }

    /// Compiles and executes a string of Elz source code.
    /// Parses `source` into forms, compiles them to bytecode, and runs them on the VM
    /// in the root environment.
    ///
    /// Parameters:
    /// - `self`: A pointer to the `Interpreter` instance.
    /// - `source`: A string slice containing the Elz code to evaluate.
    /// - `fuel`: A pointer to a `u64` value that represents the maximum number of evaluation steps
    ///           allowed. This is a mechanism to prevent infinite loops. The value is decremented
    ///           during evaluation.
    ///
    /// Returns:
    /// The `core.Value` of the last evaluated expression, or an error if parsing or evaluation fails.
    pub fn evalString(self: *Interpreter, source: []const u8, fuel: *u64) !core.Value {
        var forms = try parser.readAllTracked(source, self.allocator, "<eval>", &self.source_locations);
        defer forms.deinit(self.allocator);

        if (forms.items.len == 0) return .unspecified;

        self.beginEval();
        defer self.endEval();

        const proto = try compiler.Compiler.compileTopLevel(self.allocator, self, forms.items, self.root_env, fuel);
        // Protos are GC-allocated and may be referenced by closures stored in the environment.
        // Do NOT call proto.deinit() — the GC collects sub-protos when closures are released.

        var machine = try vm.VM.init(self);
        defer machine.deinit();

        return wrapEvalResult(self, machine.runProto(proto, fuel));
    }

    /// Loads a module file, evaluates every form in it, and caches the result.
    /// Returns the cached `core.Value.module` if the path was already loaded.
    pub fn importModule(self: *Interpreter, path_val: core.Value) core.ElzError!core.Value {
        if (path_val != .string) return core.ElzError.InvalidArgument;
        if (!self.enable_filesystem) {
            self.last_error_message = "import: filesystem access is disabled";
            return core.ElzError.PermissionDenied;
        }
        const path_str = path_val.string.bytes;

        if (self.module_cache.get(path_str)) |cached_mod_ptr| {
            return core.Value{ .module = cached_mod_ptr };
        }

        if (!self.beginLoading(path_str)) {
            self.last_error_message = std.fmt.allocPrint(self.allocator, "import: '{s}' imports itself", .{path_str}) catch null;
            return core.ElzError.InvalidArgument;
        }
        defer self.endLoading(path_str);

        const source_bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path_str, self.allocator, .limited(1024 * 1024)) catch {
            self.last_error_message = "Failed to read module file.";
            return core.ElzError.InvalidArgument;
        };
        defer self.allocator.free(source_bytes);

        var forms = @import("parser.zig").readAllTracked(source_bytes, self.allocator, try self.allocator.dupe(u8, path_str), &self.source_locations) catch {
            self.last_error_message = "Failed to parse module file.";
            return core.ElzError.InvalidArgument;
        };
        defer forms.deinit(self.allocator);

        // Snapshot the set of keys already defined in root_env so we can identify
        // the bindings added by the module.
        var existing_keys = std.StringHashMapUnmanaged(void).empty;
        defer existing_keys.deinit(self.allocator);
        {
            var it = self.root_env.bindings.iterator();
            while (it.next()) |entry| {
                try existing_keys.put(self.allocator, entry.key_ptr.*, {});
            }
        }

        // Compile and run all module forms into root_env (globals always go there).
        {
            var local_fuel: u64 = std.math.maxInt(u64);
            const proto = try compiler.Compiler.compileTopLevel(self.allocator, self, forms.items, self.root_env, &local_fuel);
            var machine = try vm.VM.init(self);
            defer machine.deinit();
            _ = try machine.runProto(proto, &local_fuel);
        }

        const mod_ptr = try self.allocator.create(core.Module);
        mod_ptr.* = .{
            .exports = std.StringHashMap(core.Value).init(self.allocator),
        };

        var temp = std.ArrayListUnmanaged(struct { k: []const u8, v: core.Value }).empty;
        defer temp.deinit(self.allocator);

        // Collect all bindings that were added to root_env by the module.
        {
            var it = self.root_env.bindings.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.len > 0 and key[0] == '_') continue;
                if (existing_keys.contains(key)) continue;
                try temp.append(self.allocator, .{ .k = key, .v = entry.value_ptr.* });
            }
        }

        try mod_ptr.exports.ensureTotalCapacity(@intCast(temp.items.len));
        for (temp.items) |kv| {
            try mod_ptr.exports.put(kv.k, kv.v);
        }

        const cached_name = try self.allocator.dupe(u8, path_str);
        try self.module_cache.put(cached_name, mod_ptr);

        return core.Value{ .module = mod_ptr };
    }

    /// Compiles and executes a single pre-parsed Elz form in the root environment.
    /// Useful when the caller controls parsing (e.g., the REPL) and needs per-form
    /// error handling without going through `evalString`.
    pub fn evalForm(self: *Interpreter, form: *const core.Value, fuel: *u64) core.ElzError!core.Value {
        self.beginEval();
        defer self.endEval();
        const forms = [_]core.Value{form.*};
        const proto = try compiler.Compiler.compileTopLevel(self.allocator, self, &forms, self.root_env, fuel);
        // Protos are GC-allocated and may be referenced by closures stored in the environment.
        // Do NOT call proto.deinit() — the GC collects sub-protos when closures are released.

        var machine = try vm.VM.init(self);
        defer machine.deinit();

        return wrapEvalResult(self, machine.runProto(proto, fuel));
    }

    /// Starts the time-limit clock for an outermost evaluation.
    fn beginEval(self: *Interpreter) void {
        if (self.eval_depth == 0 and self.time_limit_ms != null) {
            self.eval_start_ms = currentTimeMs();
            self.time_check_counter = 0;
        }
        self.eval_depth += 1;
    }

    fn endEval(self: *Interpreter) void {
        self.eval_depth -= 1;
    }

    /// Marks `path` as being loaded. Returns false when it is already in
    /// progress, which means the file recursively includes or imports itself.
    pub fn beginLoading(self: *Interpreter, path: []const u8) bool {
        if (self.loading_files.contains(path)) return false;
        const owned = self.allocator.dupe(u8, path) catch return true;
        self.loading_files.put(self.allocator, owned, {}) catch {};
        return true;
    }

    pub fn endLoading(self: *Interpreter, path: []const u8) void {
        _ = self.loading_files.remove(path);
    }

    /// Converts internal CPS signals into embedder-facing errors at the API boundary.
    /// `EscapeContinuationInvoked` must never reach embedder code; if it does (e.g.,
    /// a stale escape continuation called outside its dynamic extent) we return
    /// `InvalidArgument` with a descriptive message.
    fn wrapEvalResult(self: *Interpreter, result: core.ElzError!core.Value) core.ElzError!core.Value {
        return result catch |err| switch (err) {
            error.EscapeContinuationInvoked => {
                self.last_error_message = "escape continuation invoked outside its dynamic extent";
                return error.InvalidArgument;
            },
            else => err,
        };
    }

    /// Increments the time-check step counter and, every 256 steps, compares elapsed
    /// wall-clock time against the configured limit. Returns `TimeLimitExceeded` if over.
    /// Called by vm.zig and primitives to check the time budget without duplicating the logic.
    pub fn checkTimeBudget(self: *Interpreter) core.ElzError!void {
        self.time_check_counter +%= 1;
        if (self.time_check_counter & 0xFF == 0) {
            if (self.time_limit_ms) |limit| {
                // No eval window yet (e.g. the stdlib load during init): nothing to limit.
                const start = self.eval_start_ms orelse return;
                const elapsed = currentTimeMs() - start;
                if (elapsed >= @as(i64, @intCast(limit))) return core.ElzError.TimeLimitExceeded;
            }
        }
    }

    /// Releases resources held by this `Interpreter`.
    /// Most memory is GC-managed; this cleans up the module cache.
    pub fn deinit(self: *Interpreter) void {
        self.module_cache.deinit();
        for (self.vm_pool.items) |machine| {
            machine.deinit();
            self.allocator.destroy(machine);
        }
        self.vm_pool.deinit(self.allocator);
        self.pending_globals.deinit(self.allocator);
    }

    /// Returns the lazily initialized port that wraps the host's standard input stream.
    pub fn currentInputPort(self: *Interpreter) !*core.Port {
        if (self.stdin_port) |p| return p;
        const port = try self.allocator.create(core.Port);
        port.* = try core.Port.fromStandard(self.allocator, self.io, std.Io.File.stdin(), true, "<stdin>");
        self.stdin_port = port;
        return port;
    }

    /// Returns the lazily initialized port that wraps the host's standard output stream.
    pub fn currentOutputPort(self: *Interpreter) !*core.Port {
        if (self.stdout_port) |p| return p;
        const port = try self.allocator.create(core.Port);
        port.* = try core.Port.fromStandard(self.allocator, self.io, std.Io.File.stdout(), false, "<stdout>");
        self.stdout_port = port;
        return port;
    }

    /// Returns the lazily initialized port that wraps the host's standard error stream.
    pub fn currentErrorPort(self: *Interpreter) !*core.Port {
        if (self.stderr_port) |p| return p;
        const port = try self.allocator.create(core.Port);
        port.* = try core.Port.fromStandard(self.allocator, self.io, std.Io.File.stderr(), false, "<stderr>");
        self.stderr_port = port;
        return port;
    }
};

test "interpreter init and basic eval" {
    var interp = try Interpreter.init(.{});
    defer interp.deinit();

    // Test that nil is defined
    const nil_val = try interp.root_env.get("nil", &interp);
    try std.testing.expect(nil_val == .nil);

    // Test basic arithmetic
    var fuel: u64 = 1000;
    const result = try interp.evalString("(+ 1 2 3)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 6), result.exact_integer);
}

test "interpreter evalString with multiple expressions" {
    var interp = try Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 1000;
    // Last expression is returned
    const result = try interp.evalString("(define x 10) (+ x 5)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 15), result.exact_integer);
}

test "interpreter sandbox flags" {
    // Test with math disabled
    var interp = try Interpreter.init(.{ .enable_math = false });
    defer interp.deinit();

    var fuel: u64 = 1000;
    // With math disabled, + should not be defined
    const result = interp.evalString("(+ 1 2)", &fuel);
    try std.testing.expectError(core.ElzError.SymbolNotFound, result);
}

test "interpreter eval lambda" {
    var interp = try Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 1000;
    const result = try interp.evalString("((lambda (x) (* x x)) 5)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 25), result.exact_integer);
}

test "stale escape continuation returns InvalidArgument, not EscapeContinuationInvoked" {
    // A stale escape continuation (invoked after call/ec has already returned) must
    // not leak EscapeContinuationInvoked to the embedder. wrapEvalResult converts it
    // to InvalidArgument with a descriptive message.
    var interp = try Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 100_000;
    // Capture the escape continuation k outside its extent.
    _ = try interp.evalString("(define stale-k #f)", &fuel);
    _ = try interp.evalString("(call/ec (lambda (k) (set! stale-k k) 42))", &fuel);
    // Now invoke the stale escape continuation.
    const result = interp.evalString("(stale-k 99)", &fuel);
    try std.testing.expectError(core.ElzError.InvalidArgument, result);
    try std.testing.expect(interp.last_error_message != null);
}

test "cps state is grouped under interp.cps" {
    // Verify the CPS fields are accessible via the sub-struct and initialise to zero/null.
    var interp = try Interpreter.init(.{});
    defer interp.deinit();

    try std.testing.expect(interp.cps.escape_value == null);
    try std.testing.expect(interp.cps.winders == null);
}
