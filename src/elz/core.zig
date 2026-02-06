const std = @import("std");
const errors = @import("errors.zig");
const ElzError = errors.ElzError;
const interpreter = @import("interpreter.zig");

const gc = @import("gc.zig");

/// A garbage-collected list of `Value`s.
pub const ValueList = gc.GcArrayList(Value);

/// Represents a module in Elz, which is a collection of exported symbols.
pub const Module = struct {
    /// A hash map of exported symbols and their corresponding values.
    exports: std.StringHashMap(Value),
};

/// A `Cell` is a mutable container for a `Value`.
/// It is used to implement mutable variables in Elz.
pub const Cell = struct {
    /// The `Value` contained within the cell.
    content: Value,
};

/// `Environment` represents a lexical scope in the interpreter.
/// It contains a set of bindings from symbols to values and a reference to an outer (enclosing) environment.
pub const Environment = struct {
    /// A hash map of symbol names to their bound `Value`s.
    bindings: std.StringHashMap(Value),
    /// A pointer to the enclosing environment, or `null` if this is the root environment.
    outer: ?*Environment,
    /// The allocator used by this environment.
    allocator: std.mem.Allocator,

    /// Initializes a new environment.
    ///
    /// Parameters:
    /// - `allocator`: The memory allocator to use for the environment's bindings.
    /// - `outer`: An optional pointer to the enclosing environment.
    ///
    /// Returns:
    /// A pointer to the newly created `Environment`, or an error if allocation fails.
    pub fn init(allocator: std.mem.Allocator, outer: ?*Environment) !*Environment {
        const self = try allocator.create(Environment);
        self.* = .{
            .bindings = std.StringHashMap(Value).init(allocator),
            .outer = outer,
            .allocator = allocator,
        };
        try self.bindings.ensureTotalCapacity(8);
        return self;
    }

    /// Retrieves the value of a symbol from the environment or any of its outer environments.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current environment.
    /// - `name`: The name of the symbol to look up.
    /// - `interp`: A pointer to the interpreter instance, used for error reporting.
    ///
    /// Returns:
    /// The `Value` bound to the symbol, or `ElzError.SymbolNotFound` if the symbol is not found.
    pub fn get(self: *const Environment, name: []const u8, interp: *interpreter.Interpreter) ElzError!Value {
        var current_env: ?*const Environment = self;
        while (current_env) |env| {
            if (env.bindings.capacity() > 0) {
                if (env.bindings.get(name)) |value| {
                    return switch (value) {
                        .cell => |c| c.content,
                        else => value,
                    };
                }
            }
            current_env = env.outer;
        }
        interp.last_error_message = std.fmt.allocPrint(self.allocator, "Symbol '{s}' not found.", .{name}) catch null;
        return ElzError.SymbolNotFound;
    }

    /// Checks if a symbol is bound in the current environment or any of its outer environments.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current environment.
    /// - `name`: The name of the symbol to check.
    ///
    /// Returns:
    /// `true` if the symbol is bound, otherwise `false`.
    pub fn contains(self: *const Environment, name: []const u8) bool {
        var current_env: ?*const Environment = self;
        while (current_env) |env| {
            if (env.bindings.contains(name)) {
                return true;
            }
            current_env = env.outer;
        }
        return false;
    }

    /// Binds a symbol to a value in the current environment.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current environment.
    /// - `interp`: A pointer to the interpreter instance (currently unused in this function).
    /// - `name`: The name of the symbol to bind.
    /// - `value`: The `Value` to bind to the symbol.
    ///
    /// Returns:
    /// `void` or an error if memory allocation for the name or value fails.
    pub fn set(self: *Environment, interp: *interpreter.Interpreter, name: []const u8, value: Value) ElzError!void {
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_value = try value.deep_clone(self.allocator);
        try self.bindings.put(owned_name, owned_value);
        _ = interp;
    }

    /// Updates the value of an existing symbol in the current environment or any of its outer environments.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current environment.
    /// - `interp`: A pointer to the interpreter instance, used for error reporting.
    /// - `name`: The name of the symbol to update.
    /// - `value`: The new `Value` for the symbol.
    ///
    /// Returns:
    /// `void` or `ElzError.SymbolNotFound` if the symbol is not bound in any accessible environment.
    pub fn update(self: *Environment, interp: *interpreter.Interpreter, name: []const u8, value: Value) ElzError!void {
        var current_env: ?*Environment = self;
        while (current_env) |env| {
            if (env.bindings.getEntry(name)) |entry| {
                switch (entry.value_ptr.*) {
                    .cell => |c| c.content = try value.deep_clone(self.allocator),
                    else => entry.value_ptr.* = try value.deep_clone(self.allocator),
                }
                return;
            }
            current_env = env.outer;
        }
        interp.last_error_message = std.fmt.allocPrint(self.allocator, "Cannot set! unbound symbol '{s}'.", .{name}) catch null;
        return ElzError.SymbolNotFound;
    }
};

/// Represents a user-defined procedure (lambda) in Elz.
pub const UserDefinedProc = struct {
    /// A list of parameter names (as `Value.symbol`).
    params: ValueList,
    /// The body of the procedure, which is a single `Value` (typically a list of expressions).
    body: Value,
    /// The environment in which the procedure was created, which provides its lexical scope.
    env: *Environment,
};

/// Represents a macro transformer in Element 0.
/// Macros are procedures that transform code before evaluation.
pub const Macro = struct {
    /// The name of the macro (for error messages).
    name: []const u8,
    /// The parameter names of the macro transformer.
    params: ValueList,
    /// The body of the macro transformer.
    body: Value,
    /// The environment in which the macro was defined.
    env: *Environment,
};

/// A pointer to a native Zig function that can be called from Elz.
pub const PrimitiveFn = *const fn (interp: *interpreter.Interpreter, env: *Environment, args: ValueList, fuel: *u64) ElzError!Value;

/// Represents a pair in an Element 0 list.
pub const Pair = struct {
    /// The first element of the pair (the "contents of the address register").
    car: Value,
    /// The second element of the pair (the "contents of the decrement register").
    cdr: Value,
};

/// Represents a vector (mutable fixed-size array) in Element 0.
pub const Vector = struct {
    /// The elements of the vector.
    items: []Value,
};

/// Represents a hash map (key-value store) in Element 0.
/// Keys are stored as string representations for hashing.
pub const HashMap = struct {
    /// The underlying hash map storage using string keys.
    entries: std.StringHashMapUnmanaged(Value),
    /// Allocator used for memory management.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HashMap {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HashMap) void {
        self.entries.deinit(self.allocator);
    }

    pub fn put(self: *HashMap, key: []const u8, value: Value) !void {
        // Check if key already exists to avoid duplicating keys
        if (self.entries.contains(key)) {
            // Key exists, just update value
            self.entries.putAssumeCapacity(key, value);
        } else {
            // New key, need to duplicate
            const owned_key = try self.allocator.dupe(u8, key);
            try self.entries.put(self.allocator, owned_key, value);
        }
    }

    pub fn get(self: *HashMap, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn remove(self: *HashMap, key: []const u8) bool {
        const result = self.entries.fetchRemove(key);
        return result != null;
    }

    pub fn count(self: *HashMap) usize {
        return self.entries.count();
    }
};

/// Represents a port (I/O stream) in Element 0.
/// Ports can be input (for reading) or output (for writing).
pub const Port = struct {
    /// The underlying file handle.
    file: std.fs.File,
    /// Whether this is an input port (true) or output port (false).
    is_input: bool,
    /// Whether the port is open.
    is_open: bool,
    /// Name of the file (for error messages).
    name: []const u8,

    pub fn openInput(allocator: std.mem.Allocator, name: []const u8) !Port {
        const file = try std.fs.cwd().openFile(name, .{});
        return .{
            .file = file,
            .is_input = true,
            .is_open = true,
            .name = try allocator.dupe(u8, name), // Clone to own the memory
        };
    }

    pub fn openOutput(allocator: std.mem.Allocator, name: []const u8) !Port {
        const file = try std.fs.cwd().createFile(name, .{});
        return .{
            .file = file,
            .is_input = false,
            .is_open = true,
            .name = try allocator.dupe(u8, name), // Clone to own the memory
        };
    }

    pub fn close(self: *Port) void {
        if (self.is_open) {
            self.file.close();
            self.is_open = false;
        }
    }

    pub fn readLine(self: *Port, allocator: std.mem.Allocator) !?[]const u8 {
        if (!self.is_input or !self.is_open) return null;
        var buf: [4096]u8 = undefined;
        var read_buf: [1]u8 = undefined;
        var len: usize = 0;

        while (len < buf.len - 1) {
            const bytes_read = self.file.read(&read_buf) catch return null;
            if (bytes_read == 0) {
                // EOF
                if (len == 0) return null;
                break;
            }
            if (read_buf[0] == '\n') break;
            buf[len] = read_buf[0];
            len += 1;
        }

        if (len == 0) return null;
        return try allocator.dupe(u8, buf[0..len]);
    }

    pub fn readChar(self: *Port) !?u8 {
        if (!self.is_input or !self.is_open) return null;
        var buf: [1]u8 = undefined;
        const bytes_read = self.file.read(&buf) catch return null;
        if (bytes_read == 0) return null;
        return buf[0];
    }

    pub fn writeString(self: *Port, str: []const u8) !void {
        if (self.is_input or !self.is_open) return error.InvalidPort;
        _ = try self.file.write(str);
    }
};

/// `Value` is the core data type in the Elz interpreter.
/// It is a tagged union that can represent all the different types of values in the Elz language.
pub const Value = union(enum) {
    /// An Element 0 symbol.
    symbol: []const u8,
    /// A floating-point number.
    number: f64,
    /// A pair, the building block of lists.
    pair: *Pair,
    /// A single character.
    character: u32,
    /// A string of characters.
    string: []const u8,
    /// A boolean value (`#t` or `#f`).
    boolean: bool,
    /// A user-defined procedure (lambda).
    closure: *UserDefinedProc,
    /// A macro transformer (define-macro).
    macro: *Macro,
    /// A built-in (primitive) procedure.
    procedure: PrimitiveFn,
    /// A foreign function interface (FFI) procedure.
    foreign_procedure: *const fn (env: *Environment, args: ValueList) anyerror!Value,
    /// An opaque pointer to a value managed by foreign code.
    opaque_pointer: ?*anyopaque,
    /// A mutable cell for holding a value.
    cell: *Cell,
    /// A module containing exported symbols.
    module: *Module,
    /// A vector (mutable fixed-size array).
    vector: *Vector,
    /// A hash map (key-value store).
    hash_map: *HashMap,
    /// A port (file I/O stream).
    port: *Port,
    /// The `nil` or empty list value.
    nil,
    /// An unspecified or void value.
    unspecified,

    /// Checks if the `Value` is a specific symbol.
    ///
    /// Parameters:
    /// - `self`: The `Value` to check.
    /// - `str`: The string to compare the symbol against.
    ///
    /// Returns:
    /// `true` if the `Value` is a symbol equal to `str`, otherwise `false`.
    pub fn is_symbol(self: Value, comptime str: []const u8) bool {
        return switch (self) {
            .symbol => |s| std.mem.eql(u8, s, str),
            else => false,
        };
    }

    /// Creates a deep copy of the `Value`.
    /// For composite types like pairs and strings, this function allocates new memory
    /// and recursively clones the contents. For simple types, it returns the value itself.
    ///
    /// Parameters:
    /// - `self`: The `Value` to clone.
    /// - `allocator`: The memory allocator to use for the new allocations.
    ///
    /// Returns:
    /// A new `Value` that is a deep copy of the original, or an error if allocation fails.
    pub fn deep_clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .symbol => |s| Value{ .symbol = try allocator.dupe(u8, s) },
            .number, .boolean, .character, .closure, .macro, .procedure, .foreign_procedure, .opaque_pointer, .cell, .module, .nil, .unspecified => self,
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            .pair => |p| {
                const new_pair = try allocator.create(Pair);
                new_pair.* = .{
                    .car = try p.car.deep_clone(allocator),
                    .cdr = try p.cdr.deep_clone(allocator),
                };
                return Value{ .pair = new_pair };
            },
            .vector => |v| {
                const new_vec = try allocator.create(Vector);
                const new_items = try allocator.alloc(Value, v.items.len);
                for (v.items, 0..) |item, i| {
                    new_items[i] = try item.deep_clone(allocator);
                }
                new_vec.* = .{ .items = new_items };
                return Value{ .vector = new_vec };
            },
            .hash_map => self, // Hash maps are not deep cloned (shared reference)
            .port => self, // Ports are not deep cloned (shared reference)
        };
    }

    /// Converts a Zig value to an Elz `Value`.
    /// This function is used for interoperability between Zig and Elz.
    /// It supports a limited set of Zig types.
    ///
    /// Parameters:
    /// - `allocator`: The memory allocator to use for creating new `Value`s (e.g., for strings).
    /// - `v`: The Zig value to convert.
    ///
    /// Returns:
    /// The corresponding Elz `Value`, or a compile error for unsupported types.
    pub fn from(allocator: std.mem.Allocator, v: anytype) !Value {
        return switch (@typeInfo(@TypeOf(v))) {
            .float => Value{ .number = v },
            .int => Value{ .number = @floatFromInt(v) },
            .bool => Value{ .boolean = v },
            .pointer => |p| switch (p.size) {
                .slice => blk: {
                    const s = try allocator.dupe(u8, v);
                    break :blk Value{ .string = s };
                },
                else => @compileError("Unsupported pointer type"),
            },
            else => @compileError("Unsupported from type"),
        };
    }
};

test "core environment" {
    const allocator = std.testing.allocator;
    const testing = std.testing;
    var interp_stub: interpreter.Interpreter = .{
        .allocator = allocator,
        .root_env = undefined,
        .last_error_message = null,
        .module_cache = undefined,
    };

    // Test set and get in the same environment
    var env = try Environment.init(allocator, null);
    try env.set(&interp_stub, "x", Value{ .number = 42 });
    var value = try env.get("x", &interp_stub);
    try testing.expect(value == Value{ .number = 42 });

    // Test get from outer environment
    var outer_env = try Environment.init(allocator, null);
    try outer_env.set(&interp_stub, "y", Value{ .string = "hello" });
    var inner_env = try Environment.init(allocator, outer_env);
    value = try inner_env.get("y", &interp_stub);
    try testing.expect(value == Value{ .string = "hello" });

    // Test update on outer environment
    try inner_env.update(&interp_stub, "y", Value{ .string = "world" });
    value = try outer_env.get("y", &interp_stub);
    try testing.expect(value == Value{ .string = "world" });

    // Test update on symbol not found
    const err = inner_env.update(&interp_stub, "z", Value{ .number = 0 });
    try testing.expectError(ElzError.SymbolNotFound, err);
}
