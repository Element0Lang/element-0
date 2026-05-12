const std = @import("std");
const builtin = @import("builtin");
const core = @import("./core.zig");
const env_setup = @import("./env_setup.zig");
const eval = @import("./eval.zig");
const parser = @import("./parser.zig");
const gc = @import("gc.zig");

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

/// `SandboxFlags` is a struct that defines the features to be enabled in the Elz interpreter.
/// This allows for creating a sandboxed environment with a restricted set of capabilities.
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
    /// Maximum wall-clock execution time in milliseconds. Null means no limit.
    time_limit_ms: ?u64 = null,
};

/// CPS trampoline state bundled away from the public Interpreter surface.
/// All fields are implementation details of eval.zig and primitives/control.zig.
pub const CpsState = struct {
    /// Value carried by the most recently invoked escape continuation.
    escape_value: ?core.Value = null,
    /// ID field reserved for future use (currently unused; kept for ABI stability).
    escape_id: u64 = 0,
    /// Counter for generating unique escape continuation IDs, passed to primitive fuel params.
    escape_id_counter: u64 = 0,
    /// Innermost active dynamic-wind frame, null when none is in effect.
    winders: ?*core.Winder = null,
};

/// `Interpreter` is the main struct for the Elz interpreter.
/// It holds the state of the interpreter, including the root environment, allocator, and module cache.
pub const Interpreter = struct {
    /// The memory allocator used by the interpreter.
    allocator: std.mem.Allocator,
    /// The I/O implementation used for file operations, sleeping, etc.
    io: std.Io,
    /// The root environment of the interpreter, containing the built-in functions and variables.
    root_env: *core.Environment,
    /// A message describing the last error that occurred, if any.
    last_error_message: ?[]const u8 = null,
    /// A cache for loaded modules to avoid redundant parsing and evaluation.
    module_cache: std.StringHashMap(*core.Module),
    /// Counter for generating unique symbols with gensym (thread-safe per interpreter).
    gensym_counter: u64 = 0,
    /// Maximum wall-clock execution time in milliseconds (null = no limit).
    time_limit_ms: ?u64 = null,
    /// Timestamp (ms) when the current evaluation started.
    eval_start_ms: ?i64 = null,
    /// Step counter for throttling time checks (check every N steps).
    time_check_counter: u64 = 0,
    /// CPS trampoline state: escape-continuation side-channel and dynamic-wind chain.
    /// Only eval.zig and primitives/control.zig should read or write these fields.
    /// Embedders must not touch them.
    cps: CpsState = .{},
    /// The current input port. Populated lazily on first reference.
    stdin_port: ?*core.Port = null,
    /// The current output port. Populated lazily on first reference.
    stdout_port: ?*core.Port = null,
    /// Hook set by vm.zig so that eval.zig can dispatch vm_closure values without
    /// directly importing the VM. Registered during Interpreter.init.
    run_vm_closure: ?*const fn (*Interpreter, *core.VmClosure, core.ValueList) core.ElzError!core.Value = null,

    /// Initializes a new Elz interpreter instance.
    /// This function sets up the garbage collector, creates the root environment,
    /// populates it with primitive functions based on the provided `SandboxFlags`,
    /// and loads the standard library.
    ///
    /// Parameters:
    /// - `flags`: A `SandboxFlags` struct specifying which features to enable.
    ///
    /// Returns:
    /// An initialized `Interpreter` instance, or an error if initialization fails.
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
            try env_setup.populate_io(&self);
        }
        try env_setup.populate_control(&self);
        try env_setup.populate_modules(&self);
        try env_setup.populate_process(&self);
        try env_setup.populate_vectors(&self);
        try env_setup.populate_hashmaps(&self);
        try env_setup.populate_ports(&self);
        try env_setup.populate_os(&self);
        try env_setup.populate_datetime(&self);
        try env_setup.populate_format(&self);
        try env_setup.populate_json(&self);
        try env_setup.populate_regex(&self);

        const std_lib_source = @embedFile("../stdlib/std.elz");
        var std_lib_forms = try parser.readAll(std_lib_source, allocator);
        defer std_lib_forms.deinit(allocator);

        var fuel: u64 = 1_000_000;
        for (std_lib_forms.items) |form| {
            _ = try eval.eval(&self, &form, self.root_env, &fuel);
        }

        self.run_vm_closure = @import("vm.zig").runFromEval;

        return self;
    }

    /// Evaluates a string of Elz source code.
    /// This function parses the source code into a series of expressions and then evaluates them
    /// in the interpreter's root environment.
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
        var forms = try parser.readAll(source, self.allocator);
        defer forms.deinit(self.allocator);

        // Set the eval start time for time-limited execution
        if (self.time_limit_ms != null) {
            self.eval_start_ms = currentTimeMs();
            self.time_check_counter = 0;
        }

        var result: core.Value = .unspecified;
        for (forms.items) |form| {
            result = try wrapEvalResult(self, eval.eval(self, &form, self.root_env, fuel));
        }
        return result;
    }

    /// Evaluates a single pre-parsed Elz form in the interpreter's root environment.
    /// Useful when the caller controls parsing (e.g., the REPL) and needs per-form
    /// error handling without going through `evalString`.
    pub fn evalForm(self: *Interpreter, form: *const core.Value, fuel: *u64) core.ElzError!core.Value {
        return wrapEvalResult(self, eval.eval(self, form, self.root_env, fuel));
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
    /// Both eval.zig and vm.zig call this instead of duplicating the logic.
    pub fn checkTimeBudget(self: *Interpreter) core.ElzError!void {
        self.time_check_counter +%= 1;
        if (self.time_check_counter & 0xFF == 0) {
            if (self.time_limit_ms) |limit| {
                const elapsed = currentTimeMs() - (self.eval_start_ms orelse 0);
                if (elapsed >= @as(i64, @intCast(limit))) return core.ElzError.TimeLimitExceeded;
            }
        }
    }

    /// Cleans up resources used by the interpreter.
    /// This method should be called when the interpreter is no longer needed.
    /// Note: With garbage collection, most memory is automatically managed,
    /// but this ensures proper cleanup of the module cache.
    pub fn deinit(self: *Interpreter) void {
        self.module_cache.deinit();
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
    try std.testing.expectEqual(@as(u64, 0), interp.cps.escape_id);
    try std.testing.expect(interp.cps.winders == null);
}
