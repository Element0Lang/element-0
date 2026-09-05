/// Elz bytecode compiler: AST Value → FuncProto
///
/// Transforms parsed Elz S-expressions into bytecode chunks that can be
/// executed by vm.zig.  The compiler handles all special forms, tail-call
/// detection, lexical closures with upvalue capture, and compile-time macro
/// expansion.
const std = @import("std");
const core = @import("core.zig");
const chunk = @import("chunk.zig");
// macros_mod is imported for compile-time macro expansion: define-macro and define-syntax
// transformers must be evaluated (not just compiled) so their output can be used
// immediately by the rest of the compilation pass.
const macros_mod = @import("macros.zig");
const parser = @import("parser.zig");
const Value = core.Value;
const ElzError = core.ElzError;
const FuncProto = chunk.FuncProto;
const Instruction = chunk.Instruction;
const OpCode = chunk.OpCode;
const UpvalDesc = chunk.UpvalDesc;

// ---------------------------------------------------------------------------
// Scope / local variable tracking
// ---------------------------------------------------------------------------

/// Deepest expression nesting the compiler accepts.
const MAX_COMPILE_DEPTH: u32 = 1000;

const Local = struct {
    name: []const u8,
    slot: u8,
    depth: usize,
    is_captured: bool = false,
};

const Scope = struct {
    locals: std.ArrayList(Local),
    upval_descs: std.ArrayList(UpvalDesc),
    depth: usize,
    parent: ?*Scope,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{
            .locals = .empty,
            .upval_descs = .empty,
            .depth = if (parent) |p| p.depth + 1 else 0,
            .parent = parent,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Scope) void {
        self.locals.deinit(self.allocator);
        self.upval_descs.deinit(self.allocator);
    }

    /// Allocate a new local slot in this scope. Returns the slot index.
    /// Slot indices are one byte wide, so a frame holds at most 255 locals.
    fn addLocal(self: *Scope, name: []const u8) !u8 {
        if (self.locals.items.len >= std.math.maxInt(u8)) return ElzError.TooManyLocals;
        const slot: u8 = @intCast(self.locals.items.len);
        try self.locals.append(self.allocator, .{ .name = name, .slot = slot, .depth = self.depth });
        return slot;
    }

    /// Look up a local in *this* scope only. Returns null if not found.
    fn findLocal(self: *const Scope, name: []const u8) ?u8 {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name))
                return self.locals.items[i].slot;
        }
        return null;
    }

    /// Add an upvalue descriptor and return its index. Upvalue indices are one
    /// byte wide, so a closure captures at most 255 variables.
    fn addUpval(self: *Scope, desc: UpvalDesc) !u8 {
        for (self.upval_descs.items, 0..) |existing, i| {
            if (existing.is_local == desc.is_local and existing.index == desc.index)
                return @intCast(i);
        }
        if (self.upval_descs.items.len >= std.math.maxInt(u8)) return ElzError.TooManyLocals;
        const idx: u8 = @intCast(self.upval_descs.items.len);
        try self.upval_descs.append(self.allocator, desc);
        return idx;
    }
};

// ---------------------------------------------------------------------------
// Variable resolution result
// ---------------------------------------------------------------------------

const VarLoc = union(enum) {
    local: u8,
    upval: u8,
    global,
};

// ---------------------------------------------------------------------------
// Compiler context
// ---------------------------------------------------------------------------

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    /// The prototype being built for the current function.
    proto: *FuncProto,
    /// Scope stack for the current function.
    scope: Scope,
    /// Pointer to the enclosing compiler (for nested lambdas).
    enclosing: ?*Compiler,
    /// Source location of the form currently being compiled (0 / "" unknown).
    current_line: u32 = 0,
    current_file: []const u8 = "",
    /// Interpreter reference for macro expansion.
    interp: *@import("interpreter.zig").Interpreter,
    /// Identity of this compiler scope, recorded by transformers defined in it.
    id: u64 = 0,
    /// Tracked stack depth: number of values currently on the runtime stack above
    /// frame.stack_base. Used to assign correct slot indices when allocating locals
    /// inside inline expressions. Incremented by every push-emitting instruction and
    /// decremented by every pop-emitting instruction.
    stack_depth: u8 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        interp: *@import("interpreter.zig").Interpreter,
        name: []const u8,
        enclosing: ?*Compiler,
    ) !Compiler {
        const proto = try allocator.create(FuncProto);
        proto.* = FuncProto.init(allocator, name);
        if (enclosing) |enc| proto.source_file = enc.current_file;
        interp.compiler_id_counter += 1;
        return .{
            .allocator = allocator,
            .proto = proto,
            .id = interp.compiler_id_counter,
            .current_line = if (enclosing) |enc| enc.current_line else 0,
            .current_file = if (enclosing) |enc| enc.current_file else "",
            .scope = Scope.init(allocator, null),
            .enclosing = enclosing,
            .interp = interp,
            .stack_depth = 0,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.scope.deinit();
        // proto ownership is transferred to the caller; don't free here
    }

    // -----------------------------------------------------------------------
    // Variable resolution (local → upvalue → global)
    // -----------------------------------------------------------------------

    fn resolveVar(self: *Compiler, name: []const u8) !VarLoc {
        if (self.scope.findLocal(name)) |slot| return .{ .local = slot };
        if (try self.resolveUpval(name)) |uv| return .{ .upval = uv };
        return .global;
    }

    fn resolveUpval(self: *Compiler, name: []const u8) !?u8 {
        const enc = self.enclosing orelse return null;
        // Check if it's a local in the immediately enclosing function.
        if (enc.scope.findLocal(name)) |slot| {
            // Mark that local as captured.
            for (enc.scope.locals.items) |*loc| {
                if (loc.slot == slot) loc.is_captured = true;
            }
            return try self.scope.addUpval(.{ .is_local = true, .index = slot });
        }
        // Recurse upward.
        if (try enc.resolveUpval(name)) |uv| {
            return try self.scope.addUpval(.{ .is_local = false, .index = uv });
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Emit helpers
    // -----------------------------------------------------------------------

    fn emit(self: *Compiler, instr: Instruction) !usize {
        const idx = try self.proto.emit(instr);
        try self.proto.lines.append(self.allocator, self.current_line);
        return idx;
    }

    fn emitOp(self: *Compiler, op: OpCode) !usize {
        return self.emit(Instruction.init_op(op));
    }

    fn emitA(self: *Compiler, op: OpCode, a: u8) !usize {
        return self.emit(Instruction.init_a(op, a));
    }

    fn emitBx(self: *Compiler, op: OpCode, bx: u16) !usize {
        return self.emit(Instruction.init_bx(op, bx));
    }

    fn emitJump(self: *Compiler, op: OpCode) !usize {
        return self.emit(Instruction.init_offset(op, 0));
    }

    fn patchJump(self: *Compiler, idx: usize) void {
        self.proto.patchJump(idx);
    }

    fn addConst(self: *Compiler, val: Value) !u16 {
        return self.proto.addConst(val);
    }

    // -----------------------------------------------------------------------
    // Shape checks for special forms
    //
    // The form-specific compilers below index their operand lists directly
    // (`args.pair.car` and friends). Without these checks a malformed form such
    // as `(define)` or `(let 1 2)` would index a union field that is not active
    // and abort the process, which an embedder cannot catch. Each check reports
    // a syntax error instead.
    // -----------------------------------------------------------------------

    /// Records a "malformed <name> form" message and returns a syntax error.
    fn badForm(self: *Compiler, name: []const u8) ElzError {
        self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "malformed {s} form", .{name}) catch null;
        return ElzError.InvalidArgument;
    }

    /// Requires `list` to be a proper list holding at least `min` elements.
    fn requireOperands(self: *Compiler, name: []const u8, list: Value, min: usize) ElzError!void {
        var n: usize = 0;
        var cur = list;
        while (cur == .pair) : (cur = cur.pair.cdr) n += 1;
        if (cur != .nil or n < min) return self.badForm(name);
    }

    /// Requires `v` to be a pair and returns it.
    fn requirePair(self: *Compiler, name: []const u8, v: Value) ElzError!*core.Pair {
        if (v != .pair) return self.badForm(name);
        return v.pair;
    }

    /// Requires `v` to be a symbol and returns its name.
    fn requireSymbol(self: *Compiler, name: []const u8, v: Value) ElzError![]const u8 {
        if (v != .symbol) return self.badForm(name);
        return v.symbol;
    }

    /// Requires a `(name init)` binding pair and returns both parts.
    fn requireBinding(self: *Compiler, name: []const u8, v: Value) ElzError!struct { name: Value, init: Value } {
        const p = try self.requirePair(name, v);
        const rest = try self.requirePair(name, p.cdr);
        if (rest.cdr != .nil) return self.badForm(name);
        if (p.car != .symbol) return self.badForm(name);
        return .{ .name = p.car, .init = rest.car };
    }

    // -----------------------------------------------------------------------
    // Macro expansion
    // -----------------------------------------------------------------------

    /// True when `head` names a local or upvalue, which takes precedence over
    /// any macro of the same name.
    fn macroShadowed(self: *Compiler, head: Value) !bool {
        if (head != .symbol) return false;
        return (try self.resolveVar(head.symbol)) != .global;
    }

    /// True when a `define` directly in `body` (or inside a `begin` there)
    /// binds `name`, so a same-named macro must not expand in that body.
    fn bodyDefines(self: *Compiler, body: Value, name: []const u8) bool {
        var cur = body;
        while (cur == .pair) : (cur = cur.pair.cdr) {
            const form = cur.pair.car;
            if (form != .pair or form.pair.car != .symbol) continue;
            const head = self.baseName(form.pair.car.symbol);
            if (std.mem.eql(u8, head, "begin")) {
                if (self.bodyDefines(form.pair.cdr, name)) return true;
                continue;
            }
            if (!std.mem.eql(u8, head, "define") or form.pair.cdr != .pair) continue;
            const target = form.pair.cdr.pair.car;
            const defined: ?[]const u8 = switch (target) {
                .symbol => |sym| sym,
                .pair => |tp| if (tp.car == .symbol) tp.car.symbol else null,
                else => null,
            };
            if (defined) |d| if (std.mem.eql(u8, d, name)) return true;
        }
        return false;
    }

    fn tryExpandMacro(self: *Compiler, head: Value, args: Value, env: *core.Environment, fuel: *u64) !?Value {
        if (head != .symbol) return null;
        const looked_up = env.lookup(head.symbol) orelse blk: {
            // A macro name renamed by hygiene refers to the macro itself.
            var name = head.symbol;
            while (macros_mod.hygieneBase(name)) |base| {
                name = base;
                if (env.lookup(name)) |v| break :blk v;
            }
            return null;
        };
        switch (looked_up) {
            .syntax_rules => |sr| {
                return try macros_mod.expandSyntaxRules(self.interp, sr, args, env, fuel);
            },
            .macro => |m| {
                return try macros_mod.expandMacro(self.interp, m, args, env, fuel);
            },
            else => return null,
        }
    }

    // -----------------------------------------------------------------------
    // Core compile entry point
    // -----------------------------------------------------------------------

    /// Compile one expression. `tail` is true when this expression is in tail
    /// position (may emit tail_call instead of call).
    pub fn compileExpr(self: *Compiler, expr: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // Nested forms compile recursively; bound the depth so hostile or
        // runaway (self-expanding macro) input reports an error instead of
        // exhausting the native stack.
        if (self.interp.compile_depth >= MAX_COMPILE_DEPTH) {
            self.interp.last_error_message = "expression nesting too deep to compile";
            return ElzError.InvalidArgument;
        }
        self.interp.compile_depth += 1;
        defer self.interp.compile_depth -= 1;
        if (expr == .pair) {
            if (self.interp.source_locations.get(@intFromPtr(expr.pair))) |loc| {
                self.current_line = loc.line;
                self.current_file = loc.file;
                if (self.proto.source_file.len == 0) self.proto.source_file = loc.file;
            }
        }
        switch (expr) {
            // --- Self-evaluating atoms ---
            .nil => _ = try self.emitOp(.load_nil),
            .boolean => |b| _ = try self.emitOp(if (b) .load_true else .load_false),
            .unspecified => _ = try self.emitOp(.load_unspecified),
            .number, .exact_integer, .rational, .complex, .string, .character => {
                const ci = try self.addConst(expr);
                _ = try self.emitBx(.load_const, ci);
            },
            .symbol => |name| {
                try self.compileVarLoad(name);
            },
            .pair => |p| {
                const head = p.car;
                const args = p.cdr;
                try self.compileForm(head, args, env, tail, fuel);
            },
            // Vectors and other literals as constants
            .vector => {
                const ci = try self.addConst(expr);
                _ = try self.emitBx(.load_const, ci);
            },
            else => {
                const ci = try self.addConst(expr);
                _ = try self.emitBx(.load_const, ci);
            },
        }
    }

    // -----------------------------------------------------------------------
    // Hygiene: identifiers introduced by syntax-rules templates
    //
    // An introduced identifier is an alias (`name__hN`) registered in
    // `interp.hygiene_aliases` with the scope its macro was defined in. It is
    // resolved as its base name *from that scope*, so a binding at the use
    // site cannot capture it, and a keyword such as `if` or `else` keeps its
    // meaning even when the use site rebinds that name.
    // -----------------------------------------------------------------------

    fn aliasOf(self: *Compiler, name: []const u8) ?@import("interpreter.zig").HygieneAlias {
        return self.interp.hygiene_aliases.get(name);
    }

    /// The compiler with identity `id` among this one and its enclosing ones.
    fn findScope(self: *Compiler, id: u64) ?*Compiler {
        var cur: ?*Compiler = self;
        while (cur) |c| : (cur = c.enclosing) {
            if (c.id == id) return c;
        }
        return null;
    }

    /// Reports whether `name` is lexically bound as seen from compiler `c`,
    /// without recording any capture.
    fn boundFrom(c: *Compiler, name: []const u8) bool {
        var cur: ?*Compiler = c;
        while (cur) |k| : (cur = k.enclosing) {
            if (k.scope.findLocal(name) != null) return true;
        }
        return false;
    }

    /// Resolves `name` as seen from the enclosing compiler `target`, threading
    /// upvalue captures through every compiler in between.
    fn resolveFrom(self: *Compiler, target: *Compiler, name: []const u8) ElzError!VarLoc {
        if (self == target) return self.resolveVar(name);
        const enc = self.enclosing orelse return .global;
        const loc = try enc.resolveFrom(target, name);
        switch (loc) {
            .local => |slot| {
                for (enc.scope.locals.items) |*l| {
                    if (l.slot == slot) l.is_captured = true;
                }
                return .{ .upval = try self.scope.addUpval(.{ .is_local = true, .index = slot }) };
            },
            .upval => |idx| return .{ .upval = try self.scope.addUpval(.{ .is_local = false, .index = idx }) },
            .global => return .global,
        }
    }

    /// Resolves a variable. An alias that is not itself lexically bound
    /// resolves as its base name from the macro's definition scope; when that
    /// scope is not enclosing (a global macro), it is a global, and the VM
    /// falls back from the alias to the base name at run time.
    fn resolveVarWithFallback(self: *Compiler, name: []const u8) ElzError!VarLoc {
        const loc = try self.resolveVar(name);
        if (loc != .global) return loc;
        const alias = self.aliasOf(name) orelse return loc;
        if (self.findScope(alias.def_scope_id)) |def| {
            const from_def = try self.resolveFrom(def, alias.base);
            if (from_def != .global) return from_def;
        }
        // The base may itself be an alias (a macro-defining macro): resolve
        // it in turn. Otherwise it is a global the VM finds by base name.
        if (self.aliasOf(alias.base) != null) return self.resolveVarWithFallback(alias.base);
        return .global;
    }

    /// The keyword a head symbol denotes: its own name, or for an alias the
    /// base name when that is not lexically bound at the definition scope.
    /// Null when the symbol is a lexically bound variable.
    fn keywordName(self: *Compiler, sym: []const u8) ElzError!?[]const u8 {
        if ((try self.resolveVar(sym)) != .global) return null;
        if (self.aliasOf(sym)) |alias| {
            if (self.findScope(alias.def_scope_id)) |def| {
                if (boundFrom(def, alias.base)) return null;
            }
            // An alias of an alias: keep unwrapping.
            if (self.aliasOf(alias.base) != null) return self.keywordName(alias.base);
            return alias.base;
        }
        return sym;
    }

    /// True when `v` denotes the syntactic keyword `kw`.
    fn isKeyword(self: *Compiler, v: Value, comptime kw: []const u8) ElzError!bool {
        if (v != .symbol) return false;
        const k = (try self.keywordName(v.symbol)) orelse return false;
        return std.mem.eql(u8, k, kw);
    }

    /// The base name of an alias, or the symbol itself: for syntactic scans
    /// that run before scopes are known.
    fn baseName(self: *Compiler, sym: []const u8) []const u8 {
        var name = sym;
        while (self.aliasOf(name)) |alias| name = alias.base;
        return name;
    }

    fn compileVarLoad(self: *Compiler, name: []const u8) ElzError!void {
        const loc = try self.resolveVarWithFallback(name);
        switch (loc) {
            .local => |slot| _ = try self.emitA(.load_local, slot),
            .upval => |uv| _ = try self.emitA(.load_upval, uv),
            .global => {
                const ci = try self.addConst(Value{ .symbol = name });
                _ = try self.emitBx(.load_global, ci);
            },
        }
    }

    fn compileVarStore(self: *Compiler, name: []const u8) ElzError!void {
        const loc = try self.resolveVarWithFallback(name);
        switch (loc) {
            .local => |slot| _ = try self.emitA(.store_local, slot),
            .upval => |uv| _ = try self.emitA(.store_upval, uv),
            .global => {
                const ci = try self.addConst(Value{ .symbol = name });
                _ = try self.emitBx(.store_global, ci);
            },
        }
    }

    // -----------------------------------------------------------------------
    // Special-form and application dispatch
    // -----------------------------------------------------------------------

    fn compileForm(self: *Compiler, head: Value, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // Try macro expansion first (compile-time), unless a lexical binding
        // shadows the macro name.
        if (try self.macroShadowed(head)) {
            return self.compileCall(head, args, env, tail, fuel);
        }
        if (try self.tryExpandMacro(head, args, env, fuel)) |expanded| {
            return self.compileExpr(expanded, env, tail, fuel);
        }

        if (head != .symbol) {
            // (expr args...) — eval head then args
            return self.compileCall(head, args, env, tail, fuel);
        }

        // A lexically bound name shadows any special form of the same name,
        // e.g. (let ((if list)) (if 1 2 3)) calls the variable. A hygiene
        // alias dispatches on the keyword it stands for.
        const sym = (try self.keywordName(head.symbol)) orelse {
            return self.compileCall(head, args, env, tail, fuel);
        };

        // Validate the operand list's shape once, before dispatch.
        if (minOperands(sym)) |min| try self.requireOperands(sym, args, min);

        if (std.mem.eql(u8, sym, "quote")) return self.compileQuote(args);
        if (std.mem.eql(u8, sym, "quasiquote")) return self.compileQuasiquote(args.pair.car, env, fuel);
        if (std.mem.eql(u8, sym, "if")) return self.compileIf(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "begin")) return self.compileBegin(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "define")) return self.compileDefine(args, env, fuel);
        if (std.mem.eql(u8, sym, "define-macro")) return self.compileDefineMacro(args, env, fuel);
        if (std.mem.eql(u8, sym, "define-syntax")) return self.compileDefineSyntax(args, env, fuel);
        if (std.mem.eql(u8, sym, "set!")) return self.compileSet(args, env, fuel);
        if (std.mem.eql(u8, sym, "lambda")) return self.compileLambda(args, env, fuel);
        if (std.mem.eql(u8, sym, "let")) return self.compileLet(args, env, tail, false, fuel);
        if (std.mem.eql(u8, sym, "let*")) return self.compileLet(args, env, tail, true, fuel);
        if (std.mem.eql(u8, sym, "letrec")) return self.compileLetrec(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "letrec*")) return self.compileLetrec(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "and")) return self.compileAnd(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "or")) return self.compileOr(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "cond")) return self.compileCond(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "case")) return self.compileCase(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "when")) return self.compileWhen(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "unless")) return self.compileUnless(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "do")) return self.compileDo(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "delay")) return self.compileDelay(args, env, fuel);
        if (std.mem.eql(u8, sym, "let-syntax")) return self.compileLetSyntax(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "letrec-syntax")) return self.compileLetSyntax(args, env, tail, fuel);
        if (std.mem.eql(u8, sym, "syntax-rules")) return self.compileSyntaxRules(head, args, env);
        if (std.mem.eql(u8, sym, "reset")) return self.compileReset(args, env, fuel);
        if (std.mem.eql(u8, sym, "shift")) return self.compileShift(args, env, fuel);
        if (std.mem.eql(u8, sym, "include")) return self.compileInclude(args, env, tail, false, fuel);
        if (std.mem.eql(u8, sym, "include-ci")) return self.compileInclude(args, env, tail, true, fuel);
        if (std.mem.eql(u8, sym, "syntax-error")) {
            if (args == .pair and args.pair.car == .string) {
                self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "syntax-error: {s}", .{args.pair.car.string.bytes}) catch null;
            } else {
                self.interp.last_error_message = "syntax-error";
            }
            return ElzError.InvalidArgument;
        }
        if (std.mem.eql(u8, sym, "import")) return self.compileImport(args, env);
        if (std.mem.eql(u8, sym, "define-library")) return self.compileDefineLibrary(args, env, fuel);
        if (std.mem.eql(u8, sym, "try")) return self.compileTry(args, env, tail, fuel);

        // Not a special form — regular function call.
        return self.compileCall(head, args, env, tail, fuel);
    }

    // -----------------------------------------------------------------------
    // quote
    // -----------------------------------------------------------------------

    fn compileQuote(self: *Compiler, args: Value) ElzError!void {
        const val = args.pair.car;
        const ci = try self.addConst(val);
        _ = try self.emitBx(.load_const, ci);
    }

    // -----------------------------------------------------------------------
    // quasiquote
    // -----------------------------------------------------------------------

    fn compileQuasiquote(self: *Compiler, expr: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        try self.compileQQ(expr, env, 1, fuel);
    }

    fn compileQQ(self: *Compiler, expr: Value, env: *core.Environment, level: usize, fuel: *u64) ElzError!void {
        switch (expr) {
            .pair => |p| {
                // Check whether unquote/unquote-splicing are locally bound (in which case they
                // lose their special meaning inside quasiquote per R7RS §4.2.8).
                const unquote_is_global = try self.isKeyword(p.car, "unquote");
                const unquote_splice_is_global = try self.isKeyword(p.car, "unquote-splicing");
                // (unquote x) at level 1 → compile x
                if (level == 1 and unquote_is_global) {
                    const operand = try self.requirePair("unquote", p.cdr);
                    return self.compileExpr(operand.car, env, false, fuel);
                }
                // (unquote x) at level > 1 → produce (unquote (qq-expand x level-1))
                if (level > 1 and unquote_is_global) {
                    const operand = try self.requirePair("unquote", p.cdr);
                    const ci = try self.addConst(Value{ .symbol = "unquote" });
                    _ = try self.emitBx(.load_const, ci);
                    try self.compileQQ(operand.car, env, level - 1, fuel);
                    _ = try self.emitA(.make_list, 1);
                    _ = try self.emitOp(.cons);
                    return;
                }
                // (unquote-splicing x) at level > 1 → produce (unquote-splicing (qq-expand x level-1))
                if (level > 1 and unquote_splice_is_global) {
                    const operand = try self.requirePair("unquote-splicing", p.cdr);
                    const ci = try self.addConst(Value{ .symbol = "unquote-splicing" });
                    _ = try self.emitBx(.load_const, ci);
                    try self.compileQQ(operand.car, env, level - 1, fuel);
                    _ = try self.emitA(.make_list, 1);
                    _ = try self.emitOp(.cons);
                    return;
                }
                // (quasiquote x) — increase level
                if (try self.isKeyword(p.car, "quasiquote") and p.cdr == .pair) {
                    // Wrap in (quasiquote ...)
                    const ci = try self.addConst(Value{ .symbol = "quasiquote" });
                    _ = try self.emitBx(.load_const, ci);
                    try self.compileQQ(p.cdr.pair.car, env, level + 1, fuel);
                    _ = try self.emitA(.make_list, 1);
                    _ = try self.emitOp(.cons);
                    return;
                }

                // General pair: build as list with possible splicing
                try self.compileQQList(expr, env, level, fuel);
            },
            .vector => |v| {
                // Build the elements as a quasiquoted list, so unquote-splicing
                // inside a vector works, then convert.
                var as_list: Value = .nil;
                var i = v.items.len;
                while (i > 0) {
                    i -= 1;
                    as_list = try makePair(self.allocator, v.items[i], as_list);
                }
                try self.compileQQList(as_list, env, level, fuel);
                _ = try self.emitOp(.list_to_vector);
            },
            else => {
                const ci = try self.addConst(expr);
                _ = try self.emitBx(.load_const, ci);
            },
        }
    }

    fn compileQQList(self: *Compiler, list: Value, env: *core.Environment, level: usize, fuel: *u64) ElzError!void {
        // Collect segments: each segment is either a splice or a cons element
        // We build this by recursing and using cons/append_lists
        if (list == .nil) {
            _ = try self.emitOp(.load_nil);
            return;
        }
        if (list != .pair) {
            // Improper list tail
            return self.compileQQ(list, env, level, fuel);
        }
        const p = list.pair;
        const car = p.car;
        // `(a . ,x)` reads as `(a unquote x)`: an unquote form in tail position
        // is the tail itself, not two more elements.
        if (try self.isKeyword(car, "unquote") and p.cdr == .pair and p.cdr.pair.cdr == .nil) {
            return self.compileQQ(list, env, level, fuel);
        }
        // Check for (unquote-splicing x) at level 1 — splice (only when unquote-splicing is global)
        const splice_is_global = car == .pair and car.pair.cdr == .pair and try self.isKeyword(car.pair.car, "unquote-splicing");
        if (level == 1 and splice_is_global) {
            // Splice: evaluate the spliced list, then append to rest
            try self.compileExpr(car.pair.cdr.pair.car, env, false, fuel);
            try self.compileQQList(p.cdr, env, level, fuel);
            _ = try self.emitOp(.append_lists);
        } else {
            // Regular element: compile car as QQ, compile rest, cons
            try self.compileQQ(car, env, level, fuel);
            try self.compileQQList(p.cdr, env, level, fuel);
            _ = try self.emitOp(.cons);
        }
    }

    // -----------------------------------------------------------------------
    // if
    // -----------------------------------------------------------------------

    fn compileIf(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        if (args != .pair or args.pair.cdr != .pair) return ElzError.IfInvalidArguments;
        const test_expr = args.pair.car;
        const then_expr = args.pair.cdr.pair.car;
        const has_else = args.pair.cdr.pair.cdr == .pair;
        const else_expr: Value = if (has_else) args.pair.cdr.pair.cdr.pair.car else .unspecified;

        try self.compileExpr(test_expr, env, false, fuel);
        const jif = try self.emitJump(.jump_if_false);

        try self.compileExpr(then_expr, env, tail, fuel);
        const jmp = try self.emitJump(.jump);

        self.patchJump(jif);
        try self.compileExpr(else_expr, env, tail, fuel);
        self.patchJump(jmp);
    }

    // -----------------------------------------------------------------------
    // begin
    // -----------------------------------------------------------------------

    fn compileBegin(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        if (args == .nil) {
            _ = try self.emitOp(.load_unspecified);
            return;
        }
        var cur = args;
        while (cur == .pair) {
            const p = cur.pair;
            const is_last = p.cdr == .nil;
            try self.compileExpr(p.car, env, tail and is_last, fuel);
            if (!is_last) _ = try self.emitOp(.pop);
            cur = p.cdr;
        }
        if (cur != .nil) return self.badForm("begin");
    }

    // -----------------------------------------------------------------------
    // define
    // -----------------------------------------------------------------------

    fn compileDefine(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        const ap = try self.requirePair("define", args);
        const target = ap.car;
        const rest = ap.cdr;

        if (target == .symbol) {
            // (define name expr)
            const name = target.symbol;
            const val_expr: Value = if (rest != .nil) rest.pair.car else .unspecified;
            try self.compileExpr(val_expr, env, false, fuel);
            try self.emitDefineOrStore(name);
        } else if (target == .pair) {
            // (define (f params...) body...)
            const name = try self.requireSymbol("define", target.pair.car);
            const params = target.pair.cdr;
            // Build a lambda form and compile it
            const lambda_args = try makePair(self.allocator, params, rest);
            try self.compileLambdaWithName(lambda_args, name, env, fuel);
            try self.emitDefineOrStore(name);
        } else {
            return ElzError.InvalidArgument;
        }
    }

    fn emitDefineOrStore(self: *Compiler, name: []const u8) ElzError!void {
        // At top-level (no enclosing function scope), use define_global.
        // Inside a function, allocate a local slot.
        if (self.enclosing == null and self.scope.locals.items.len == 0 and self.scope.depth == 0) {
            // Top-level
            const ci = try self.addConst(Value{ .symbol = name });
            _ = try self.emitBx(.define_global, ci);
        } else {
            // Local define inside a function body. The body scan hoisted every
            // definition, so a name without a slot sits in expression context
            // (inside `when`, `if`, a `do` result, ...), where a definition is
            // a syntax error: allocating a slot here would alias stack
            // temporaries.
            if (self.scope.findLocal(name)) |slot| {
                _ = try self.emitA(.store_local, slot);
            } else {
                self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "define: '{s}' is not at the start of a body", .{name}) catch null;
                return ElzError.InvalidArgument;
            }
        }
    }

    // -----------------------------------------------------------------------
    // try / catch
    // -----------------------------------------------------------------------

    // Compiles (try body... (catch err handler...)) into a call to %%try%%, an
    // internal primitive that runs the body thunk and on error calls the handler
    // thunk with the error message bound to the catch variable.
    fn compileTry(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // Parse into body forms and catch clause.
        var body_list: Value = .nil; // reversed; we'll build it forward
        var body_tail: Value = .nil;
        var catch_clause: ?Value = null;
        var cur = args;
        while (cur == .pair) {
            const form = cur.pair.car;
            if (form == .pair and try self.isKeyword(form.pair.car, "catch")) {
                catch_clause = form;
                break;
            }
            // Append form to body list.
            const node = try self.allocator.create(core.Pair);
            node.* = .{ .car = form, .cdr = .nil };
            if (body_list == .nil) {
                body_list = Value{ .pair = node };
                body_tail = body_list;
            } else {
                body_tail.pair.cdr = Value{ .pair = node };
                body_tail = body_tail.pair.cdr;
            }
            cur = cur.pair.cdr;
        }
        if (catch_clause == null) return self.badForm("try");
        const catch_rest = try self.requirePair("catch", catch_clause.?.pair.cdr); // (err handler...)
        const err_sym = catch_rest.car;
        if (err_sym != .symbol) return self.badForm("catch");
        const handler_body = catch_rest.cdr;

        // Emit: (%%try%% body-thunk handler-thunk)
        // body-thunk  = (lambda () body...)
        // handler-thunk = (lambda (err) handler...)
        const try_sym_ci = try self.addConst(Value{ .symbol = "%%try%%" });
        _ = try self.emitBx(.load_global, try_sym_ci);

        // Build and compile body thunk: (lambda () body_list...)
        try self.compileLambdaArgs(.nil, body_list, env, fuel);
        // Build and compile handler thunk: (lambda (err) handler_body...)
        const err_param_pair = try self.allocator.create(core.Pair);
        err_param_pair.* = .{ .car = err_sym, .cdr = .nil };
        try self.compileLambdaArgs(Value{ .pair = err_param_pair }, handler_body, env, fuel);

        // The thunks may capture locals of this frame as open upvalues. Those
        // point directly into this VM's stack, which stays valid while the
        // nested VM runs the thunks, so the upvalues must stay open: closing
        // them here would detach the thunks' view of a local from the frame's.
        if (tail) {
            _ = try self.emitA(.tail_call, 2);
        } else {
            _ = try self.emitA(.call, 2);
        }
    }

    // Compile a lambda given its param list and body list directly (no wrapping pair needed).
    fn compileLambdaArgs(self: *Compiler, params: Value, body: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        // Build (lambda params body...) as a Value and compile it.
        const params_body_pair = try self.allocator.create(core.Pair);
        params_body_pair.* = .{ .car = params, .cdr = body };
        try self.compileLambdaWithName(Value{ .pair = params_body_pair }, "<try-thunk>", env, fuel);
    }

    // -----------------------------------------------------------------------
    // Helper: evaluate a transformer expression at compile time.
    // If `expr` is a `(syntax-rules ...)` form, parse it directly using
    // macros_mod.buildSyntaxRules so we never re-enter the compiler (which
    // would create an infinite loop). For any other expression, delegate to
    // interp.evalForm as before.
    // -----------------------------------------------------------------------

    fn evalTransformer(self: *Compiler, expr: Value, name: []const u8, env: *core.Environment) ElzError!Value {
        if (expr == .pair and expr.pair.car == .symbol and std.mem.eql(u8, self.baseName(expr.pair.car.symbol), "syntax-rules")) {
            const ellipsis_bound = switch (try self.resolveVar("...")) {
                .global => false,
                else => true,
            };
            const sr = try macros_mod.buildSyntaxRules(env, name, expr.pair.cdr, ellipsis_bound);
            sr.def_scope_id = self.id;
            return Value{ .syntax_rules = sr };
        }
        var f: u64 = 1_000_000;
        return self.interp.evalForm(&expr, &f);
    }

    // -----------------------------------------------------------------------
    // define-macro / define-syntax
    // -----------------------------------------------------------------------

    fn compileDefineMacro(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        // Two supported forms:
        //   (define-macro name transformer-expr)  -- transformer is a lambda value
        //   (define-macro (name params...) body)  -- shorthand, creates a core.Macro directly
        _ = fuel;
        const first = args.pair.car;
        const transformer: core.Value = blk: {
            if (first == .symbol) {
                // Long form: evaluate the transformer expression.
                const rest = try self.requirePair("define-macro", args.pair.cdr);
                const transformer_expr = rest.car;
                break :blk try evalTransformer(self, transformer_expr, first.symbol, env);
            } else if (first == .pair) {
                // Shorthand: (define-macro (name params...) body)
                const sig = first.pair;
                const macro_name = try self.requireSymbol("define-macro", sig.car);
                // Validate the formals: symbols in a proper or dotted list, or a bare rest symbol.
                var cur = sig.cdr;
                while (cur == .pair) {
                    if (cur.pair.car != .symbol) return self.badForm("define-macro");
                    cur = cur.pair.cdr;
                }
                if (cur != .nil and cur != .symbol) return self.badForm("define-macro");
                const body = args.pair.cdr;
                const m = try self.allocator.create(core.Macro);
                m.* = .{ .name = macro_name, .formals = try sig.cdr.deep_clone(self.allocator), .body = try body.deep_clone(self.allocator), .env = env };
                const macro_val = core.Value{ .macro = m };
                try env.set(self.interp, macro_name, macro_val);
                _ = try self.emitOp(.load_unspecified);
                return;
            } else {
                return ElzError.InvalidArgument;
            }
        };
        const name = first.symbol;
        try env.set(self.interp, name, transformer);
        _ = try self.emitOp(.load_unspecified);
    }

    fn compileDefineSyntax(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        _ = fuel;
        const name = try self.requireSymbol("define-syntax", args.pair.car);
        const sr_expr = args.pair.cdr.pair.car;

        const sr_val = try evalTransformer(self, sr_expr, name, env);
        try env.set(self.interp, name, sr_val);

        _ = try self.emitOp(.load_unspecified);
    }

    // -----------------------------------------------------------------------
    // set!
    // -----------------------------------------------------------------------

    fn compileSet(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        const name = try self.requireSymbol("set!", args.pair.car);
        const val_expr = args.pair.cdr.pair.car;

        try self.compileExpr(val_expr, env, false, fuel);
        try self.compileVarStore(name);
        // Pop the stored value: store_global/store_local/store_upval are all
        // non-popping (the value stays on the stack). Since `set!` returns
        // unspecified, we must pop the stored value before pushing unspecified,
        // otherwise the leftover value corrupts subsequent local-variable slots.
        _ = try self.emitOp(.pop);
        _ = try self.emitOp(.load_unspecified);
    }

    // -----------------------------------------------------------------------
    // lambda
    // -----------------------------------------------------------------------

    fn compileLambda(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        try self.compileLambdaWithName(args, "<lambda>", env, fuel);
    }

    fn compileLambdaWithName(self: *Compiler, args: Value, name: []const u8, env: *core.Environment, fuel: *u64) ElzError!void {
        const ap = try self.requirePair("lambda", args);
        const params = ap.car;
        const body = ap.cdr;

        // Create a child compiler for the lambda body.
        var child = try Compiler.init(self.allocator, self.interp, name, self);
        defer child.deinit();

        // Parse parameter list.
        child.proto.arity = 0;
        child.proto.variadic = false;

        var cur_param = params;
        while (cur_param != .nil) {
            switch (cur_param) {
                .symbol => |rest_name| {
                    // (lambda rest body) or (lambda (a b . rest) body)
                    _ = try child.scope.addLocal(rest_name);
                    child.proto.variadic = true;
                    break;
                },
                .pair => |pp| {
                    if (pp.car != .symbol) return self.badForm("lambda");
                    _ = try child.scope.addLocal(pp.car.symbol);
                    if (child.proto.arity == std.math.maxInt(u8)) return ElzError.TooManyLocals;
                    child.proto.arity += 1;
                    cur_param = pp.cdr;
                },
                else => return self.badForm("lambda"),
            }
        }

        // Compile the body.
        try child.compileBody(body, env, fuel);

        // Finalize: copy upvalue descriptors into proto.
        for (child.scope.upval_descs.items) |desc| {
            try child.proto.upval_descs.append(child.proto.allocator, desc);
        }
        child.proto.local_count = @intCast(child.scope.locals.items.len);

        // Stash the child proto as a sub-proto of self.
        const sub_idx: u16 = @intCast(self.proto.sub_protos.items.len);
        try self.proto.sub_protos.append(self.proto.allocator, child.proto);
        // Ownership transferred to sub_protos; don't let deinit free it.
        child.proto = try self.allocator.create(FuncProto);
        child.proto.* = FuncProto.init(self.allocator, "<unreachable>");

        // Emit make_closure + capture instructions.
        _ = try self.emitBx(.make_closure, sub_idx);
        for (self.proto.sub_protos.items[sub_idx].upval_descs.items, 0..) |desc, fill_idx| {
            _ = try self.emit(.{
                .op = if (desc.is_local) .capture_local else .capture_upval,
                .a = desc.index,
                .b = @intCast(fill_idx), // upvalue slot index to fill in the new closure
            });
        }
    }

    // -----------------------------------------------------------------------
    // Body compilation (begin + internal defines)
    // -----------------------------------------------------------------------

    fn compileBody(self: *Compiler, body: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        // Flatten the body first: macro uses at body level are expanded so a
        // macro that produces definitions (define-values, define-record-type)
        // is seen, and `begin` forms are spliced as R7RS 5.3.2 requires.
        var forms: std.ArrayListUnmanaged(Value) = .empty;
        defer forms.deinit(self.allocator);
        try self.collectBodyForms(body, env, &forms, fuel);

        // Scan for internal defines and hoist them as locals.
        for (forms.items) |form| {
            if (form == .pair and try self.isKeyword(form.pair.car, "define")) {
                const spec = try self.requirePair("define", form.pair.cdr);
                const target = spec.car;
                const dname = switch (target) {
                    .symbol => |sym| sym,
                    .pair => |tp| try self.requireSymbol("define", tp.car),
                    else => return self.badForm("define"),
                };
                if (self.scope.findLocal(dname) == null) {
                    _ = try self.scope.addLocal(dname);
                    _ = try self.emitOp(.load_false); // placeholder
                }
            }
        }

        // Now compile body forms.
        for (forms.items, 0..) |form, idx| {
            const is_last = idx == forms.items.len - 1;
            try self.compileExpr(form, env, is_last, fuel);
            if (!is_last) _ = try self.emitOp(.pop);
        }
        if (forms.items.len == 0) _ = try self.emitOp(.load_unspecified);
        _ = try self.emitOp(.return_val);
    }

    /// Appends the forms of a body to `out`, expanding macro uses at body
    /// level and splicing `begin` forms.
    fn collectBodyForms(self: *Compiler, body: Value, env: *core.Environment, out: *std.ArrayListUnmanaged(Value), fuel: *u64) ElzError!void {
        var cur = body;
        while (cur == .pair) : (cur = cur.pair.cdr) {
            var form = cur.pair.car;
            while (form == .pair) {
                // A definition in this body shadows a macro of the same name.
                if (form.pair.car == .symbol and (try self.macroShadowed(form.pair.car) or self.bodyDefines(body, form.pair.car.symbol))) break;
                const expanded = try self.tryExpandMacro(form.pair.car, form.pair.cdr, env, fuel) orelse break;
                form = expanded;
            }
            if (form == .pair and try self.isKeyword(form.pair.car, "begin")) {
                try self.collectBodyForms(form.pair.cdr, env, out, fuel);
                continue;
            }
            try out.append(self.allocator, form);
        }
        if (cur != .nil) return self.badForm("lambda");
    }

    // -----------------------------------------------------------------------
    // let / let*
    // -----------------------------------------------------------------------

    fn compileLet(self: *Compiler, args: Value, env: *core.Environment, tail: bool, is_star: bool, fuel: *u64) ElzError!void {
        const form_name = if (is_star) "let*" else "let";
        const first = args.pair.car;

        // Named let: (let name ((var init) ...) body...)
        if (!is_star and first == .symbol) {
            try self.requireOperands("let", args.pair.cdr, 1);
            return self.compileNamedLet(first.symbol, args.pair.cdr, env, tail, fuel);
        }

        const bindings = first;
        const body = args.pair.cdr;
        try self.requireOperands(form_name, bindings, 0);

        if (is_star) {
            // let*: compile as nested immediately-invoked lambdas to ensure internal
            // defines are local and bindings are sequential.
            // (let* ((x e1) (y e2)) body) → ((lambda (x) ((lambda (y) body) e2)) e1)
            // (let* () body) → ((lambda () body))
            try self.compileLetStar(bindings, body, env, tail, fuel);
        } else {
            // Non-star let: compile as an immediately-invoked lambda.
            // (let ((x e1) (y e2)) body) → ((lambda (x y) body) e1 e2)
            //
            // This guarantees correct slot allocation regardless of the stack context
            // (the lambda creates a fresh frame starting at stack_top).

            // Build parameter list.
            var param_list: std.ArrayListUnmanaged(Value) = .empty;
            defer param_list.deinit(self.allocator);
            var init_list: std.ArrayListUnmanaged(Value) = .empty;
            defer init_list.deinit(self.allocator);

            var cur = bindings;
            while (cur == .pair) {
                const binding = try self.requireBinding("let", cur.pair.car);
                try param_list.append(self.allocator, binding.name);
                try init_list.append(self.allocator, binding.init);
                cur = cur.pair.cdr;
            }

            // Build the params list value (reversed).
            var params: Value = .nil;
            var pi = param_list.items.len;
            while (pi > 0) {
                pi -= 1;
                params = try makePair(self.allocator, param_list.items[pi], params);
            }

            // Compile the lambda.
            const lambda_body = try makePair(self.allocator, params, body);
            try self.compileLambdaWithName(lambda_body, "<let>", env, fuel);

            // Compile and push each init argument.
            for (init_list.items) |init_expr| {
                try self.compileExpr(init_expr, env, false, fuel);
            }

            // Call the lambda.
            if (init_list.items.len >= std.math.maxInt(u8)) return ElzError.TooManyLocals;
            const argc: u8 = @intCast(init_list.items.len);
            if (tail) {
                _ = try self.emitA(.tail_call, argc);
            } else {
                _ = try self.emitA(.call, argc);
            }
        }
    }

    /// Compile `let*` as nested immediately-invoked lambdas so that:
    ///   1. Internal `define` forms in the body are always local (never global), and
    ///   2. Bindings are sequential (each init can see previous bindings).
    ///
    /// (let* ()              body) → ((lambda ()    body))
    /// (let* ((x e1))        body) → ((lambda (x)   body) e1)
    /// (let* ((x e1)(y e2))  body) → ((lambda (x) ((lambda (y) body) e2)) e1)
    fn compileLetStar(self: *Compiler, bindings: Value, body: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        if (bindings != .nil and bindings != .pair) return self.badForm("let*");
        if (bindings == .nil) {
            // Base case: compile as ((lambda () body...)).
            const lambda_body = try makePair(self.allocator, Value.nil, body);
            try self.compileLambdaWithName(lambda_body, "<let*>", env, fuel);
            if (tail) {
                _ = try self.emitA(.tail_call, 0);
            } else {
                _ = try self.emitA(.call, 0);
            }
        } else {
            // Recursive case: ((lambda (var) inner-let*) init).
            const binding = try self.requireBinding("let*", bindings.pair.car);
            const var_name_val = binding.name;
            const init_expr = binding.init;
            const rest_bindings = bindings.pair.cdr;

            // Build the inner body: it recursively compiles (let* rest body).
            // We do this by building a single-param lambda whose body is the recursive let*.
            // The lambda body is compiled via a child Compiler just like compileLambdaWithName.
            var child = try Compiler.init(self.allocator, self.interp, "<let*>", self);
            defer child.deinit();
            _ = try child.scope.addLocal(var_name_val.symbol);
            child.proto.arity = 1;
            child.proto.variadic = false;

            // In the child, compile the rest of the let* as another nested lambda
            // call in tail position, so the nested frames do not accumulate.
            try child.compileLetStar(rest_bindings, body, env, true, fuel);
            _ = try child.emitOp(.return_val);

            // Finalize child proto.
            for (child.scope.upval_descs.items) |desc| {
                try child.proto.upval_descs.append(child.proto.allocator, desc);
            }
            child.proto.local_count = @intCast(child.scope.locals.items.len);

            const sub_idx: u16 = @intCast(self.proto.sub_protos.items.len);
            try self.proto.sub_protos.append(self.proto.allocator, child.proto);
            child.proto = try self.allocator.create(FuncProto);
            child.proto.* = FuncProto.init(self.allocator, "<unreachable>");

            _ = try self.emitBx(.make_closure, sub_idx);
            for (self.proto.sub_protos.items[sub_idx].upval_descs.items, 0..) |desc, fill_idx| {
                _ = try self.emit(.{
                    .op = if (desc.is_local) .capture_local else .capture_upval,
                    .a = desc.index,
                    .b = @intCast(fill_idx),
                });
            }

            // Compile and push the init expression.
            try self.compileExpr(init_expr, env, false, fuel);

            if (tail) {
                _ = try self.emitA(.tail_call, 1);
            } else {
                _ = try self.emitA(.call, 1);
            }
        }
    }

    fn compileNamedLet(self: *Compiler, name: []const u8, rest: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // (let name ((var init) ...) body...)
        //
        // Compile by creating a child compiler (fresh frame) that:
        //   1. Allocates a local slot for `name` (with a placeholder).
        //   2. Compiles the loop lambda (so `name` can be captured as upvalue).
        //   3. Stores the closure into the slot and pops the extra value.
        //   4. Loads `name`, compiles init args, calls it.
        //
        // Wrapping in a child compiler isolates the `name` local from the caller's
        // stack, ensuring no extra locals pollute the outer frame.
        const bindings = rest.pair.car;
        const body = rest.pair.cdr;
        try self.requireOperands("let", bindings, 0);

        // Build params list and inits list.
        var cur = bindings;
        var param_list: std.ArrayList(Value) = .empty;
        defer param_list.deinit(self.allocator);
        var init_list: std.ArrayList(Value) = .empty;
        defer init_list.deinit(self.allocator);
        while (cur == .pair) {
            const binding = try self.requireBinding("let", cur.pair.car);
            try param_list.append(self.allocator, binding.name);
            try init_list.append(self.allocator, binding.init);
            cur = cur.pair.cdr;
        }

        // Build (lambda (params...) body...)
        var params: Value = .nil;
        var pi = param_list.items.len;
        while (pi > 0) {
            pi -= 1;
            params = try makePair(self.allocator, param_list.items[pi], params);
        }
        const lambda_body = try makePair(self.allocator, params, body);

        // Create a child compiler for the wrapper that holds the `name` local.
        var wrapper = try Compiler.init(self.allocator, self.interp, name, self);
        defer wrapper.deinit();
        wrapper.proto.arity = 0;
        wrapper.proto.variadic = false;

        // In the wrapper: allocate `name` slot and emit placeholder.
        const slot = try wrapper.scope.addLocal(name);
        _ = try wrapper.emitOp(.load_false); // placeholder

        // Compile the loop lambda inside the wrapper so it can capture `name`.
        try wrapper.compileLambdaWithName(lambda_body, name, env, fuel);

        // Store closure into slot, pop the extra copy.
        _ = try wrapper.emitA(.store_local, slot);
        _ = try wrapper.emitOp(.pop);

        // Load `name` and call with init values.
        _ = try wrapper.emitA(.load_local, slot);
        for (init_list.items) |init_expr| {
            try wrapper.compileExpr(init_expr, env, false, fuel);
        }
        if (init_list.items.len >= std.math.maxInt(u8)) return ElzError.TooManyLocals;
        const argc: u8 = @intCast(init_list.items.len);
        // A tail call: the wrapper frame is replaced by the loop body, so a
        // loop in tail position of a function does not leak a frame per
        // iteration.
        _ = try wrapper.emitA(.tail_call, argc);
        _ = try wrapper.emitOp(.return_val);

        // Finalize wrapper proto.
        for (wrapper.scope.upval_descs.items) |desc| {
            try wrapper.proto.upval_descs.append(wrapper.proto.allocator, desc);
        }
        wrapper.proto.local_count = @intCast(wrapper.scope.locals.items.len);

        const sub_idx: u16 = @intCast(self.proto.sub_protos.items.len);
        try self.proto.sub_protos.append(self.proto.allocator, wrapper.proto);
        wrapper.proto = try self.allocator.create(FuncProto);
        wrapper.proto.* = FuncProto.init(self.allocator, "<unreachable>");

        // Emit make_closure + captures for the wrapper.
        _ = try self.emitBx(.make_closure, sub_idx);
        for (self.proto.sub_protos.items[sub_idx].upval_descs.items, 0..) |desc, fill_idx| {
            _ = try self.emit(.{
                .op = if (desc.is_local) .capture_local else .capture_upval,
                .a = desc.index,
                .b = @intCast(fill_idx),
            });
        }

        // Call the wrapper with 0 args.
        if (tail) {
            _ = try self.emitA(.tail_call, 0);
        } else {
            _ = try self.emitA(.call, 0);
        }
    }

    // -----------------------------------------------------------------------
    // letrec / letrec*
    // -----------------------------------------------------------------------

    fn compileLetrec(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        const bindings = args.pair.car;
        const body = args.pair.cdr;
        try self.requireOperands("letrec", bindings, 0);

        // Rewrite (letrec ((v e) ...) body) as (let ((v #f) ...) (set! v e) ... body)
        // so the let's immediately-invoked lambda provides a fresh frame; allocating
        // locals in the current stack context breaks at top level and in argument
        // position, where the stack holds values below the new slots.
        var names: std.ArrayListUnmanaged(Value) = .empty;
        defer names.deinit(self.allocator);
        var inits: std.ArrayListUnmanaged(Value) = .empty;
        defer inits.deinit(self.allocator);

        var cur = bindings;
        while (cur == .pair) {
            const binding = try self.requireBinding("letrec", cur.pair.car);
            try names.append(self.allocator, binding.name);
            try inits.append(self.allocator, binding.init);
            cur = cur.pair.cdr;
        }

        var new_body = body;
        var i = names.items.len;
        while (i > 0) {
            i -= 1;
            var set_form: Value = .nil;
            set_form = try makePair(self.allocator, inits.items[i], set_form);
            set_form = try makePair(self.allocator, names.items[i], set_form);
            set_form = try makePair(self.allocator, Value{ .symbol = "set!" }, set_form);
            new_body = try makePair(self.allocator, set_form, new_body);
        }

        var new_bindings: Value = .nil;
        i = names.items.len;
        while (i > 0) {
            i -= 1;
            const placeholder = try makePair(self.allocator, Value{ .boolean = false }, Value.nil);
            const new_binding = try makePair(self.allocator, names.items[i], placeholder);
            new_bindings = try makePair(self.allocator, new_binding, new_bindings);
        }

        const new_args = try makePair(self.allocator, new_bindings, new_body);
        try self.compileLet(new_args, env, tail, false, fuel);
    }

    // -----------------------------------------------------------------------
    // and / or
    // -----------------------------------------------------------------------

    fn compileAnd(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        if (args == .nil) {
            _ = try self.emitOp(.load_true);
            return;
        }
        var jumps: std.ArrayList(usize) = .empty;
        defer jumps.deinit(self.allocator);

        var cur = args;
        while (cur == .pair) {
            const expr = cur.pair.car;
            const is_last = cur.pair.cdr == .nil;
            try self.compileExpr(expr, env, tail and is_last, fuel);
            if (!is_last) {
                try jumps.append(self.allocator, try self.emitJump(.jump_if_false));
            }
            cur = cur.pair.cdr;
        }

        // Patch all short-circuit jumps to here.
        const jmp_past = try self.emitJump(.jump); // jump past #f emission
        for (jumps.items) |jidx| {
            self.patchJump(jidx);
        }
        _ = try self.emitOp(.load_false);
        self.patchJump(jmp_past);
    }

    fn compileOr(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        if (args == .nil) {
            _ = try self.emitOp(.load_false);
            return;
        }
        var jumps_to_end: std.ArrayList(usize) = .empty;
        defer jumps_to_end.deinit(self.allocator);

        var cur = args;
        while (cur == .pair) {
            const expr = cur.pair.car;
            const is_last = cur.pair.cdr == .nil;
            try self.compileExpr(expr, env, tail and is_last, fuel);
            if (!is_last) {
                // Duplicate top, test, jump-to-end if truthy
                _ = try self.emitOp(.dup);
                const jt = try self.emitJump(.jump_if_false); // jump over the jmp-to-end if false
                try jumps_to_end.append(self.allocator, try self.emitJump(.jump)); // jump to end (truthy)
                self.patchJump(jt); // false: fall through, pop dup
                _ = try self.emitOp(.pop);
            }
            cur = cur.pair.cdr;
        }
        for (jumps_to_end.items) |j| {
            self.patchJump(j);
        }
    }

    // -----------------------------------------------------------------------
    // cond
    // -----------------------------------------------------------------------

    fn compileCond(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // jump_if_false pops the condition, so we must NOT emit an extra pop after it.
        var jumps_to_end: std.ArrayList(usize) = .empty;
        defer jumps_to_end.deinit(self.allocator);

        var cur = args;
        var found_else = false;
        while (cur == .pair) {
            const clause = try self.requirePair("cond", cur.pair.car);
            cur = cur.pair.cdr;
            const is_last = cur == .nil;

            const test_expr = clause.car;
            const clause_body = clause.cdr;

            // else clause — compile body, break.
            if (try self.isKeyword(test_expr, "else")) {
                found_else = true;
                try self.compileBegin(clause_body, env, tail and is_last, fuel);
                break;
            }

            // cond => arrow: (cond (test => proc) ...) — compile as (let ((t test)) (if t (proc t) ...))
            // Only treat => as the arrow keyword when it is not locally bound (R7RS §4.2.1).
            const arrow_not_bound = clause_body != .nil and try self.isKeyword(clause_body.pair.car, "=>");
            if (arrow_not_bound) {
                const arrow_rest = try self.requirePair("cond", clause_body.pair.cdr);
                const proc_expr = arrow_rest.car;
                // Keep the test value on the stack (no temp local: a local slot
                // allocated here is wrong when cond appears in argument position).
                try self.compileExpr(test_expr, env, false, fuel);
                _ = try self.emitOp(.dup);
                const jif = try self.emitJump(.jump_if_false);
                // Truthy: [test]; call proc with it.
                try self.compileExpr(proc_expr, env, false, fuel);
                _ = try self.emitOp(.swap);
                _ = try self.emitA(.call, 1);
                try jumps_to_end.append(self.allocator, try self.emitJump(.jump));
                self.patchJump(jif);
                // False: discard the test value.
                _ = try self.emitOp(.pop);
                continue;
            }

            try self.compileExpr(test_expr, env, false, fuel);

            if (clause_body == .nil) {
                // (cond (test)) — if test is truthy, return it. Dup before jump_if_false.
                _ = try self.emitOp(.dup);
                const jif = try self.emitJump(.jump_if_false);
                // Truthy: test value is on stack (the original, not the dup that was popped).
                try jumps_to_end.append(self.allocator, try self.emitJump(.jump));
                self.patchJump(jif);
                // False path: pop the dup (test was false, test value still on stack).
                _ = try self.emitOp(.pop);
            } else {
                // (cond (test body...)) — jump_if_false pops test. Compile body if truthy.
                const jif = try self.emitJump(.jump_if_false);
                try self.compileBegin(clause_body, env, tail and is_last, fuel);
                try jumps_to_end.append(self.allocator, try self.emitJump(.jump));
                self.patchJump(jif);
            }
        }

        // No clause matched and there is no else clause: the value is
        // unspecified (R7RS 4.2.1), matching `case` with no matching clause.
        if (!found_else) _ = try self.emitOp(.load_unspecified);

        for (jumps_to_end.items) |j| {
            self.patchJump(j);
        }
    }

    // -----------------------------------------------------------------------
    // case
    // -----------------------------------------------------------------------

    fn compileCase(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // (case key ((datum...) body...) ... (else body...))
        //
        // Compile strategy: push the key once and keep it on the stack throughout
        // all tests. For each datum, dup the key, call eqv?, and use jump_if_false
        // to skip past this datum's body. When a datum matches, the key is on the
        // stack below — pop it before running the body. This avoids any local-slot
        // allocation so `case` is safe to use inside argument lists.
        const key_expr = args.pair.car;
        const clauses = args.pair.cdr;

        // Push the key. Stack: [..., key]
        try self.compileExpr(key_expr, env, false, fuel);

        var jumps_to_end: std.ArrayList(usize) = .empty;
        defer jumps_to_end.deinit(self.allocator);

        try self.requireOperands("case", clauses, 0);
        var cur = clauses;
        while (cur == .pair) {
            const clause = try self.requirePair("case", cur.pair.car);
            cur = cur.pair.cdr;
            const is_last = cur == .nil;

            const datums = clause.car;
            const body = clause.cdr;

            if (try self.isKeyword(datums, "else")) {
                // Run else body (key on stack, consumed by the body helper), jump to end.
                try self.compileCaseBody(body, env, tail and is_last, fuel);
                // Jump to end (past the "no match" fallthrough code).
                try jumps_to_end.append(self.allocator, try self.emitJump(.jump));
                break;
            }

            // For each datum in this clause, emit:
            //   dup key, load eqv?, dup key, load datum, call 2 → bool
            //   jump_if_false to_next_test_or_next_clause
            //   (match found: jump to body)
            //   <next test label>:
            //
            // After all datums fail: stack = [..., key], fall through to next clause.
            // When a datum matches: jump to body_label, stack = [..., key].
            //   body_label: pop key, run body, jump to end.

            try self.requireOperands("case", datums, 0);
            var datum_cur = datums;
            var jumps_to_body: std.ArrayList(usize) = .empty;
            defer jumps_to_body.deinit(self.allocator);

            while (datum_cur == .pair) {
                const datum = datum_cur.pair.car;
                // Stack: [..., key]
                // Build [eqv?, key_copy, datum] on top for call 2.
                _ = try self.emitOp(.dup); // [..., key, key]
                const eqv_ci = try self.addConst(Value{ .symbol = "eqv?" });
                _ = try self.emitBx(.load_global, eqv_ci); // [..., key, key, eqv?]
                _ = try self.emitOp(.swap); // [..., key, eqv?, key]
                const ci = try self.addConst(datum);
                _ = try self.emitBx(.load_const, ci); // [..., key, eqv?, key, datum]
                _ = try self.emitA(.call, 2); // eqv?(key, datum) → bool
                // Stack: [..., key, bool]

                // If false, skip to next datum (or fall through to next clause).
                const jif_skip = try self.emitJump(.jump_if_false);
                // Stack: [..., key]  (bool popped by jump_if_false)
                // bool was true → jump to body.
                try jumps_to_body.append(self.allocator, try self.emitJump(.jump));
                // Patch jif_skip to here (next datum or end of datum list).
                self.patchJump(jif_skip);

                datum_cur = datum_cur.pair.cdr;
            }
            // All datums failed: jump to next clause.
            const jmp_to_next_clause = try self.emitJump(.jump);

            // Body entry: patch all jumps_to_body here.
            for (jumps_to_body.items) |j| {
                self.patchJump(j);
            }
            // Stack: [..., key], consumed by the body helper.
            try self.compileCaseBody(body, env, tail and is_last, fuel);
            try jumps_to_end.append(self.allocator, try self.emitJump(.jump));

            // Next clause entry.
            self.patchJump(jmp_to_next_clause);
        }

        // No clause matched (and no else clause): pop key, push unspecified.
        _ = try self.emitOp(.pop);
        _ = try self.emitOp(.load_unspecified);

        for (jumps_to_end.items) |j| {
            self.patchJump(j);
        }
    }

    /// Compiles (reset body ...) as a thunk plus the reset_prompt opcode.
    fn compileReset(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        if (args != .pair) return ElzError.InvalidArgument;
        try self.compileLambdaArgs(.nil, args, env, fuel);
        _ = try self.emitOp(.reset_prompt);
    }

    /// Compiles (shift k body ...) as (lambda (k) body ...) plus shift_capture.
    fn compileShift(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        if (args != .pair or args.pair.car != .symbol) return ElzError.InvalidArgument;
        const body = args.pair.cdr;
        if (body != .pair) return ElzError.InvalidArgument;
        const param_pair = self.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
        param_pair.* = .{ .car = args.pair.car, .cdr = .nil };
        try self.compileLambdaArgs(Value{ .pair = param_pair }, body, env, fuel);
        _ = try self.emitOp(.shift_capture);
    }

    /// Recursively lowercases every symbol in a form, for include-ci.
    fn foldCase(self: *Compiler, form: Value) ElzError!Value {
        switch (form) {
            .symbol => |s| {
                const folded = self.allocator.dupe(u8, s) catch return ElzError.OutOfMemory;
                for (folded) |*c| c.* = std.ascii.toLower(c.*);
                return Value{ .symbol = folded };
            },
            .pair => |p| {
                const new_pair = self.allocator.create(core.Pair) catch return ElzError.OutOfMemory;
                new_pair.* = .{
                    .car = try self.foldCase(p.car),
                    .cdr = try self.foldCase(p.cdr),
                };
                return Value{ .pair = new_pair };
            },
            else => return form,
        }
    }

    /// Compiles (include "file" ...) by splicing the files' forms in place at
    /// compile time. include-ci case-folds symbols first.
    fn compileInclude(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fold_case: bool, fuel: *u64) ElzError!void {
        if (!self.interp.enable_filesystem) {
            self.interp.last_error_message = "include: filesystem access is disabled";
            return ElzError.PermissionDenied;
        }
        var emitted = false;
        var cur = args;
        while (cur == .pair) : (cur = cur.pair.cdr) {
            const filename_val = cur.pair.car;
            if (filename_val != .string) return ElzError.InvalidArgument;
            if (!self.interp.beginLoading(filename_val.string.bytes)) {
                self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "include: '{s}' includes itself", .{filename_val.string.bytes}) catch null;
                return ElzError.InvalidArgument;
            }
            defer self.interp.endLoading(filename_val.string.bytes);
            const source = std.Io.Dir.cwd().readFileAlloc(self.interp.io, filename_val.string.bytes, self.allocator, .limited(1 * 1024 * 1024)) catch {
                self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "include: cannot read '{s}'", .{filename_val.string.bytes}) catch null;
                return ElzError.FileNotFound;
            };
            var forms = @import("parser.zig").readAll(source, self.allocator) catch |e| return e;
            defer forms.deinit(self.allocator);
            const is_last_file = cur.pair.cdr == .nil;
            for (forms.items, 0..) |form, i| {
                if (emitted) _ = try self.emitOp(.pop);
                const compiled_form = if (fold_case) try self.foldCase(form) else form;
                const form_tail = tail and is_last_file and i == forms.items.len - 1;
                try self.compileExpr(compiled_form, env, form_tail, fuel);
                emitted = true;
            }
        }
        if (!emitted) _ = try self.emitOp(.load_unspecified);
    }

    /// Compiles a case clause body with the key on top of the stack. A plain
    /// body pops the key first; a `(=> proc)` body calls proc with the key.
    fn compileCaseBody(self: *Compiler, body: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        if (body == .pair and try self.isKeyword(body.pair.car, "=>")) {
            if (body.pair.cdr != .pair) return ElzError.InvalidArgument;
            const proc_expr = body.pair.cdr.pair.car;
            try self.compileExpr(proc_expr, env, false, fuel);
            _ = try self.emitOp(.swap);
            _ = try self.emitA(.call, 1);
            return;
        }
        _ = try self.emitOp(.pop);
        try self.compileBegin(body, env, tail, fuel);
    }

    // -----------------------------------------------------------------------
    // when / unless
    // -----------------------------------------------------------------------

    fn compileWhen(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        const test_expr = args.pair.car;
        const body = args.pair.cdr;
        try self.compileExpr(test_expr, env, false, fuel);
        const jif = try self.emitJump(.jump_if_false);
        try self.compileBegin(body, env, tail, fuel);
        const jmp = try self.emitJump(.jump);
        self.patchJump(jif);
        _ = try self.emitOp(.load_unspecified);
        self.patchJump(jmp);
    }

    fn compileUnless(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        const test_expr = args.pair.car;
        const body = args.pair.cdr;
        try self.compileExpr(test_expr, env, false, fuel);
        const jif = try self.emitJump(.jump_if_false);
        _ = try self.emitOp(.load_unspecified);
        const jmp = try self.emitJump(.jump);
        self.patchJump(jif);
        try self.compileBegin(body, env, tail, fuel);
        self.patchJump(jmp);
    }

    // -----------------------------------------------------------------------
    // do
    // -----------------------------------------------------------------------

    fn compileDo(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // (do ((var init step?) ...) (test result...) body...)
        // The operand count is checked at dispatch; the two operand lists are
        // checked here.
        //
        // Expand to a named-let so that loop variables live in their own frame
        // (avoiding slot conflicts when `do` appears in expression position):
        //
        //   (let %%do-loop%% ((var init) ...)
        //     (if test
        //       (begin result...)
        //       (begin body... (%%do-loop%% step-or-var...))))
        //
        // Building this as AST and compiling it via compileNamedLet handles all
        // the stack-frame isolation and tail-call optimisation automatically.
        const var_specs = args.pair.car;
        const test_and_result = args.pair.cdr.pair.car;
        const body_forms = args.pair.cdr.pair.cdr;
        try self.requireOperands("do", var_specs, 0);
        const test_pair = try self.requirePair("do", test_and_result);
        const test_expr = test_pair.car;
        const result_exprs = test_pair.cdr;

        // Collect (var init step?) triples.
        const VarSpec = struct { name: Value, init: Value, step: Value };
        var var_list: std.ArrayList(VarSpec) = .empty;
        defer var_list.deinit(self.allocator);

        var cur = var_specs;
        while (cur == .pair) {
            const spec = try self.requirePair("do", cur.pair.car);
            if (spec.car != .symbol) return self.badForm("do");
            const spec_rest = try self.requirePair("do", spec.cdr);
            const init_e = spec_rest.car;
            // step defaults to the variable itself if omitted.
            const step_e: Value = if (spec_rest.cdr == .pair)
                spec_rest.cdr.pair.car
            else if (spec_rest.cdr == .nil)
                spec.car
            else
                return self.badForm("do");
            try var_list.append(self.allocator, .{ .name = spec.car, .init = init_e, .step = step_e });
            cur = cur.pair.cdr;
        }

        const loop_sym = Value{ .symbol = "%%do-loop%%" };

        // Build the recursive call: (%%do-loop%% step-or-var...)
        var recurse_call: Value = .nil;
        var ri = var_list.items.len;
        while (ri > 0) {
            ri -= 1;
            recurse_call = try makePair(self.allocator, var_list.items[ri].step, recurse_call);
        }
        recurse_call = try makePair(self.allocator, loop_sym, recurse_call);

        // Build the loop body: (begin body... (%%do-loop%% ...)) or just (%%do-loop%% ...)
        var loop_body: Value = try makePair(self.allocator, recurse_call, Value.nil);
        if (body_forms != .nil) {
            // Append body forms before the recursive call.
            // We need to build (begin body_form1 body_form2 ... recurse_call).
            // Build a reversed list of body forms + recurse_call.
            var forms: std.ArrayList(Value) = .empty;
            defer forms.deinit(self.allocator);
            var bc = body_forms;
            while (bc == .pair) {
                try forms.append(self.allocator, bc.pair.car);
                bc = bc.pair.cdr;
            }
            try forms.append(self.allocator, recurse_call);
            // Build list from back.
            loop_body = Value.nil;
            var fi = forms.items.len;
            while (fi > 0) {
                fi -= 1;
                loop_body = try makePair(self.allocator, forms.items[fi], loop_body);
            }
        }
        // Wrap in begin: (begin ...) — but compileBegin just iterates, so pass list directly.
        // Actually the if-false branch needs a single expression, so use begin.
        const begin_sym = Value{ .symbol = "begin" };
        const false_branch = try makePair(self.allocator, begin_sym, loop_body);

        // Build the if test:
        //   (if test (begin result...) (begin body... (loop step...)))
        // If result_exprs is nil, use unspecified.
        const true_branch: Value = if (result_exprs == .nil)
            Value.unspecified
        else blk: {
            const begin_result = try makePair(self.allocator, begin_sym, result_exprs);
            break :blk begin_result;
        };

        const if_sym = Value{ .symbol = "if" };
        var if_args = try makePair(self.allocator, false_branch, Value.nil);
        if_args = try makePair(self.allocator, true_branch, if_args);
        if_args = try makePair(self.allocator, test_expr, if_args);
        const if_form = try makePair(self.allocator, if_sym, if_args);

        // Build named-let bindings: ((var1 init1) (var2 init2) ...)
        var bindings: Value = .nil;
        ri = var_list.items.len;
        while (ri > 0) {
            ri -= 1;
            const init_pair = try makePair(self.allocator, var_list.items[ri].init, Value.nil);
            const binding = try makePair(self.allocator, var_list.items[ri].name, init_pair);
            bindings = try makePair(self.allocator, binding, bindings);
        }

        // Build named-let form: (let %%do-loop%% bindings if-form)
        const body_list = try makePair(self.allocator, if_form, Value.nil);
        const named_let_rest = try makePair(self.allocator, bindings, body_list);

        try self.compileNamedLet(loop_sym.symbol, named_let_rest, env, tail, fuel);
    }

    // -----------------------------------------------------------------------
    // delay
    // -----------------------------------------------------------------------

    fn compileDelay(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        // (delay expr) compiles to (%%make-delayed%% (lambda () expr)).
        // Push the constructor first so the stack is [ctor, thunk] before call 1.
        const ci = try self.addConst(Value{ .symbol = "%%make-delayed%%" });
        _ = try self.emitBx(.load_global, ci);
        const nil_params: Value = .nil;
        const lambda_body = try makePair(self.allocator, nil_params, args);
        try self.compileLambdaWithName(lambda_body, "<delay>", env, fuel);
        _ = try self.emitA(.call, 1);
    }

    // -----------------------------------------------------------------------
    // let-syntax / letrec-syntax
    // -----------------------------------------------------------------------

    fn compileLetSyntax(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // Transformers are bound in the compile-time environment for the extent
        // of the body only: any prior binding of the same name is restored
        // afterwards, and a name that was unbound before becomes unbound again.
        const bindings = args.pair.car;
        const body = args.pair.cdr;

        try self.requireOperands("let-syntax", bindings, 0);

        const Saved = struct { name: []const u8, previous: ?Value };
        var saved: std.ArrayListUnmanaged(Saved) = .empty;
        defer saved.deinit(self.allocator);

        var cur = bindings;
        while (cur == .pair) {
            const binding = try self.requireBinding("let-syntax", cur.pair.car);
            const name = binding.name.symbol;
            const transformer = try evalTransformer(self, binding.init, name, env);
            try saved.append(self.allocator, .{ .name = name, .previous = env.lookup(name) });
            try env.set(self.interp, name, transformer);
            cur = cur.pair.cdr;
        }
        defer {
            var i = saved.items.len;
            while (i > 0) {
                i -= 1;
                const entry = saved.items[i];
                if (entry.previous) |prev| {
                    env.set(self.interp, entry.name, prev) catch {};
                } else {
                    _ = env.remove(entry.name);
                }
            }
        }

        // The body is a <body> of its own (R7RS 4.3.1): definitions inside it
        // are local to it, so compile it as an immediately applied thunk.
        try self.compileLambdaArgs(.nil, body, env, fuel);
        _ = try self.emitA(if (tail) .tail_call else .call, 0);
    }

    // -----------------------------------------------------------------------
    // syntax-rules (as an expression, not define-syntax)
    // -----------------------------------------------------------------------

    fn compileSyntaxRules(self: *Compiler, head: Value, args: Value, env: *core.Environment) ElzError!void {
        _ = head;
        // Build the SyntaxRulesMacro directly from the AST without calling evalForm
        // (calling evalForm would recurse back into compileSyntaxRules indefinitely).
        const ellipsis_bound = switch (try self.resolveVar("...")) {
            .global => false,
            else => true,
        };
        const sr = try macros_mod.buildSyntaxRules(env, "<anonymous>", args, ellipsis_bound);
        sr.def_scope_id = self.id;
        const result = Value{ .syntax_rules = sr };
        const ci = try self.addConst(result);
        _ = try self.emitBx(.load_const, ci);
    }

    // -----------------------------------------------------------------------
    // import
    // -----------------------------------------------------------------------

    fn compileImport(self: *Compiler, args: Value, env: *core.Environment) ElzError!void {
        _ = env;
        if (args == .nil or args != .pair) return ElzError.WrongArgumentCount;
        // (import "path") — load the module file at compile time and cache the
        // result; the expression's value is the module object.
        if (args.pair.car == .string and args.pair.cdr == .nil) {
            const module_val = try self.interp.importModule(args.pair.car);
            const ci = try self.addConst(module_val);
            _ = try self.emitBx(.load_const, ci);
            return;
        }
        // R7RS form: (import (lib name) ...) — bind each registered library's
        // exports into the global environment at compile time.
        var cur = args;
        while (cur == .pair) : (cur = cur.pair.cdr) {
            try self.importLibrarySpec(cur.pair.car);
        }
        _ = try self.emitOp(.load_unspecified);
    }

    /// Builds the canonical registry key for a library name list: parts joined
    /// by single spaces (e.g. "my lib 2").
    fn libraryKey(self: *Compiler, name: Value) ElzError![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var cur = name;
        var first = true;
        while (cur == .pair) : (cur = cur.pair.cdr) {
            if (!first) aw.writer.writeAll(" ") catch return ElzError.OutOfMemory;
            first = false;
            switch (cur.pair.car) {
                .symbol => |s| aw.writer.writeAll(s) catch return ElzError.OutOfMemory,
                .exact_integer => |n| aw.writer.print("{d}", .{n}) catch return ElzError.OutOfMemory,
                else => return ElzError.InvalidArgument,
            }
        }
        if (cur != .nil or first) return ElzError.InvalidArgument;
        return aw.toOwnedSlice() catch return ElzError.OutOfMemory;
    }

    fn importLibrarySpec(self: *Compiler, spec: Value) ElzError!void {
        if (spec == .string) {
            _ = try self.interp.importModule(spec);
            return;
        }
        if (spec != .pair) return ElzError.InvalidArgument;
        const key = try self.libraryKey(spec);
        if (self.interp.library_registry.get(key)) |module| {
            var it = module.exports.iterator();
            while (it.next()) |entry| {
                try self.interp.root_env.set(self.interp, entry.key_ptr.*, entry.value_ptr.*);
            }
            return;
        }
        // Built-in library names resolve to the global environment.
        const head = spec.pair.car;
        if (head == .symbol and (std.mem.eql(u8, head.symbol, "scheme") or std.mem.eql(u8, head.symbol, "elz"))) {
            return;
        }
        self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "import: library ({s}) not found", .{key}) catch null;
        return ElzError.SymbolNotFound;
    }

    /// Compiles (define-library (name ...) clause ...). The body is evaluated
    /// at compile time in the global environment (matching how file modules
    /// load); only the declared exports become the library's bindings, made
    /// visible by (import (name ...)).
    fn compileDefineLibrary(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        _ = fuel;
        if (args != .pair or args.pair.car != .pair) return ElzError.InvalidArgument;
        const key = try self.libraryKey(args.pair.car);

        var export_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer export_names.deinit(self.allocator);
        var body_forms: std.ArrayListUnmanaged(Value) = .empty;
        defer body_forms.deinit(self.allocator);

        var cur = args.pair.cdr;
        while (cur == .pair) : (cur = cur.pair.cdr) {
            const clause = cur.pair.car;
            if (clause != .pair or clause.pair.car != .symbol) return ElzError.InvalidArgument;
            const kind = clause.pair.car.symbol;
            if (std.mem.eql(u8, kind, "export")) {
                var e = clause.pair.cdr;
                while (e == .pair) : (e = e.pair.cdr) {
                    if (e.pair.car != .symbol) return ElzError.InvalidArgument;
                    try export_names.append(self.allocator, e.pair.car.symbol);
                }
            } else if (std.mem.eql(u8, kind, "import")) {
                var i = clause.pair.cdr;
                while (i == .pair) : (i = i.pair.cdr) {
                    try self.importLibrarySpec(i.pair.car);
                }
            } else if (std.mem.eql(u8, kind, "begin")) {
                var b = clause.pair.cdr;
                while (b == .pair) : (b = b.pair.cdr) {
                    try body_forms.append(self.allocator, b.pair.car);
                }
            } else if (std.mem.eql(u8, kind, "include") or std.mem.eql(u8, kind, "include-ci")) {
                const fold = std.mem.eql(u8, kind, "include-ci");
                if (!self.interp.enable_filesystem) {
                    self.interp.last_error_message = "define-library: filesystem access is disabled";
                    return ElzError.PermissionDenied;
                }
                var f = clause.pair.cdr;
                while (f == .pair) : (f = f.pair.cdr) {
                    if (f.pair.car != .string) return ElzError.InvalidArgument;
                    const source = std.Io.Dir.cwd().readFileAlloc(self.interp.io, f.pair.car.string.bytes, self.allocator, .limited(1 * 1024 * 1024)) catch return ElzError.FileNotFound;
                    var forms = @import("parser.zig").readAll(source, self.allocator) catch |e| return e;
                    defer forms.deinit(self.allocator);
                    for (forms.items) |form| {
                        try body_forms.append(self.allocator, if (fold) try self.foldCase(form) else form);
                    }
                }
            } else {
                return ElzError.InvalidArgument;
            }
        }

        // Evaluate the body at compile time, then snapshot the exports.
        if (body_forms.items.len > 0) {
            var local_fuel: u64 = std.math.maxInt(u64);
            const proto = try Compiler.compileTopLevel(self.allocator, self.interp, body_forms.items, env, &local_fuel);
            var machine = try @import("vm.zig").VM.init(self.interp);
            defer machine.deinit();
            _ = try machine.runProto(proto, &local_fuel);
        }

        const module = self.allocator.create(core.Module) catch return ElzError.OutOfMemory;
        module.* = .{ .exports = std.StringHashMap(Value).init(self.allocator) };
        for (export_names.items) |name| {
            const value = self.interp.root_env.get(name, self.interp) catch {
                self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "define-library: exported name '{s}' is not defined", .{name}) catch null;
                return ElzError.SymbolNotFound;
            };
            const owned = self.allocator.dupe(u8, name) catch return ElzError.OutOfMemory;
            module.exports.put(owned, value) catch return ElzError.OutOfMemory;
        }
        self.interp.library_registry.put(self.interp.allocator, key, module) catch return ElzError.OutOfMemory;
        _ = try self.emitOp(.load_unspecified);
    }

    // -----------------------------------------------------------------------
    // Function call
    // -----------------------------------------------------------------------

    fn compileCall(self: *Compiler, callee_expr: Value, arg_list: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // Push callee first, then args left-to-right.
        try self.compileExpr(callee_expr, env, false, fuel);
        var argc: u8 = 0;
        var cur = arg_list;
        while (cur == .pair) {
            try self.compileExpr(cur.pair.car, env, false, fuel);
            if (argc == 255) {
                self.interp.last_error_message = "a call may pass at most 255 arguments";
                return ElzError.InvalidArgument;
            }
            argc += 1;
            cur = cur.pair.cdr;
        }
        if (cur != .nil) {
            self.interp.last_error_message = "an argument list must be a proper list";
            return ElzError.InvalidArgument;
        }
        if (tail) {
            _ = try self.emitA(.tail_call, argc);
        } else {
            _ = try self.emitA(.call, argc);
        }
    }

    // -----------------------------------------------------------------------
    // Top-level compilation
    // -----------------------------------------------------------------------

    /// Compile a sequence of top-level forms. Returns the FuncProto for the
    /// top-level "script" function.
    pub fn compileTopLevel(
        allocator: std.mem.Allocator,
        interp: *@import("interpreter.zig").Interpreter,
        forms: []const Value,
        env: *core.Environment,
        fuel: *u64,
    ) ElzError!*FuncProto {
        var c = try Compiler.init(allocator, interp, "<top>", null);
        defer c.deinit();

        // Record the names this unit defines before compiling it, so that a
        // macro template referring to one is not treated as an introduced
        // identifier and renamed (see macros.zig hygiene renaming).
        var added: std.ArrayListUnmanaged([]const u8) = .empty;
        defer added.deinit(allocator);
        defer {
            for (added.items) |name| {
                _ = interp.pending_globals.remove(name);
            }
        }
        for (forms) |form| try collectTopLevelDefines(allocator, interp, form, &added);

        for (forms, 0..) |form, i| {
            const is_last = i == forms.len - 1;
            try c.compileExpr(form, env, false, fuel);
            if (!is_last) _ = try c.emitOp(.pop);
        }
        if (forms.len == 0) _ = try c.emitOp(.load_unspecified);
        _ = try c.emitOp(.return_val);

        c.proto.local_count = @intCast(c.scope.locals.items.len);
        return c.proto;
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Records the names a top-level form defines into `interp.pending_globals`,
/// descending into `begin` so spliced definitions are seen too.
fn collectTopLevelDefines(
    allocator: std.mem.Allocator,
    interp: *@import("interpreter.zig").Interpreter,
    form: Value,
    added: *std.ArrayListUnmanaged([]const u8),
) ElzError!void {
    if (form != .pair or form.pair.car != .symbol) return;
    const head = macros_mod.hygieneBase(form.pair.car.symbol) orelse form.pair.car.symbol;
    if (std.mem.eql(u8, head, "begin")) {
        var cur = form.pair.cdr;
        while (cur == .pair) : (cur = cur.pair.cdr) {
            try collectTopLevelDefines(allocator, interp, cur.pair.car, added);
        }
        return;
    }
    if (!std.mem.eql(u8, head, "define")) return;
    if (form.pair.cdr != .pair) return;
    const target = form.pair.cdr.pair.car;
    const name: []const u8 = switch (target) {
        .symbol => |sym| sym,
        .pair => |p| if (p.car == .symbol) p.car.symbol else return,
        else => return,
    };
    if (!interp.pending_globals.contains(name)) {
        interp.pending_globals.put(allocator, name, {}) catch return ElzError.OutOfMemory;
        added.append(allocator, name) catch return ElzError.OutOfMemory;
    }
}

/// Minimum number of operands each special form needs. Forms absent from the
/// table place no minimum on their operand count, but still require a proper
/// operand list.
const special_form_operands = [_]struct { name: []const u8, min: usize }{
    .{ .name = "quote", .min = 1 },
    .{ .name = "quasiquote", .min = 1 },
    .{ .name = "if", .min = 2 },
    .{ .name = "begin", .min = 0 },
    .{ .name = "define", .min = 1 },
    .{ .name = "define-macro", .min = 1 },
    .{ .name = "define-syntax", .min = 2 },
    .{ .name = "set!", .min = 2 },
    .{ .name = "lambda", .min = 1 },
    .{ .name = "let", .min = 1 },
    .{ .name = "let*", .min = 1 },
    .{ .name = "letrec", .min = 1 },
    .{ .name = "letrec*", .min = 1 },
    .{ .name = "and", .min = 0 },
    .{ .name = "or", .min = 0 },
    .{ .name = "cond", .min = 0 },
    .{ .name = "case", .min = 1 },
    .{ .name = "when", .min = 1 },
    .{ .name = "unless", .min = 1 },
    .{ .name = "do", .min = 2 },
    .{ .name = "delay", .min = 1 },
    .{ .name = "let-syntax", .min = 1 },
    .{ .name = "letrec-syntax", .min = 1 },
    .{ .name = "reset", .min = 1 },
    .{ .name = "shift", .min = 2 },
    .{ .name = "include", .min = 0 },
    .{ .name = "include-ci", .min = 0 },
    .{ .name = "import", .min = 1 },
    .{ .name = "define-library", .min = 1 },
    .{ .name = "try", .min = 1 },
};

/// Names of the special forms handled directly by the compiler. The REPL uses
/// this for completion, since these names are not bound in any environment.
pub const special_form_names: [special_form_operands.len][]const u8 = blk: {
    var names: [special_form_operands.len][]const u8 = undefined;
    for (special_form_operands, 0..) |entry, i| names[i] = entry.name;
    break :blk names;
};

fn minOperands(sym: []const u8) ?usize {
    for (special_form_operands) |entry| {
        if (std.mem.eql(u8, entry.name, sym)) return entry.min;
    }
    return null;
}

fn listLen(list: Value) usize {
    var n: usize = 0;
    var cur = list;
    while (cur != .nil and cur == .pair) {
        n += 1;
        cur = cur.pair.cdr;
    }
    return n;
}

fn makePair(allocator: std.mem.Allocator, car: Value, cdr: Value) !Value {
    const p = try allocator.create(core.Pair);
    p.* = .{ .car = car, .cdr = cdr };
    return Value{ .pair = p };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "compile simple literal" {
    const testing = std.testing;
    const interp_mod = @import("interpreter.zig");
    var interp = try interp_mod.Interpreter.init(.{});
    defer interp.deinit();

    const allocator = interp.allocator;
    const forms = [_]Value{Value{ .exact_integer = 42 }};
    var fuel: u64 = 1_000_000;
    const proto = try Compiler.compileTopLevel(allocator, &interp, &forms, interp.root_env, &fuel);
    defer {
        proto.deinit();
        allocator.destroy(proto);
    }

    try testing.expectEqual(@as(usize, 2), proto.instructions.items.len);
    try testing.expectEqual(OpCode.load_const, proto.instructions.items[0].op);
    try testing.expectEqual(OpCode.return_val, proto.instructions.items[1].op);
}

test "compileTopLevel cleans up pending_globals" {
    const testing = std.testing;
    const interp_mod = @import("interpreter.zig");
    var interp = try interp_mod.Interpreter.init(.{});
    defer interp.deinit();

    const allocator = interp.allocator;
    var fuel: u64 = 1_000_000;
    const define_form = try makePair(allocator, Value{ .symbol = "define" }, try makePair(allocator, Value{ .symbol = "my-pending-var" }, try makePair(allocator, Value{ .exact_integer = 1 }, Value.nil)));
    const forms = [_]Value{define_form};
    _ = try Compiler.compileTopLevel(allocator, &interp, &forms, interp.root_env, &fuel);

    try testing.expectEqual(@as(usize, 0), interp.pending_globals.count());
}
