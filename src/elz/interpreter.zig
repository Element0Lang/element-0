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
    /// A full continuation that was invoked from a VM run other than its own,
    /// travelling up the native stack as `EscapeContinuationInvoked` until the
    /// run it belongs to reinstates it.
    pending_cont: ?*core.Continuation = null,
    pending_value: core.Value = .unspecified,
};

/// What a hygiene-renamed identifier stands for.
pub const HygieneAlias = struct {
    base: []const u8,
    def_scope_id: u64,
};

/// One call frame of a recorded backtrace.
pub const BacktraceFrame = struct {
    /// The function's debug name, or "<lambda>".
    name: []const u8,
    /// Source file, "" when unknown.
    file: []const u8,
    /// Source line, 0 when unknown.
    line: u32,
};

/// Upper bound on recorded frames, so a runaway recursion does not turn the
/// error report into a screenful of identical lines.
pub const MAX_BACKTRACE_FRAMES: usize = 40;

/// Everything known about the most recent error. Producers fill it through
/// `Interpreter.fail`; the catch site (`try`, the REPL, an embedder) reads it
/// and calls `clear`. Only this struct carries error detail; the Zig error
/// value itself is just the classification.
pub const ErrorState = struct {
    /// A human-readable message, when the failing operation supplied one.
    message: ?[]const u8 = null,
    /// Location of the failing form, when the source was read with tracking.
    file: ?[]const u8 = null,
    line: ?u32 = null,
    /// The object passed to `raise`, `raise-continuable`, or `error`, carried
    /// alongside `ElzError.UserError` until a handler consumes it.
    payload: ?core.Value = null,
    /// When true, the VM records the call frames an error unwinds through in
    /// `backtrace`, innermost first. Hosts such as the REPL turn this on; it
    /// is off by default because errors caught by `try` pay for it too.
    collect_backtrace: bool = false,
    backtrace: std.ArrayListUnmanaged(BacktraceFrame) = .empty,

    /// Forgets the current error. Call this once a report has been consumed so
    /// stale detail cannot attach itself to the next failure.
    pub fn clear(self: *ErrorState) void {
        self.message = null;
        self.file = null;
        self.line = null;
        self.payload = null;
        self.backtrace.clearRetainingCapacity();
    }
};

/// Bookkeeping for the wall-clock limit in `SandboxFlags.time_limit_ms`.
pub const TimeBudget = struct {
    /// Timestamp (ms) when the outermost evaluation started.
    start_ms: ?i64 = null,
    /// Step counter for throttling time checks (check every N steps).
    check_counter: u64 = 0,
    /// Nesting depth of evalString/evalForm calls. The clock starts with the
    /// outermost call only, so nested evaluation (macro expansion, `eval`,
    /// `load`) cannot extend the budget.
    eval_depth: u32 = 0,
};

/// State owned by the compiler and macro expander. Nothing in the VM or the
/// primitives should need to read it.
pub const CompilerState = struct {
    /// Hygiene aliases: a fresh identifier introduced by a `syntax-rules`
    /// template, mapped to the name it stands for and the scope the macro
    /// was defined in. The compiler resolves an alias from that scope.
    hygiene_aliases: std.StringHashMapUnmanaged(HygieneAlias) = .empty,
    /// Top-level names the current compilation unit will define. A macro
    /// template may reference one before its `define` has run, so hygiene
    /// renaming must leave these alone.
    pending_globals: std.StringHashMapUnmanaged(void) = .empty,
    /// Hands out compiler scope identities.
    id_counter: u64 = 0,
    /// Current expression nesting depth inside the compiler.
    depth: u32 = 0,
    /// Files currently being loaded by `include`, `import`, or `load`, so a
    /// file that includes itself is reported instead of recursing forever.
    loading_files: std.StringHashMapUnmanaged(void) = .empty,
    /// Libraries registered by define-library, keyed by the canonical
    /// space-joined library name (e.g. "my lib").
    library_registry: std.StringHashMapUnmanaged(*core.Module) = .empty,
    /// Loaded file modules, so a file imported twice is parsed and run once.
    module_cache: std.StringHashMapUnmanaged(*core.Module) = .empty,
    /// Source locations of parsed forms, keyed by pair pointer.
    source_locations: parser.FormLocations = .empty,
};

/// State owned by the VM and the primitives that run on it.
pub const RuntimeState = struct {
    /// Idle VM instances kept for primitive callbacks. Creating a VM allocates
    /// a large value stack and frame array, so `vm.callProc` borrows from here
    /// instead of allocating one per call (`map` calls it once per element).
    vm_pool: std.ArrayListUnmanaged(*vm.VM) = .empty,
    /// Current nesting of VM runs started by primitive callbacks.
    native_depth: u32 = 0,
    /// Handlers installed by with-exception-handler, innermost last.
    exception_handlers: std.ArrayListUnmanaged(core.Value) = .empty,
    /// Escape-continuation and dynamic-wind state.
    /// Only primitives/control.zig should read or write these fields.
    cps: CpsState = .{},
    /// The built-in record type used for error objects (set by env_setup).
    error_rtd: ?*core.RecordType = null,
    /// Counter for generating unique symbols via `gensym`.
    gensym_counter: u64 = 0,
    /// The current ports. Populated lazily on first reference.
    stdin_port: ?*core.Port = null,
    stdout_port: ?*core.Port = null,
    stderr_port: ?*core.Port = null,
    /// The Scheme name each primitive was first registered under, keyed by
    /// function address, so a failure inside a primitive can be attributed
    /// even when the primitive supplied no message of its own.
    primitive_names: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,
    /// Hands out identities to VM runs (see `vm.VM.runGuarded`).
    run_counter: u64 = 0,
    /// The runs currently on the native stack, outermost first. A full
    /// continuation may only be reinstated into one of these.
    active_runs: std.ArrayListUnmanaged(u64) = .empty,
    /// The `call/cc` primitive. The VM recognises a call to it and captures
    /// the continuation inline; when it is reached through a native path such
    /// as `apply`, the primitive itself runs and yields an escape-only
    /// continuation, since the native frame cannot be captured.
    callcc_fn: ?core.PrimitiveFn = null,
};

/// `Interpreter` is the top-level handle for the Elz scripting engine.
///
/// The first three fields and `command_line` are the embedding surface. The
/// remaining fields group the engine's mutable state by owner, so a reader can
/// tell which component a piece of state belongs to.
pub const Interpreter = struct {
    /// Allocator used for environment bindings and the module cache.
    allocator: std.mem.Allocator,
    /// The I/O implementation used for file operations, sleeping, etc.
    io: std.Io,
    /// The root environment, containing all built-in functions and global variables.
    root_env: *core.Environment,
    /// The capabilities and limits this interpreter was created with.
    flags: SandboxFlags = .{},
    /// The process argument list for (command-line), set by the host.
    command_line: ?core.Value = null,
    /// Detail about the most recent error. See `ErrorState`.
    last_error: ErrorState = .{},
    /// Wall-clock limit bookkeeping.
    budget: TimeBudget = .{},
    /// Compiler and macro expander state.
    compiler: CompilerState = .{},
    /// VM and primitive state.
    runtime: RuntimeState = .{},

    /// Records `message` as the detail for `err` and returns `err`, so a
    /// failing operation can be written as `return interp.fail(...)`.
    pub fn fail(self: *Interpreter, err: core.ElzError, comptime fmt: []const u8, args: anytype) core.ElzError {
        self.last_error.message = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
        return err;
    }

    /// Like `fail` for a message that needs no formatting.
    pub fn failWith(self: *Interpreter, err: core.ElzError, message: []const u8) core.ElzError {
        self.last_error.message = message;
        return err;
    }

    /// Binds a Zig primitive under `name` and remembers the name for error
    /// reports. All built-ins are registered this way (see `env_setup.zig`).
    pub fn definePrimitive(self: *Interpreter, name: []const u8, f: core.PrimitiveFn) !void {
        try self.root_env.set(name, core.Value{ .procedure = f });
        const entry = try self.runtime.primitive_names.getOrPut(self.allocator, @intFromPtr(f));
        if (!entry.found_existing) entry.value_ptr.* = name;
    }

    /// Whether the VM run with this id is still on the native stack.
    pub fn isActiveRun(self: *const Interpreter, run_id: u64) bool {
        for (self.runtime.active_runs.items) |id| {
            if (id == run_id) return true;
        }
        return false;
    }

    /// The name `f` was first registered under, if it is a known primitive.
    pub fn primitiveName(self: *const Interpreter, f: core.PrimitiveFn) ?[]const u8 {
        return self.runtime.primitive_names.get(@intFromPtr(f));
    }

    /// Called by the VM when a primitive returns `err` without recording a
    /// message. Supplies a generic one naming the primitive for the error
    /// kinds where that is meaningful, and passes the error on.
    pub fn describePrimitiveFailure(self: *Interpreter, err: core.ElzError, f: core.PrimitiveFn, argc: usize) core.ElzError {
        if (self.last_error.message != null) return err;
        const name = self.primitiveName(f) orelse return err;
        return switch (err) {
            error.WrongArgumentCount => self.fail(err, "{s}: wrong number of arguments (got {d})", .{ name, argc }),
            error.InvalidArgument => self.fail(err, "{s}: invalid argument", .{name}),
            error.DivisionByZero => self.fail(err, "{s}: division by zero", .{name}),
            else => err,
        };
    }

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
            .flags = flags,
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

        try root_env.set("nil", core.Value.nil);

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
        var std_lib_forms = try parser.readAllTracked(std_lib_source, allocator, "<stdlib>", &self.compiler.source_locations);
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
        var forms = try parser.readAllTracked(source, self.allocator, "<eval>", &self.compiler.source_locations);
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
        if (!self.flags.enable_filesystem) {
            return self.failWith(core.ElzError.PermissionDenied, "import: filesystem access is disabled");
        }
        const path_str = path_val.string.bytes;

        if (self.compiler.module_cache.get(path_str)) |cached_mod_ptr| {
            return core.Value{ .module = cached_mod_ptr };
        }

        if (!self.beginLoading(path_str)) {
            return self.fail(core.ElzError.InvalidArgument, "import: '{s}' imports itself", .{path_str});
        }
        defer self.endLoading(path_str);

        const source_bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path_str, self.allocator, .limited(1024 * 1024)) catch {
            return self.failWith(core.ElzError.InvalidArgument, "Failed to read module file.");
        };
        defer self.allocator.free(source_bytes);

        var forms = @import("parser.zig").readAllTracked(source_bytes, self.allocator, try self.allocator.dupe(u8, path_str), &self.compiler.source_locations) catch {
            return self.failWith(core.ElzError.InvalidArgument, "Failed to parse module file.");
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
        try self.compiler.module_cache.put(self.allocator, cached_name, mod_ptr);

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
        if (self.budget.eval_depth == 0 and self.flags.time_limit_ms != null) {
            self.budget.start_ms = currentTimeMs();
            self.budget.check_counter = 0;
        }
        self.budget.eval_depth += 1;
    }

    fn endEval(self: *Interpreter) void {
        self.budget.eval_depth -= 1;
    }

    /// Marks `path` as being loaded. Returns false when it is already in
    /// progress, which means the file recursively includes or imports itself.
    pub fn beginLoading(self: *Interpreter, path: []const u8) bool {
        if (self.compiler.loading_files.contains(path)) return false;
        const owned = self.allocator.dupe(u8, path) catch return true;
        self.compiler.loading_files.put(self.allocator, owned, {}) catch {};
        return true;
    }

    pub fn endLoading(self: *Interpreter, path: []const u8) void {
        _ = self.compiler.loading_files.remove(path);
    }

    /// Converts internal CPS signals into embedder-facing errors at the API boundary.
    /// `EscapeContinuationInvoked` must never reach embedder code; if it does (e.g.,
    /// a stale escape continuation called outside its dynamic extent) we return
    /// `InvalidArgument` with a descriptive message.
    fn wrapEvalResult(self: *Interpreter, result: core.ElzError!core.Value) core.ElzError!core.Value {
        return result catch |err| switch (err) {
            error.EscapeContinuationInvoked => {
                return self.failWith(error.InvalidArgument, "escape continuation invoked outside its dynamic extent");
            },
            else => err,
        };
    }

    /// Increments the time-check step counter and, every 256 steps, compares elapsed
    /// wall-clock time against the configured limit. Returns `TimeLimitExceeded` if over.
    /// Called by vm.zig and primitives to check the time budget without duplicating the logic.
    pub fn checkTimeBudget(self: *Interpreter) core.ElzError!void {
        self.budget.check_counter +%= 1;
        if (self.budget.check_counter & 0xFF == 0) {
            if (self.flags.time_limit_ms) |limit| {
                // No eval window yet (e.g. the stdlib load during init): nothing to limit.
                const start = self.budget.start_ms orelse return;
                const elapsed = currentTimeMs() - start;
                if (elapsed >= @as(i64, @intCast(limit))) return core.ElzError.TimeLimitExceeded;
            }
        }
    }

    /// Releases resources held by this `Interpreter`.
    /// Most memory is GC-managed; this cleans up the module cache.
    pub fn deinit(self: *Interpreter) void {
        self.compiler.module_cache.deinit(self.allocator);
        for (self.runtime.vm_pool.items) |machine| {
            machine.deinit();
            self.allocator.destroy(machine);
        }
        self.runtime.vm_pool.deinit(self.allocator);
        self.compiler.pending_globals.deinit(self.allocator);
    }

    /// Returns the lazily initialized port that wraps the host's standard input stream.
    pub fn currentInputPort(self: *Interpreter) !*core.Port {
        if (self.runtime.stdin_port) |p| return p;
        const port = try self.allocator.create(core.Port);
        port.* = try core.Port.fromStandard(self.allocator, self.io, std.Io.File.stdin(), true, "<stdin>");
        self.runtime.stdin_port = port;
        return port;
    }

    /// Returns the lazily initialized port that wraps the host's standard output stream.
    pub fn currentOutputPort(self: *Interpreter) !*core.Port {
        if (self.runtime.stdout_port) |p| return p;
        const port = try self.allocator.create(core.Port);
        port.* = try core.Port.fromStandard(self.allocator, self.io, std.Io.File.stdout(), false, "<stdout>");
        self.runtime.stdout_port = port;
        return port;
    }

    /// Returns the lazily initialized port that wraps the host's standard error stream.
    pub fn currentErrorPort(self: *Interpreter) !*core.Port {
        if (self.runtime.stderr_port) |p| return p;
        const port = try self.allocator.create(core.Port);
        port.* = try core.Port.fromStandard(self.allocator, self.io, std.Io.File.stderr(), false, "<stderr>");
        self.runtime.stderr_port = port;
        return port;
    }
};

test "interpreter init and basic eval" {
    var interp = try Interpreter.init(.{});
    defer interp.deinit();

    // Test that nil is defined
    const nil_val = try interp.root_env.get("nil");
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
    try std.testing.expect(interp.last_error.message != null);
}

test "cps state is grouped under interp.runtime.cps" {
    // Verify the CPS fields are accessible via the sub-struct and initialise to zero/null.
    var interp = try Interpreter.init(.{});
    defer interp.deinit();

    try std.testing.expect(interp.runtime.cps.escape_value == null);
    try std.testing.expect(interp.runtime.cps.winders == null);
}
