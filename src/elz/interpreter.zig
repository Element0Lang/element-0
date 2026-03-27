const std = @import("std");
const core = @import("./core.zig");
const env_setup = @import("./env_setup.zig");
const eval = @import("./eval.zig");
const parser = @import("./parser.zig");
const gc = @import("gc.zig");

var gc_once = std.once(init_gc);

fn init_gc() void {
    gc.init();
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

/// `Interpreter` is the main struct for the Elz interpreter.
/// It holds the state of the interpreter, including the root environment, allocator, and module cache.
pub const Interpreter = struct {
    /// The memory allocator used by the interpreter.
    allocator: std.mem.Allocator,
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
    /// Value carried by an escape continuation invocation.
    escape_value: ?core.Value = null,
    /// ID of the active escape continuation (for matching).
    escape_id: u64 = 0,
    /// Counter for generating unique escape continuation IDs.
    escape_id_counter: u64 = 0,

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
        gc_once.call();
        const allocator = gc.allocator;

        var self: Interpreter = .{
            .allocator = allocator,
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
            self.eval_start_ms = std.time.milliTimestamp();
            self.time_check_counter = 0;
        }

        var result: core.Value = .unspecified;
        for (forms.items) |form| {
            result = try eval.eval(self, &form, self.root_env, fuel);
        }
        return result;
    }

    /// Cleans up resources used by the interpreter.
    /// This method should be called when the interpreter is no longer needed.
    /// Note: With garbage collection, most memory is automatically managed,
    /// but this ensures proper cleanup of the module cache.
    pub fn deinit(self: *Interpreter) void {
        self.module_cache.deinit();
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
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 6), result.number);
}

test "interpreter evalString with multiple expressions" {
    var interp = try Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 1000;
    // Last expression is returned
    const result = try interp.evalString("(define x 10) (+ x 5)", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 15), result.number);
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
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 25), result.number);
}
