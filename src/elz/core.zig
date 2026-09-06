const std = @import("std");
const errors = @import("errors.zig");
pub const ElzError = errors.ElzError;
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

/// Returns a `Value` whose symbol name is owned by `allocator`. Strings and
/// heap-allocated reference variants pass through unchanged, so aliased
/// bindings observe each other's mutations (`string-set!` on a string reached
/// through two global names must be visible through both).
fn own_value_slices(value: Value, allocator: std.mem.Allocator) !Value {
    return switch (value) {
        .symbol => |s| Value{ .symbol = try allocator.dupe(u8, s) },
        else => value,
    };
}

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
    ///
    /// Returns:
    /// The `Value` bound to the symbol, or `ElzError.SymbolNotFound` if the symbol is not found.
    /// The environment does not know how to report errors; callers that want a
    /// message attach one with `Interpreter.fail`.
    pub fn get(self: *const Environment, name: []const u8) ElzError!Value {
        return self.lookup(name) orelse ElzError.SymbolNotFound;
    }

    /// Looks a symbol up without reporting an error. Callers that treat a miss
    /// as an ordinary outcome (such as the compiler probing for a macro) must
    /// use this, so a failed probe does not leave a misleading message behind
    /// in `interp.last_error.message`.
    pub fn lookup(self: *const Environment, name: []const u8) ?Value {
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
        return null;
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
    /// - `name`: The name of the symbol to bind.
    /// - `value`: The `Value` to bind to the symbol.
    ///
    /// Returns:
    /// `void` or an error if memory allocation for the name or value fails.
    pub fn set(self: *Environment, name: []const u8, value: Value) ElzError!void {
        const owned_name = try self.allocator.dupe(u8, name);
        // Only the inline byte-slice variants need to own their backing memory; heap
        // values (pair, vector, hash_map, port, cell, closure, ...) are shared by
        // reference so that aliased bindings observe each other's mutations as Scheme
        // requires for `(define w v)` style aliasing.
        const owned_value = try own_value_slices(value, self.allocator);
        try self.bindings.put(owned_name, owned_value);
    }

    /// Removes a binding from this environment only. Returns true when a
    /// binding was present. Used to undo the compile-time transformer bindings
    /// that `let-syntax` installs for the extent of its body.
    pub fn remove(self: *Environment, name: []const u8) bool {
        return self.bindings.remove(name);
    }

    /// Updates the value of an existing symbol in the current environment or any of its outer environments.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current environment.
    /// - `name`: The name of the symbol to update.
    /// - `value`: The new `Value` for the symbol.
    ///
    /// Returns:
    /// `void` or `ElzError.SymbolNotFound` if the symbol is not bound in any accessible environment.
    pub fn update(self: *Environment, name: []const u8, value: Value) ElzError!void {
        var current_env: ?*Environment = self;
        while (current_env) |env| {
            if (env.bindings.getEntry(name)) |entry| {
                const owned = try own_value_slices(value, self.allocator);
                switch (entry.value_ptr.*) {
                    .cell => |c| c.content = owned,
                    else => entry.value_ptr.* = owned,
                }
                return;
            }
            current_env = env.outer;
        }
        return ElzError.SymbolNotFound;
    }
};

/// A heap-allocated upvalue cell shared between a closure and the stack frame that owns the local.
/// While the local is live the cell holds a pointer directly into the stack slot (`open`).
/// When the frame exits the value is copied into the cell itself (`closed`).
/// Storing a `*Value` pointer (rather than a stack index) makes upvalue access correct across
/// multiple VM instances: a primitive may call back into Elz via `callProc`, which creates a
/// fresh VM with a different stack buffer. With a direct pointer, `get`/`set` always reach the
/// right memory regardless of which VM is currently executing.
pub const Upvalue = struct {
    state: union(enum) {
        open: *Value, // pointer directly into the owning VM's stack slot
        closed: Value, // captured value after the owning frame exits
    },
    next: ?*Upvalue = null, // linked list of open upvalues in the VM

    pub fn get(self: *const Upvalue) Value {
        return switch (self.state) {
            .open => |ptr| ptr.*,
            .closed => |v| v,
        };
    }

    pub fn set(self: *Upvalue, val: Value) void {
        switch (self.state) {
            .open => |ptr| ptr.* = val,
            .closed => self.state = .{ .closed = val },
        }
    }

    pub fn close(self: *Upvalue) void {
        switch (self.state) {
            .open => |ptr| self.state = .{ .closed = ptr.* },
            .closed => {},
        }
    }
};

/// A VM-compiled closure: a `FuncProto` (bytecode + constants) paired with captured upvalue cells.
pub const VmClosure = struct {
    proto: *@import("chunk.zig").FuncProto,
    upvals: []*Upvalue,
};

/// One call frame on the VM's call stack.
pub const CallFrame = struct {
    closure: *VmClosure,
    ip: usize,
    /// Index in the value stack where this frame's locals start.
    stack_base: usize,
};

/// An escape continuation created by `call/ec` (and by `call/cc` when it is
/// reached through a native path such as `apply`, where nothing more can be
/// captured). Invoking it unwinds to the `call/ec` frame that created it:
/// the `id` lets that frame recognise its own jump, so an inner `call/ec` no
/// longer swallows a jump aimed at an outer one. `active` becomes false once
/// the creating frame has returned, which makes a stale invocation reportable.
pub const Escape = struct {
    id: u64,
    active: bool = true,
};

/// An active `reset` prompt: the stack height where the reset expression's
/// value belongs and the frame count at the prompt.
pub const Prompt = struct {
    stack_base: usize,
    boundary_frames: usize,
};

/// A captured continuation. `shift` captures the value-stack and frame
/// segment between the enclosing `reset` prompt and the call site, with frame
/// bases relative to the prompt so the segment can be reinstated anywhere.
/// `call/cc` captures the whole state of the current VM run (`full` is set),
/// and reinstating it replaces that run's stack, frames, and prompts.
/// Both kinds are multi-shot.
pub const Continuation = struct {
    stack: []Value,
    frames: []CallFrame,
    /// Upvalues that were open into the captured region when it was taken.
    /// Reinstating re-opens them onto the new copy, so closures created inside
    /// the region and the resumed frames share one location.
    upvals: []CapturedUpvalue = &.{},
    /// Present for a full continuation.
    full: ?Full = null,

    pub const CapturedUpvalue = struct {
        upvalue: *Upvalue,
        /// Stack slot relative to the captured region's base.
        offset: usize,
    };

    pub const Full = struct {
        /// The prompts in effect at capture.
        prompts: []Prompt,
        /// The dynamic-wind frames in effect at capture. Reinstating runs the
        /// `after` thunks of frames being left and the `before` thunks of
        /// frames being re-entered.
        winders: ?*Winder,
        /// The VM run the continuation belongs to. It can only be reinstated
        /// while that run is active, since native frames cannot be copied.
        run_id: u64,
    };
};

/// Represents a macro transformer in Element 0.
/// Macros are procedures that transform code before evaluation.
pub const Macro = struct {
    /// The name of the macro (for error messages).
    name: []const u8,
    /// The transformer's formals, as written: a proper list, dotted list, or
    /// single rest symbol. Arity is checked by the lambda built at expansion.
    formals: Value,
    /// The body of the macro transformer.
    body: Value,
    /// The environment in which the macro was defined.
    env: *Environment,
};

/// One pattern/template pair from a `syntax-rules` form. The pattern starts with the
/// macro keyword (or `_`), as R7RS specifies.
pub const SyntaxRule = struct {
    pattern: Value,
    template: Value,
};

/// Represents a `syntax-rules` macro transformer. Pattern matching uses literal
/// identifiers for exact-name matching and binds remaining identifiers as pattern
/// variables.
pub const SyntaxRulesMacro = struct {
    /// The macro name (for error messages).
    name: []const u8,
    /// Identifier names listed as literals in `(syntax-rules (literal ...) ...)`.
    literals: [][]const u8,
    /// Pattern/template rules, tried top-to-bottom.
    rules: []SyntaxRule,
    /// The environment captured at definition time. Used for hygiene in later slices.
    env: *Environment,
    /// The ellipsis marker (default "..."). Set to "" when "..." is lexically rebound,
    /// or to a custom symbol for the R7RS `(syntax-rules <ellipsis> ...)` form.
    ellipsis: []const u8,
    /// Identity of the compiler scope the transformer was defined in (0 for
    /// none). Free identifiers a template introduces resolve from that scope.
    def_scope_id: u64 = 0,
};

/// A pointer to a native Zig function that can be called from Elz.
pub const PrimitiveFn = *const fn (interp: *interpreter.Interpreter, env: *Environment, args: ValueList, fuel: *u64) ElzError!Value;

/// An exact rational number stored in canonical form (GCD-reduced, positive denominator).
pub const Rational = struct {
    numerator: i64,
    denominator: i64,

    pub fn toFloat(self: Rational) f64 {
        return @as(f64, @floatFromInt(self.numerator)) / @as(f64, @floatFromInt(self.denominator));
    }
};

fn gcd_abs(a: i64, b: i64) i64 {
    var x: i64 = if (a < 0) -a else a;
    var y: i64 = if (b < 0) -b else b;
    while (y != 0) {
        const t = y;
        y = @rem(x, y);
        x = t;
    }
    return x;
}

/// Normalizes a rational number (n/d) into canonical form and returns the
/// appropriate Value: `.exact_integer` if denominator reduces to 1, else
/// `.rational` (heap-allocated). Returns `ElzError.DivisionByZero` if d == 0.
pub fn normalizeRational(n: i64, d: i64, allocator: std.mem.Allocator) ElzError!Value {
    if (d == 0) return ElzError.DivisionByZero;
    const sign: i64 = if (d < 0) -1 else 1;
    const g = gcd_abs(n, d);
    const num = sign * @divTrunc(n, g);
    const den = sign * @divTrunc(d, g);
    if (den == 1) return Value{ .exact_integer = num };
    const r = allocator.create(Rational) catch return ElzError.OutOfMemory;
    r.* = .{ .numerator = num, .denominator = den };
    return Value{ .rational = r };
}

/// An arbitrary-precision exact integer. Only values that do not fit in an
/// i64 are represented this way; see bigint.zig for the arithmetic.
pub const BigInt = struct {
    /// Little-endian magnitude limbs, normalized (no leading zero limbs).
    limbs: []const std.math.big.Limb,
    positive: bool,
};

/// A complex number with inexact real and imaginary parts.
pub const Complex = struct {
    real: f64,
    imag: f64,
};

/// A mutable fixed-size array of bytes.
pub const Bytevector = struct {
    items: []u8,
};

/// A record type descriptor created by define-record-type. Type identity is
/// pointer identity: two definitions with the same name are distinct types.
pub const RecordType = struct {
    name: []const u8,
    field_names: [][]const u8,
};

/// A record instance. `fields` is indexed in the order of the type's field_names.
pub const Record = struct {
    rtd: *RecordType,
    fields: []Value,
};

/// A dynamic-wind frame: a (before, after) pair pushed onto the interpreter
/// dynamic winder chain. The chain is innermost-first.
pub const Winder = struct {
    before: Value,
    after: Value,
    next: ?*Winder,
};

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
        var it = self.entries.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
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
    /// The backing store: either an OS file or an in-memory string buffer.
    kind: Kind,
    /// Whether this is an input port (true) or output port (false).
    is_input: bool,
    /// Whether the port is open.
    is_open: bool,
    /// Name used in error messages and `write` output.
    name: []const u8,
    /// Bytes read ahead by the peek operations and not yet consumed.
    pushback: [4]u8 = undefined,
    pushback_len: u8 = 0,
    pushback_pos: u8 = 0,
    /// Whether this is a binary port (bytevector or binary file backed).
    binary: bool = false,

    pub const Kind = union(enum) {
        /// An OS file handle.
        file: FileKind,
        /// An input port reading from an immutable string.
        string_input: StringInputKind,
        /// An output port accumulating into a growable buffer.
        string_output: StringOutputKind,
    };

    pub const FileKind = struct {
        file: std.Io.File,
        io: std.Io,
        /// When true, `close` does not close the underlying file handle
        /// (used for stdin/stdout which are shared with the host process).
        persistent: bool = false,
    };

    pub const StringInputKind = struct {
        source: []const u8,
        pos: usize = 0,
        allocator: std.mem.Allocator,
    };

    pub const StringOutputKind = struct {
        buffer: std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
    };

    /// Wraps an already-open file as a port without taking ownership of the close.
    pub fn fromStandard(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, is_input: bool, name: []const u8) !Port {
        return .{
            .kind = .{ .file = .{ .file = file, .io = io, .persistent = true } },
            .is_input = is_input,
            .is_open = true,
            .name = try allocator.dupe(u8, name),
        };
    }

    pub fn openInput(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !Port {
        const file = try std.Io.Dir.cwd().openFile(io, name, .{});
        return .{
            .kind = .{ .file = .{ .file = file, .io = io } },
            .is_input = true,
            .is_open = true,
            .name = try allocator.dupe(u8, name),
        };
    }

    pub fn openOutput(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !Port {
        const file = try std.Io.Dir.cwd().createFile(io, name, .{});
        return .{
            .kind = .{ .file = .{ .file = file, .io = io } },
            .is_input = false,
            .is_open = true,
            .name = try allocator.dupe(u8, name),
        };
    }

    /// Creates a string input port that reads from `source` (takes ownership of the slice).
    pub fn fromString(allocator: std.mem.Allocator, source: []const u8) !Port {
        return .{
            .kind = .{ .string_input = .{ .source = source, .pos = 0, .allocator = allocator } },
            .is_input = true,
            .is_open = true,
            .name = try allocator.dupe(u8, "<string>"),
        };
    }

    /// Creates an empty string output port.
    pub fn openStringOutput(allocator: std.mem.Allocator) !Port {
        return .{
            .kind = .{ .string_output = .{ .buffer = .empty, .allocator = allocator } },
            .is_input = false,
            .is_open = true,
            .name = try allocator.dupe(u8, "<string>"),
        };
    }

    /// Returns the accumulated string from a string output port. The caller owns the slice.
    pub fn getString(self: *Port, allocator: std.mem.Allocator) ![]const u8 {
        switch (self.kind) {
            .string_output => |*sk| return allocator.dupe(u8, sk.buffer.items),
            else => return error.InvalidPort,
        }
    }

    pub fn close(self: *Port) void {
        if (!self.is_open) return;
        switch (self.kind) {
            .file => |fk| {
                if (!fk.persistent) fk.file.close(fk.io);
            },
            else => {},
        }
        self.is_open = false;
    }

    /// Reads one line, without its terminating delimiter (LF, CRLF, or CR, per
    /// R7RS). Returns null only at end of input: a blank line yields an empty
    /// string, and a line of any length is returned whole.
    pub fn readLine(self: *Port, allocator: std.mem.Allocator) !?[]const u8 {
        if (!self.is_input or !self.is_open) return null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var saw_input = false;

        while (true) {
            const c_opt = try self.readChar();
            if (c_opt == null) {
                if (!saw_input) return null; // end of input before any character
                break;
            }
            saw_input = true;
            const c = c_opt.?;
            if (c == '\n') break;
            if (c == '\r') {
                if (try self.peekChar()) |next| {
                    if (next == '\n') _ = try self.readChar();
                }
                break;
            }
            try out.append(allocator, c);
        }

        return try out.toOwnedSlice(allocator);
    }

    /// Number of bytes peeked but not yet consumed.
    pub fn pendingBytes(self: *const Port) usize {
        return self.pushback_len - self.pushback_pos;
    }

    /// Discards any peeked bytes.
    pub fn clearPushback(self: *Port) void {
        self.pushback_len = 0;
        self.pushback_pos = 0;
    }

    fn unreadBytes(self: *Port, bytes: []const u8) void {
        // Only called when the pushback buffer has been fully consumed.
        @memcpy(self.pushback[0..bytes.len], bytes);
        self.pushback_len = @intCast(bytes.len);
        self.pushback_pos = 0;
    }

    fn readRawByte(self: *Port) !?u8 {
        switch (self.kind) {
            .file => |fk| {
                var buf: [1]u8 = undefined;
                const n = fk.file.readStreaming(fk.io, &.{&buf}) catch return null;
                if (n == 0) return null;
                return buf[0];
            },
            .string_input => |*sk| {
                if (sk.pos >= sk.source.len) return null;
                const c = sk.source[sk.pos];
                sk.pos += 1;
                return c;
            },
            .string_output => return null,
        }
    }

    pub fn readChar(self: *Port) !?u8 {
        if (!self.is_input or !self.is_open) return null;
        if (self.pushback_pos < self.pushback_len) {
            const c = self.pushback[self.pushback_pos];
            self.pushback_pos += 1;
            if (self.pushback_pos == self.pushback_len) self.clearPushback();
            return c;
        }
        return self.readRawByte();
    }

    pub fn peekChar(self: *Port) !?u8 {
        if (!self.is_input or !self.is_open) return null;
        if (self.pushback_pos < self.pushback_len) return self.pushback[self.pushback_pos];
        const c = (try self.readRawByte()) orelse return null;
        self.unreadBytes(&.{c});
        return c;
    }

    /// Reads one UTF-8 encoded character. Invalid sequences yield the
    /// replacement character so a text port never returns half a character.
    pub fn readCodepoint(self: *Port) !?u32 {
        const first = (try self.readChar()) orelse return null;
        const len = std.unicode.utf8ByteSequenceLength(first) catch return 0xFFFD;
        if (len == 1) return first;
        var buf: [4]u8 = undefined;
        buf[0] = first;
        var i: usize = 1;
        while (i < len) : (i += 1) {
            buf[i] = (try self.readChar()) orelse return 0xFFFD;
        }
        return std.unicode.utf8Decode(buf[0..len]) catch 0xFFFD;
    }

    /// Returns the next character without consuming it.
    pub fn peekCodepoint(self: *Port) !?u32 {
        if (!self.is_input or !self.is_open) return null;
        var buf: [4]u8 = undefined;
        var n: usize = 0;
        const first = (try self.readChar()) orelse return null;
        buf[0] = first;
        n = 1;
        const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
        while (n < len) : (n += 1) {
            const c = (try self.readChar()) orelse break;
            buf[n] = c;
        }
        self.unreadBytes(buf[0..n]);
        if (n != len) return 0xFFFD;
        return std.unicode.utf8Decode(buf[0..n]) catch 0xFFFD;
    }

    pub fn writeString(self: *Port, str: []const u8) !void {
        if (self.is_input or !self.is_open) return error.InvalidPort;
        switch (self.kind) {
            .file => |fk| try fk.file.writeStreamingAll(fk.io, str),
            .string_output => |*sk| try sk.buffer.appendSlice(sk.allocator, str),
            .string_input => return error.InvalidPort,
        }
    }
};

/// A mutable string. `bytes` holds UTF-8 and is replaced wholesale when an
/// in-place edit changes the encoded length.
pub const MString = struct {
    bytes: []u8,
};

/// Wraps `bytes` (already owned by `allocator`) as a string value.
pub fn makeString(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Value {
    const s = allocator.create(MString) catch return error.OutOfMemory;
    s.* = .{ .bytes = @constCast(bytes) };
    return Value{ .string = s };
}

/// Copies `bytes` into a fresh string value.
pub fn copyString(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Value {
    const owned = allocator.dupe(u8, bytes) catch return error.OutOfMemory;
    return makeString(allocator, owned);
}

/// Represents zero or more return values produced by `values`. A continuation expecting
/// a single value but receiving a `MultiValues` is an error in standard Scheme.
pub const MultiValues = struct {
    items: []Value,
};

/// Represents a delayed (lazy) computation. A promise is created by `delay` and forced
/// by `force`. The result is memoized after the first force.
pub const Promise = struct {
    /// The thunk expression to evaluate. Unused once the promise is forced.
    expr: Value,
    /// The environment captured at `delay` time.
    env: *Environment,
    /// True once the promise has been forced and `result` is populated.
    forced: bool,
    /// The cached result, valid only when `forced` is true.
    result: Value,
    /// True for promises made by `delay-force`: a promise-valued result is
    /// forced in turn rather than being the value.
    is_delay_force: bool = false,
    /// Set when another promise adopted this one's computation; forcing this
    /// promise then forces that one.
    forward: ?*Promise = null,
};

/// The Scheme-facing name of a value's type, for error messages such as
/// "car: expected a pair, got string".
pub fn typeName(v: Value) []const u8 {
    return switch (v) {
        .nil => "the empty list",
        .pair => "a pair",
        .boolean => "a boolean",
        .number => "an inexact number",
        .exact_integer, .bigint => "an integer",
        .string => "a string",
        .symbol => "a symbol",
        .character => "a character",
        .vector => "a vector",
        .bytevector => "a bytevector",
        .hash_map => "a hash map",
        .port => "a port",
        .promise => "a promise",
        .record => "a record",
        .record_type => "a record type",
        .procedure, .vm_closure, .foreign_procedure => "a procedure",
        .continuation, .escape => "a continuation",
        .macro, .syntax_rules => "a macro",
        .module => "a module",
        .multi_values => "multiple values",
        .eof => "the end-of-file object",
        .unspecified => "an unspecified value",
        else => @tagName(v),
    };
}

/// `Value` is the core data type in the Elz interpreter.
/// It is a tagged union that can represent all the different types of values in the Elz language.
pub const Value = union(enum) {
    /// An Element 0 symbol.
    symbol: []const u8,
    /// A floating-point number (inexact real).
    number: f64,
    /// An exact integer that fits in 64 bits.
    exact_integer: i64,
    /// An exact integer outside the i64 range (see bigint.zig).
    bigint: *BigInt,
    /// An exact rational number (heap-allocated, GCD-reduced).
    rational: *Rational,
    /// A complex number with inexact real and imaginary parts.
    complex: *Complex,
    /// A pair, the building block of lists.
    pair: *Pair,
    /// A single character.
    character: u32,
    /// A string of characters. Strings are heap objects so that aliases share
    /// one buffer and `string-set!` can change a character's byte width.
    string: *MString,
    /// A boolean value (`#t` or `#f`).
    boolean: bool,
    /// A VM-compiled closure (bytecode + upvalues).
    vm_closure: *VmClosure,
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
    /// A delayed computation produced by `delay`.
    promise: *Promise,
    /// Zero or more return values produced by `values`.
    multi_values: *MultiValues,
    /// A `syntax-rules` based macro transformer.
    syntax_rules: *SyntaxRulesMacro,
    /// A bytevector (mutable fixed-size byte array).
    bytevector: *Bytevector,
    /// A delimited continuation captured by shift.
    continuation: *Continuation,
    /// An escape continuation created by `call/ec` or `call/cc`.
    escape: *Escape,
    /// A record type descriptor created by define-record-type.
    record_type: *RecordType,
    /// A record instance.
    record: *Record,
    /// The `nil` or empty list value.
    nil,
    /// An unspecified or void value.
    unspecified,
    /// The end-of-file object returned by the read procedures.
    eof,

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

    /// Returns the numeric value as f64 if this is a real numeric type, or null
    /// otherwise. A complex number has no single real value, so callers that
    /// only handle reals reject it instead of silently using the real part.
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .number => |n| n,
            .exact_integer => |n| @floatFromInt(n),
            .bigint => |b| @import("bigint.zig").toF64(b),
            .rational => |r| @as(f64, @floatFromInt(r.numerator)) / @as(f64, @floatFromInt(r.denominator)),
            else => null,
        };
    }

    /// Returns true if this value is any numeric type.
    pub fn isNumeric(self: Value) bool {
        return self == .number or self == .exact_integer or self == .bigint or self == .rational or self == .complex;
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
            .number, .exact_integer, .bigint, .boolean, .character, .vm_closure, .macro, .procedure, .foreign_procedure, .opaque_pointer, .cell, .module, .promise, .multi_values, .syntax_rules, .bytevector, .continuation, .escape, .record_type, .record, .nil, .unspecified, .eof => self,
            .rational => |r| blk: {
                const new_r = try allocator.create(Rational);
                new_r.* = r.*;
                break :blk Value{ .rational = new_r };
            },
            .complex => |c| blk: {
                const new_c = try allocator.create(Complex);
                new_c.* = c.*;
                break :blk Value{ .complex = new_c };
            },
            .string => |s| try copyString(allocator, s.bytes),
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
            .int => Value{ .exact_integer = @intCast(v) },
            .bool => Value{ .boolean = v },
            .pointer => |p| switch (p.size) {
                .slice => blk: {
                    const s = try allocator.dupe(u8, v);
                    break :blk (try makeString(allocator, s));
                },
                else => @compileError("Unsupported pointer type"),
            },
            else => @compileError("Unsupported from type"),
        };
    }
};

test "core environment" {
    // Element 0 environments and values allocate their backing storage from the
    // interpreter's GC allocator in production. Inside this unit test we use an arena
    // backed by `std.testing.allocator` so every allocation is freed by `arena.deinit()`
    // without having to traverse the environment's binding map and free each entry by
    // hand.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing = std.testing;

    // Test set and get in the same environment
    var env = try Environment.init(allocator, null);
    try env.set("x", Value{ .number = 42 });
    var value = try env.get("x");
    try testing.expect(value == .number);
    try testing.expectEqual(@as(f64, 42), value.number);

    // Test get from outer environment
    var outer_env = try Environment.init(allocator, null);
    try outer_env.set("y", (try makeString(allocator, "hello")));
    var inner_env = try Environment.init(allocator, outer_env);
    value = try inner_env.get("y");
    try testing.expectEqualStrings("hello", value.string.bytes);

    // Test update on outer environment
    try inner_env.update("y", (try makeString(allocator, "world")));
    value = try outer_env.get("y");
    try testing.expectEqualStrings("world", value.string.bytes);

    // Test update on symbol not found
    const err = inner_env.update("z", Value{ .number = 0 });
    try testing.expectError(ElzError.SymbolNotFound, err);
}
