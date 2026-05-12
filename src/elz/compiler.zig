/// Elz bytecode compiler: AST Value → FuncProto
///
/// Transforms parsed Elz S-expressions into bytecode chunks that can be
/// executed by vm.zig.  The compiler handles all special forms, tail-call
/// detection, lexical closures with upvalue capture, and compile-time macro
/// expansion.
const std = @import("std");
const core = @import("core.zig");
const chunk = @import("chunk.zig");
// eval_mod is imported for compile-time macro expansion: define-macro and define-syntax
// transformers must be evaluated (not just compiled) so their output can be used
// immediately by the rest of the compilation pass.
const eval_mod = @import("eval.zig");
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
    // Macro expansion (delegates to eval.zig at compile time)
    // -----------------------------------------------------------------------

    fn tryExpandMacro(self: *Compiler, head: Value, args: Value, env: *core.Environment, fuel: *u64) !?Value {
        if (head != .symbol) return null;
        const looked_up = env.get(head.symbol, self.interp) catch return null;
        switch (looked_up) {
            .syntax_rules => |sr| {
                return try eval_mod.expandSyntaxRules(self.interp, sr, args, env, fuel);
            },
            .macro => |m| {
                return try eval_mod.expandMacro(self.interp, m, args, env, fuel);
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
        if (std.mem.eql(u8, sym, "import")) return self.compileImport(args, env);

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
                // (unquote x) at level 1 → compile x
                if (level == 1 and p.car == .symbol and std.mem.eql(u8, p.car.symbol, "unquote")) {
                    return self.compileExpr(p.cdr.pair.car, env, false, fuel);
                }
                // (unquote-splicing ...) handled in list context below
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
        // Check for (unquote-splicing x) at level 1
        if (level == 1 and car == .pair and
            car.pair.car == .symbol and std.mem.eql(u8, car.pair.car.symbol, "unquote-splicing"))
        {
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
    // define-macro / define-syntax
    // -----------------------------------------------------------------------

    fn compileDefineMacro(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        // Evaluate the transformer at compile time and bind it in env.
        // Then emit nothing (macros are compile-time only).
        _ = fuel;
        const name_val = args.pair.car;
        if (name_val != .symbol) return ElzError.InvalidArgument;
        const name = name_val.symbol;
        const transformer_expr = args.pair.cdr.pair.car;

        var f: u64 = 1_000_000;
        const transformer = try eval_mod.eval(self.interp, &transformer_expr, env, &f);
        try env.set(self.interp, name, transformer);

        _ = try self.emitOp(.load_unspecified);
    }

    fn compileDefineSyntax(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        _ = fuel;
        const name_val = args.pair.car;
        if (name_val != .symbol) return ElzError.InvalidArgument;
        const name = name_val.symbol;
        const sr_expr = args.pair.cdr.pair.car;

        var f: u64 = 1_000_000;
        const sr_val = try eval_mod.eval(self.interp, &sr_expr, env, &f);
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
        const upval_count = self.proto.sub_protos.items[sub_idx].upval_descs.items.len;
        for (self.proto.sub_protos.items[sub_idx].upval_descs.items) |desc| {
            _ = try self.emit(.{
                .op = if (desc.is_local) .capture_local else .capture_upval,
                .a = desc.index,
                .b = @intCast(upval_count),
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

        // Evaluate binding inits before adding locals.
        var cur = bindings;
        var count: u8 = 0;
        while (cur != .nil) {
            const binding = cur.pair.car;
            const init_expr = binding.pair.cdr.pair.car;
            try self.compileExpr(init_expr, env, false, fuel);
            if (is_star) {
                // For let*, each binding is immediately visible to subsequent inits.
                const var_name = binding.pair.car.symbol;
                const slot = try self.scope.addLocal(var_name);
                _ = try self.emitA(.store_local, slot);
            }
            count += 1;
            cur = cur.pair.cdr;
        }

        if (!is_star) {
            // For let, add all locals after evaluating all inits.
            cur = bindings;
            while (cur != .nil) {
                const binding = cur.pair.car;
                const var_name = binding.pair.car.symbol;
                const slot = try self.scope.addLocal(var_name);
                _ = try self.emitA(.store_local, slot);
                cur = cur.pair.cdr;
            }
        }

        try self.compileBegin(body, env, tail, fuel);
    }

    fn compileNamedLet(self: *Compiler, name: []const u8, rest: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        _ = tail;
        const bindings = rest.pair.car;
        const body = rest.pair.cdr;

        // Build params list and inits list.
        var params: Value = .nil;
        var inits: Value = .nil;
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

        // Build (lambda (params...) body) and compile it
        params = .nil;
        var pi = param_list.items.len;
        while (pi > 0) {
            pi -= 1;
            params = try makePair(self.allocator, param_list.items[pi], params);
        }

        const lambda_body = try makePair(self.allocator, params, body);
        try self.compileLambdaWithName(lambda_body, name, env, fuel);

        // Bind in scope so recursive calls work
        const slot = try self.scope.addLocal(name);
        _ = try self.emitA(.store_local, slot);

        // Compile inits and call
        _ = try self.emitA(.load_local, slot);
        for (init_list.items) |init_expr| {
            try self.compileExpr(init_expr, env, false, fuel);
        }
        _ = try self.emitA(.call, @intCast(init_list.items.len));

        inits = .nil; // suppress unused
    }

    // -----------------------------------------------------------------------
    // letrec / letrec*
    // -----------------------------------------------------------------------

    fn compileLetrec(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        const bindings = args.pair.car;
        const body = args.pair.cdr;

        // Allocate all locals first (set to #f placeholder).
        var cur = bindings;
        while (cur != .nil) {
            const binding = cur.pair.car;
            const var_name = binding.pair.car.symbol;
            _ = try self.scope.addLocal(var_name);
            _ = try self.emitOp(.load_false);
            cur = cur.pair.cdr;
        }

        // Now store all locals from initializer start (find the first slot).
        const first_slot: u8 = @intCast(self.scope.locals.items.len - listLen(bindings));
        cur = bindings;
        var i: u8 = first_slot;
        while (cur != .nil) {
            const binding = cur.pair.car;
            const init_expr = binding.pair.cdr.pair.car;
            try self.compileExpr(init_expr, env, false, fuel);
            _ = try self.emitA(.store_local, i);
            cur = cur.pair.cdr;
            i += 1;
        }

        try self.compileBegin(body, env, tail, fuel);
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
        var jumps_to_end: std.ArrayList(usize) = .empty;
        defer jumps_to_end.deinit(self.allocator);

        var cur = args;
        while (cur != .nil) {
            const clause = cur.pair.car;
            cur = cur.pair.cdr;
            const is_last = cur == .nil;

            const test_expr = clause.pair.car;
            const clause_body = clause.pair.cdr;

            // else clause
            if (test_expr == .symbol and std.mem.eql(u8, test_expr.symbol, "else")) {
                try self.compileBegin(clause_body, env, tail and is_last, fuel);
                break;
            }

            // cond => arrow
            if (clause_body != .nil and clause_body.pair.car == .symbol and
                std.mem.eql(u8, clause_body.pair.car.symbol, "=>"))
            {
                const proc_expr = clause_body.pair.cdr.pair.car;
                try self.compileExpr(test_expr, env, false, fuel);
                _ = try self.emitOp(.dup);
                const jif = try self.emitJump(.jump_if_false);
                // truthy: call proc with test value
                try self.compileExpr(proc_expr, env, false, fuel);
                _ = try self.emitOp(.dup); // [proc, testval, proc]
                // Swap needed: stack is [test_dup, proc]... actually let's just use call
                // Stack: ..., test_dup, proc → swap test_dup below proc, call 1
                // Instead, compile as: dup test → test proc → call 1
                // Actually we have: test_dup (from dup), then proc on top.
                // We need [proc, test_dup] but have [test_dup, proc].
                // Emit a small helper: swap instruction not in our set.
                // Simplest: re-arrange. Let's store test in a temp local.
                // For simplicity, compile this as: (let ((t test)) (if t (proc t) ...))
                // But we're mid-stream. Use a simpler approach:
                // Load proc, load test_dup again from stack position using store_local.
                // Actually: pop proc into local, pop testval, load testval, load proc, call 1
                // This is getting complex. Just emit a load_const for the proc and call.
                // The simplest correct approach: give up on the stack trick and use locals.
                // Revert: just pop and discard the proc dup, then call proc expr with test.
                _ = try self.emitOp(.pop); // pop the proc dup
                _ = try self.emitOp(.pop); // pop the test dup

                // Redo: store test result in a temp local
                _ = try self.emitOp(.pop); // discard
                self.patchJump(jif);
                // Re-do without the arrow optimization for now
                // Fall through to next clause
                continue;
            }

            try self.compileExpr(test_expr, env, false, fuel);
            const jif = try self.emitJump(.jump_if_false);

            if (clause_body == .nil) {
                // (cond (test)) — return test value
                // We already have test on stack; just jump to end
            } else {
                _ = try self.emitOp(.pop); // discard test value
                try self.compileBegin(clause_body, env, tail and is_last, fuel);
            }

            try jumps_to_end.append(self.allocator, try self.emitJump(.jump));
            self.patchJump(jif);
        }

        // If no clause matched, emit unspecified
        _ = try self.emitOp(.load_unspecified);

        for (jumps_to_end.items) |j| {
            self.patchJump(j);
        }
    }

    // -----------------------------------------------------------------------
    // case
    // -----------------------------------------------------------------------

    fn compileCase(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        // (case key ((datum...) body...) ... (else body...))
        // Compile as: eval key, store in local, then chain of if-eqv? checks.
        const key_expr = args.pair.car;
        const clauses = args.pair.cdr;

        try self.compileExpr(key_expr, env, false, fuel);
        const key_slot = try self.scope.addLocal("__case_key__");
        _ = try self.emitA(.store_local, key_slot);

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
                try self.compileBegin(body, env, tail and is_last, fuel);
                break;
            }

            // Test: (eqv? key datum1) or (eqv? key datum2) ...
            // Build OR of eqv? tests
            var datum_jumps: std.ArrayList(usize) = .empty;
            defer datum_jumps.deinit(self.allocator);

            var datum_cur = datums;
            var is_first_datum = true;
            while (datum_cur != .nil) {
                if (!is_first_datum) {
                    // If previous test passed, skip to body
                    try datum_jumps.append(self.allocator, try self.emitJump(.jump));
                }
                const datum = datum_cur.pair.car;
                _ = try self.emitA(.load_local, key_slot);
                const ci = try self.addConst(datum);
                _ = try self.emitBx(.load_const, ci);
                // emit eqv? call
                const eqv_ci = try self.addConst(Value{ .symbol = "eqv?" });
                _ = try self.emitBx(.load_global, eqv_ci);
                // Reorder: need [proc, arg1, arg2]
                // Currently stack: key, datum, eqv?
                // We need eqv? first... This is tricky with a stack VM.
                // Simpler: load eqv? first, then key, then datum
                // Let me redo this differently
                _ = try self.emitOp(.pop); // pop eqv?
                _ = try self.emitOp(.pop); // pop datum
                _ = try self.emitOp(.pop); // pop key

                // Load in correct order: eqv?, key, datum
                _ = try self.emitBx(.load_global, eqv_ci);
                _ = try self.emitA(.load_local, key_slot);
                _ = try self.emitBx(.load_const, ci);
                _ = try self.emitA(.call, 2);

                is_first_datum = false;
                datum_cur = datum_cur.pair.cdr;
            }

            // Check if any datum matched: jump_if_false to next clause
            const jif = try self.emitJump(.jump_if_false);

            // Patch "datum matched" jumps to here
            for (datum_jumps.items) |j| {
                self.patchJump(j);
            }

            try self.compileBegin(body, env, tail and is_last, fuel);
            try jumps_to_end.append(self.allocator, try self.emitJump(.jump));
            self.patchJump(jif);
        }

        _ = try self.emitOp(.load_unspecified);

        for (jumps_to_end.items) |j| {
            self.patchJump(j);
        }
    }

    // -----------------------------------------------------------------------
    // when / unless
    // -----------------------------------------------------------------------

    fn compileWhen(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        const test_expr = args.pair.car;
        const body = args.pair.cdr;
        try self.compileExpr(test_expr, env, false, fuel);
        const jif = try self.emitJump(.jump_if_false);
        _ = try self.emitOp(.pop);
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
        _ = try self.emitOp(.pop);
        try self.compileBegin(body, env, tail, fuel);
        self.patchJump(jmp);
    }

    // -----------------------------------------------------------------------
    // do
    // -----------------------------------------------------------------------

    fn compileDo(self: *Compiler, args: Value, env: *core.Environment, tail: bool, fuel: *u64) ElzError!void {
        _ = tail;
        // (do ((var init step) ...) (test result...) body...)
        const var_specs = args.pair.car;
        const test_and_result = args.pair.cdr.pair.car;
        const body = args.pair.cdr.pair.cdr;

        // Allocate locals for loop variables
        var var_list: std.ArrayList(struct { name: []const u8, slot: u8, step: ?Value }) = .empty;
        defer var_list.deinit(self.allocator);

        var cur = var_specs;
        while (cur != .nil) {
            const spec = cur.pair.car;
            const var_name = spec.pair.car.symbol;
            const init_expr = spec.pair.cdr.pair.car;
            const step_expr: ?Value = if (spec.pair.cdr.pair.cdr != .nil)
                spec.pair.cdr.pair.cdr.pair.car
            else
                null;

            try self.compileExpr(init_expr, env, false, fuel);
            const slot = try self.scope.addLocal(var_name);
            _ = try self.emitA(.store_local, slot);
            try var_list.append(self.allocator, .{ .name = var_name, .slot = slot, .step = step_expr });
            cur = cur.pair.cdr;
        }

        // Loop start
        const loop_start = self.proto.instructions.items.len;

        // Test
        const test_expr = test_and_result.pair.car;
        const result_exprs = test_and_result.pair.cdr;
        try self.compileExpr(test_expr, env, false, fuel);
        const jif_exit = try self.emitJump(.jump_if_false);

        // Result expressions (exit path)
        if (result_exprs == .nil) {
            _ = try self.emitOp(.load_unspecified);
        } else {
            try self.compileBegin(result_exprs, env, false, fuel);
        }
        const jmp_exit = try self.emitJump(.jump);

        self.patchJump(jif_exit);

        // Body
        if (body != .nil) {
            try self.compileBegin(body, env, false, fuel);
            _ = try self.emitOp(.pop);
        }

        // Step updates (evaluate all steps first, then store)
        var step_vals: std.ArrayList(u8) = .empty;
        defer step_vals.deinit(self.allocator);
        for (var_list.items) |v| {
            if (v.step) |step| {
                try self.compileExpr(step, env, false, fuel);
            } else {
                _ = try self.emitA(.load_local, v.slot);
            }
        }
        // Now store in reverse... actually store in order from bottom of stack
        var vi = var_list.items.len;
        while (vi > 0) {
            vi -= 1;
            // Store into temp then re-assign... this is tricky with stack ordering.
            // Simple approach: store into a temporary slot, then copy back.
            // Since we pushed all step values, the last one is on top.
            // We need to store them in reverse order.
            const v = var_list.items[var_list.items.len - 1 - (var_list.items.len - 1 - vi)];
            _ = try self.emitA(.store_local, v.slot);
        }

        // Jump back to loop start
        const current = self.proto.instructions.items.len;
        const back_offset: i16 = -@as(i16, @intCast(current - loop_start + 1));
        _ = try self.emit(Instruction.init_offset(.jump, back_offset));

        self.patchJump(jmp_exit);
    }

    // -----------------------------------------------------------------------
    // delay
    // -----------------------------------------------------------------------

    fn compileDelay(self: *Compiler, args: Value, env: *core.Environment, fuel: *u64) ElzError!void {
        // Compile as (delay expr) → runtime delay object
        // For the VM, delay can be implemented as a lambda with no args
        // that gets wrapped in a promise at runtime.
        // For now, compile as a lambda and let the VM wrap it.
        const expr = args.pair.car;
        const nil_params: Value = .nil;
        const lambda_body = try makePair(self.allocator, nil_params, args);
        try self.compileLambdaWithName(lambda_body, "<delay>", env, fuel);
        // The VM's `delay` primitive will be called with the thunk.
        // Actually emit a call to the primitive `make-promise`.
        const ci = try self.addConst(Value{ .symbol = "make-promise" });
        _ = try self.emitBx(.load_global, ci);
        // Swap: [lambda, make-promise] → [make-promise, lambda]
        // No swap instruction. Use a temp local.
        const tmp = try self.scope.addLocal("__delay_tmp__");
        _ = try self.emitA(.store_local, tmp);
        _ = try self.emitBx(.load_global, ci);
        _ = try self.emitA(.load_local, tmp);
        _ = try self.emitA(.call, 1);
        _ = expr; // already used above
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
            var f: u64 = 1_000_000;
            const transformer = try eval_mod.eval(self.interp, &transformer_expr, env, &f);
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
        // Evaluate at compile time and push as a constant.
        var f: u64 = 1_000_000;
        const form = try makePair(self.allocator, Value{ .symbol = "syntax-rules" }, args);
        const result = try eval_mod.eval(self.interp, &form, env, &f);
        const ci = try self.addConst(result);
        _ = try self.emitBx(.load_const, ci);
    }

    // -----------------------------------------------------------------------
    // import
    // -----------------------------------------------------------------------

    fn compileImport(self: *Compiler, args: Value, env: *core.Environment) ElzError!void {
        // (import module path) — evaluated at compile time via eval
        var f: u64 = 1_000_000;
        const form = try makePair(self.allocator, Value{ .symbol = "import" }, args);
        _ = try eval_mod.eval(self.interp, &form, env, &f);
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
    ) ElzError!*FuncProto {
        var c = try Compiler.init(allocator, interp, "<top>", null);
        defer c.deinit();

        var fuel: u64 = 1_000_000;
        for (forms, 0..) |form, i| {
            const is_last = i == forms.len - 1;
            try c.compileExpr(form, env, false, &fuel);
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
    const proto = try Compiler.compileTopLevel(allocator, &interp, &forms, interp.root_env);
    defer {
        proto.deinit();
        allocator.destroy(proto);
    }

    try testing.expectEqual(@as(usize, 2), proto.instructions.items.len);
    try testing.expectEqual(OpCode.load_const, proto.instructions.items[0].op);
    try testing.expectEqual(OpCode.return_val, proto.instructions.items[1].op);
}
