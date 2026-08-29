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
    fn addLocal(self: *Scope, name: []const u8) !u8 {
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

    /// Add an upvalue descriptor and return its index.
    fn addUpval(self: *Scope, desc: UpvalDesc) !u8 {
        for (self.upval_descs.items, 0..) |existing, i| {
            if (existing.is_local == desc.is_local and existing.index == desc.index)
                return @intCast(i);
        }
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
    /// Interpreter reference for macro expansion.
    interp: *@import("interpreter.zig").Interpreter,
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
        return .{
            .allocator = allocator,
            .proto = proto,
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
        return self.proto.emit(instr);
    }

    fn emitOp(self: *Compiler, op: OpCode) !usize {
        return self.proto.emit(Instruction.init_op(op));
    }

    fn emitA(self: *Compiler, op: OpCode, a: u8) !usize {
        return self.proto.emit(Instruction.init_a(op, a));
    }

    fn emitBx(self: *Compiler, op: OpCode, bx: u16) !usize {
        return self.proto.emit(Instruction.init_bx(op, bx));
    }

    fn emitJump(self: *Compiler, op: OpCode) !usize {
        return self.proto.emit(Instruction.init_offset(op, 0));
    }

    fn patchJump(self: *Compiler, idx: usize) void {
        self.proto.patchJump(idx);
    }

    fn addConst(self: *Compiler, val: Value) !u16 {
        return self.proto.addConst(val);
    }

    // -----------------------------------------------------------------------
    // Macro expansion
    // -----------------------------------------------------------------------

    fn tryExpandMacro(self: *Compiler, head: Value, args: Value, env: *core.Environment, fuel: *u64) !?Value {
        if (head != .symbol) return null;
        const looked_up = env.get(head.symbol, self.interp) catch return null;
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

    fn compileVarLoad(self: *Compiler, name: []const u8) ElzError!void {
        const loc = try self.resolveVar(name);
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
        const loc = try self.resolveVar(name);
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
        // Try macro expansion first (compile-time).
        if (try self.tryExpandMacro(head, args, env, fuel)) |expanded| {
            return self.compileExpr(expanded, env, tail, fuel);
        }

        if (head != .symbol) {
            // (expr args...) — eval head then args
            return self.compileCall(head, args, env, tail, fuel);
        }

        const sym = head.symbol;

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
        if (std.mem.eql(u8, sym, "include")) return self.compileInclude(args, env, tail, false, fuel);
        if (std.mem.eql(u8, sym, "include-ci")) return self.compileInclude(args, env, tail, true, fuel);
        if (std.mem.eql(u8, sym, "syntax-error")) {
            if (args == .pair and args.pair.car == .string) {
                self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "syntax-error: {s}", .{args.pair.car.string}) catch null;
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
                // lose their special meaning inside quasiquote per R5RS §4.2.6).
                const unquote_is_global = blk: {
                    if (p.car == .symbol and std.mem.eql(u8, p.car.symbol, "unquote")) {
                        const loc = try self.resolveVar("unquote");
                        break :blk switch (loc) {
                            .global => true,
                            else => false,
                        };
                    }
                    break :blk false;
                };
                const unquote_splice_is_global = blk: {
                    if (p.car == .symbol and std.mem.eql(u8, p.car.symbol, "unquote-splicing")) {
                        const loc = try self.resolveVar("unquote-splicing");
                        break :blk switch (loc) {
                            .global => true,
                            else => false,
                        };
                    }
                    break :blk false;
                };
                // (unquote x) at level 1 → compile x
                if (level == 1 and unquote_is_global) {
                    return self.compileExpr(p.cdr.pair.car, env, false, fuel);
                }
                // (unquote x) at level > 1 → produce (unquote (qq-expand x level-1))
                if (level > 1 and unquote_is_global) {
                    const ci = try self.addConst(Value{ .symbol = "unquote" });
                    _ = try self.emitBx(.load_const, ci);
                    try self.compileQQ(p.cdr.pair.car, env, level - 1, fuel);
                    _ = try self.emitA(.make_list, 1);
                    _ = try self.emitOp(.cons);
                    return;
                }
                // (unquote-splicing x) at level > 1 → produce (unquote-splicing (qq-expand x level-1))
                if (level > 1 and unquote_splice_is_global) {
                    const ci = try self.addConst(Value{ .symbol = "unquote-splicing" });
                    _ = try self.emitBx(.load_const, ci);
                    try self.compileQQ(p.cdr.pair.car, env, level - 1, fuel);
                    _ = try self.emitA(.make_list, 1);
                    _ = try self.emitOp(.cons);
                    return;
                }
                // (quasiquote x) — increase level
                if (p.car == .symbol and std.mem.eql(u8, p.car.symbol, "quasiquote")) {
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
                // Build vector elements
                var count: u8 = 0;
                for (v.items) |item| {
                    try self.compileQQ(item, env, level, fuel);
                    count += 1;
                }
                _ = try self.emitA(.make_vector, count);
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
        // Check for (unquote-splicing x) at level 1 — splice (only when unquote-splicing is global)
        const splice_is_global = blk: {
            if (car == .pair and car.pair.car == .symbol and
                std.mem.eql(u8, car.pair.car.symbol, "unquote-splicing"))
            {
                const loc = try self.resolveVar("unquote-splicing");
                break :blk switch (loc) {
                    .global => true,
                    else => false,
                };
            }
            break :blk false;
        };
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
        const test_expr = args.pair.car;
        const then_expr = args.pair.cdr.pair.car;
        const has_else = args.pair.cdr.pair.cdr != .nil;
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
        while (cur != .nil) {
            const p = cur.pair;
            const is_last = p.cdr == .nil;
            try self.compileExpr(p.car, env, tail and is_last, fuel);
            if (!is_last) _ = try self.emitOp(.pop);
            cur = p.cdr;
        }
    }

    // -----------------------------------------------------------------------
    // define
    // -----------------------------------------------------------------------

    fn compileDefine(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        const target = args.pair.car;
        const rest = args.pair.cdr;

        if (target == .symbol) {
            // (define name expr)
            const name = target.symbol;
            const val_expr: Value = if (rest != .nil) rest.pair.car else .unspecified;
            try self.compileExpr(val_expr, env, false, fuel);
            try self.emitDefineOrStore(name);
        } else if (target == .pair) {
            // (define (f params...) body...)
            const name_sym = target.pair.car;
            if (name_sym != .symbol) return ElzError.InvalidArgument;
            const name = name_sym.symbol;
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
            // Local define inside a function body
            if (self.scope.findLocal(name)) |slot| {
                _ = try self.emitA(.store_local, slot);
            } else {
                const slot = try self.scope.addLocal(name);
                _ = try self.emitA(.store_local, slot);
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
        while (cur != .nil) {
            const form = cur.pair.car;
            if (form == .pair and form.pair.car == .symbol and
                std.mem.eql(u8, form.pair.car.symbol, "catch"))
            {
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
        if (catch_clause == null) return ElzError.InvalidArgument;
        const catch_rest = catch_clause.?.pair.cdr; // (err handler...)
        const err_sym = catch_rest.pair.car;
        if (err_sym != .symbol) return ElzError.InvalidArgument;
        const handler_body = catch_rest.pair.cdr;

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

        // Close all upvalues for the current frame before calling %%try%%.
        // The thunks may capture locals from the current frame as open upvalues. When
        // %%try%% calls them via a new VM (runFromEval), those open upvalues would point
        // into the original VM's stack — which is invalid. Closing them first copies the
        // values into the upvalue cells so they're safe to use from any VM.
        _ = try self.emitA(.close_upval, 0);

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
        if (expr == .pair and expr.pair.car == .symbol and std.mem.eql(u8, expr.pair.car.symbol, "syntax-rules")) {
            const ellipsis_bound = switch (try self.resolveVar("...")) {
                .global => false,
                else => true,
            };
            const sr = try macros_mod.buildSyntaxRules(env, name, expr.pair.cdr, ellipsis_bound);
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
                const transformer_expr = args.pair.cdr.pair.car;
                break :blk try evalTransformer(self, transformer_expr, first.symbol, env);
            } else if (first == .pair) {
                // Shorthand: (define-macro (name params...) body)
                const sig = first.pair;
                const macro_name = if (sig.car == .symbol) sig.car.symbol else return ElzError.InvalidArgument;
                // Validate the formals: symbols in a proper or dotted list, or a bare rest symbol.
                var cur = sig.cdr;
                while (cur == .pair) {
                    if (cur.pair.car != .symbol) return ElzError.InvalidArgument;
                    cur = cur.pair.cdr;
                }
                if (cur != .nil and cur != .symbol) return ElzError.InvalidArgument;
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
        const name_val = args.pair.car;
        if (name_val != .symbol) return ElzError.InvalidArgument;
        const name = name_val.symbol;
        const sr_expr = args.pair.cdr.pair.car;

        const sr_val = try evalTransformer(self, sr_expr, name, env);
        try env.set(self.interp, name, sr_val);

        _ = try self.emitOp(.load_unspecified);
    }

    // -----------------------------------------------------------------------
    // set!
    // -----------------------------------------------------------------------

    fn compileSet(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        const name_val = args.pair.car;
        if (name_val != .symbol) return ElzError.InvalidArgument;
        const name = name_val.symbol;
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
        const params = args.pair.car;
        const body = args.pair.cdr;

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
                    if (pp.car != .symbol) return ElzError.InvalidArgument;
                    _ = try child.scope.addLocal(pp.car.symbol);
                    child.proto.arity += 1;
                    cur_param = pp.cdr;
                },
                else => return ElzError.InvalidArgument,
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
        // Scan for internal defines and hoist them as locals.
        var cur = body;
        while (cur != .nil) {
            const form = cur.pair.car;
            if (form == .pair and form.pair.car == .symbol and
                std.mem.eql(u8, form.pair.car.symbol, "define"))
            {
                const target = form.pair.cdr.pair.car;
                const dname = if (target == .symbol) target.symbol else target.pair.car.symbol;
                _ = try self.scope.addLocal(dname);
                _ = try self.emitOp(.load_false); // placeholder
            }
            cur = cur.pair.cdr;
        }

        // Now compile body forms.
        cur = body;
        var idx: usize = 0;
        const body_len = listLen(body);
        while (cur != .nil) {
            const form = cur.pair.car;
            const is_last = idx == body_len - 1;
            try self.compileExpr(form, env, is_last, fuel);
            if (!is_last) _ = try self.emitOp(.pop);
            cur = cur.pair.cdr;
            idx += 1;
        }
        if (body_len == 0) _ = try self.emitOp(.load_unspecified);
        _ = try self.emitOp(.return_val);
    }

    // -----------------------------------------------------------------------
    // let / let*
    // -----------------------------------------------------------------------

    fn compileLet(self: *Compiler, args: Value, env: *core.Environment, tail: bool, is_star: bool, fuel: *u64) ElzError!void {
        const first = args.pair.car;

        // Named let: (let name ((var init) ...) body...)
        if (!is_star and first == .symbol) {
            return self.compileNamedLet(first.symbol, args.pair.cdr, env, tail, fuel);
        }

        const bindings = first;
        const body = args.pair.cdr;

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
            while (cur != .nil) {
                const binding = cur.pair.car;
                try param_list.append(self.allocator, binding.pair.car); // name
                try init_list.append(self.allocator, binding.pair.cdr.pair.car); // init
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
            const binding = bindings.pair.car;
            const var_name_val = binding.pair.car;
            if (var_name_val != .symbol) return ElzError.InvalidArgument;
            const init_expr = binding.pair.cdr.pair.car;
            const rest_bindings = bindings.pair.cdr;

            // Build the inner body: it recursively compiles (let* rest body).
            // We do this by building a single-param lambda whose body is the recursive let*.
            // The lambda body is compiled via a child Compiler just like compileLambdaWithName.
            var child = try Compiler.init(self.allocator, self.interp, "<let*>", self);
            defer child.deinit();
            _ = try child.scope.addLocal(var_name_val.symbol);
            child.proto.arity = 1;
            child.proto.variadic = false;

            // In the child, compile the rest of the let* as another nested lambda call,
            // then return the result.
            try child.compileLetStar(rest_bindings, body, env, false, fuel);
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

        // Build params list and inits list.
        var cur = bindings;
        var param_list: std.ArrayList(Value) = .empty;
        defer param_list.deinit(self.allocator);
        var init_list: std.ArrayList(Value) = .empty;
        defer init_list.deinit(self.allocator);
        while (cur != .nil) {
            const binding = cur.pair.car;
            try param_list.append(self.allocator, binding.pair.car);
            try init_list.append(self.allocator, binding.pair.cdr.pair.car);
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
        const argc: u8 = @intCast(init_list.items.len);
        _ = try wrapper.emitA(.call, argc);
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

        // Rewrite (letrec ((v e) ...) body) as (let ((v #f) ...) (set! v e) ... body)
        // so the let's immediately-invoked lambda provides a fresh frame; allocating
        // locals in the current stack context breaks at top level and in argument
        // position, where the stack holds values below the new slots.
        var names: std.ArrayListUnmanaged(Value) = .empty;
        defer names.deinit(self.allocator);
        var inits: std.ArrayListUnmanaged(Value) = .empty;
        defer inits.deinit(self.allocator);

        var cur = bindings;
        while (cur != .nil) {
            const binding = cur.pair.car;
            try names.append(self.allocator, binding.pair.car);
            try inits.append(self.allocator, binding.pair.cdr.pair.car);
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
        while (cur != .nil) {
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
        while (cur != .nil) {
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
        while (cur != .nil) {
            const clause = cur.pair.car;
            cur = cur.pair.cdr;
            const is_last = cur == .nil;

            const test_expr = clause.pair.car;
            const clause_body = clause.pair.cdr;

            // else clause — compile body, break.
            if (test_expr == .symbol and std.mem.eql(u8, test_expr.symbol, "else")) {
                found_else = true;
                try self.compileBegin(clause_body, env, tail and is_last, fuel);
                break;
            }

            // cond => arrow: (cond (test => proc) ...) — compile as (let ((t test)) (if t (proc t) ...))
            // Only treat => as the arrow keyword when it is not locally bound (R5RS §4.2.1).
            const arrow_not_bound = brk: {
                if (clause_body != .nil and clause_body.pair.car == .symbol and
                    std.mem.eql(u8, clause_body.pair.car.symbol, "=>"))
                {
                    const loc = try self.resolveVar("=>");
                    break :brk switch (loc) {
                        .global => true,
                        else => false,
                    };
                }
                break :brk false;
            };
            if (arrow_not_bound) {
                const proc_expr = clause_body.pair.cdr.pair.car;
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

        // No clause matched (and no else): return nil per R5RS.
        if (!found_else) _ = try self.emitOp(.load_nil);

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

        var cur = clauses;
        while (cur != .nil) {
            const clause = cur.pair.car;
            cur = cur.pair.cdr;
            const is_last = cur == .nil;

            const datums = clause.pair.car;
            const body = clause.pair.cdr;

            if (datums == .symbol and std.mem.eql(u8, datums.symbol, "else")) {
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

            var datum_cur = datums;
            var jumps_to_body: std.ArrayList(usize) = .empty;
            defer jumps_to_body.deinit(self.allocator);

            while (datum_cur != .nil) {
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
        var emitted = false;
        var cur = args;
        while (cur == .pair) : (cur = cur.pair.cdr) {
            const filename_val = cur.pair.car;
            if (filename_val != .string) return ElzError.InvalidArgument;
            const source = std.Io.Dir.cwd().readFileAlloc(self.interp.io, filename_val.string, self.allocator, .limited(1 * 1024 * 1024)) catch {
                self.interp.last_error_message = std.fmt.allocPrint(self.allocator, "include: cannot read '{s}'", .{filename_val.string}) catch null;
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
        if (body == .pair and body.pair.car == .symbol and std.mem.eql(u8, body.pair.car.symbol, "=>")) {
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
        const test_expr = test_and_result.pair.car;
        const result_exprs = test_and_result.pair.cdr;

        // Collect (var init step?) triples.
        const VarSpec = struct { name: Value, init: Value, step: Value };
        var var_list: std.ArrayList(VarSpec) = .empty;
        defer var_list.deinit(self.allocator);

        var cur = var_specs;
        while (cur != .nil) {
            const spec = cur.pair.car;
            const var_name = spec.pair.car;
            const init_e = spec.pair.cdr.pair.car;
            // step defaults to the variable itself if omitted.
            const step_e: Value = if (spec.pair.cdr.pair.cdr != .nil)
                spec.pair.cdr.pair.cdr.pair.car
            else
                var_name;
            try var_list.append(self.allocator, .{ .name = var_name, .init = init_e, .step = step_e });
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
            while (bc != .nil) {
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
        // (delay expr) compiles to (make-promise (lambda () expr)).
        // Push make-promise first so the stack is [make-promise, thunk] before call 1.
        const ci = try self.addConst(Value{ .symbol = "make-promise" });
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
        // Evaluate transformer bindings into env at compile time.
        const bindings = args.pair.car;
        const body = args.pair.cdr;

        var cur = bindings;
        while (cur != .nil) {
            const binding = cur.pair.car;
            const name = binding.pair.car.symbol;
            const transformer_expr = binding.pair.cdr.pair.car;
            const transformer = try evalTransformer(self, transformer_expr, name, env);
            try env.set(self.interp, name, transformer);
            cur = cur.pair.cdr;
        }

        try self.compileBegin(body, env, tail, fuel);
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
                var f = clause.pair.cdr;
                while (f == .pair) : (f = f.pair.cdr) {
                    if (f.pair.car != .string) return ElzError.InvalidArgument;
                    const source = std.Io.Dir.cwd().readFileAlloc(self.interp.io, f.pair.car.string, self.allocator, .limited(1 * 1024 * 1024)) catch return ElzError.FileNotFound;
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
        while (cur != .nil) {
            try self.compileExpr(cur.pair.car, env, false, fuel);
            argc += 1;
            cur = cur.pair.cdr;
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
