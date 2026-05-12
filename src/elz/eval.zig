const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const Value = core.Value;
const UserDefinedProc = core.UserDefinedProc;
const Environment = core.Environment;
const ElzError = @import("errors.zig").ElzError;
const interpreter = @import("interpreter.zig");
const parser = @import("parser.zig");
const env_setup = @import("env_setup.zig");

// ============================================================================
// Continuation helpers
// ============================================================================

pub fn allocCont(interp: *interpreter.Interpreter, frame: core.ContFrame, next: ?*core.Cont) ElzError!*core.Cont {
    const k = try interp.allocator.create(core.Cont);
    k.* = .{ .frame = frame, .next = next };
    return k;
}

fn isTruthy(v: Value) bool {
    return switch (v) {
        .boolean => |b| b,
        else => true,
    };
}

// ============================================================================
// Quote / Quasiquote
// ============================================================================

fn evalQuote(rest: Value, env: *Environment) !Value {
    const p_arg = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.QuoteInvalidArguments,
    };
    if (p_arg.cdr != .nil) return ElzError.QuoteInvalidArguments;
    return try p_arg.car.deep_clone(env.allocator);
}

fn evalQuasiquote(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) !Value {
    const p_arg = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.InvalidArgument,
    };
    if (p_arg.cdr != .nil) return ElzError.InvalidArgument;
    return try expandQuasiquote(interp, p_arg.car, env, fuel, 1);
}

fn expandQuasiquote(interp: *interpreter.Interpreter, template: Value, env: *Environment, fuel: *u64, level: usize) ElzError!Value {
    switch (template) {
        .pair => |p| {
            const unquote_is_free = if (p.car.is_symbol("unquote")) blk: {
                _ = env.get("unquote", interp) catch break :blk true;
                break :blk false;
            } else false;
            if (unquote_is_free) {
                if (level == 1) {
                    const unquote_rest = switch (p.cdr) {
                        .pair => |up| up,
                        else => return ElzError.InvalidArgument,
                    };
                    if (unquote_rest.cdr != .nil) return ElzError.InvalidArgument;
                    return try eval(interp, &unquote_rest.car, env, fuel);
                } else {
                    const new_cdr = try expandQuasiquote(interp, p.cdr, env, fuel, level - 1);
                    const new_pair = try env.allocator.create(core.Pair);
                    new_pair.* = .{ .car = p.car, .cdr = new_cdr };
                    return Value{ .pair = new_pair };
                }
            } else if (p.car.is_symbol("quasiquote")) {
                const new_cdr = try expandQuasiquote(interp, p.cdr, env, fuel, level + 1);
                const new_pair = try env.allocator.create(core.Pair);
                new_pair.* = .{ .car = p.car, .cdr = new_cdr };
                return Value{ .pair = new_pair };
            } else if (p.car == .pair) {
                const inner = p.car.pair;
                const splice_is_free = if (inner.car.is_symbol("unquote-splicing")) blk: {
                    _ = env.get("unquote-splicing", interp) catch break :blk true;
                    break :blk false;
                } else false;
                if (splice_is_free and level == 1) {
                    const splice_rest = switch (inner.cdr) {
                        .pair => |sp| sp,
                        else => return ElzError.InvalidArgument,
                    };
                    if (splice_rest.cdr != .nil) return ElzError.InvalidArgument;
                    const splice_result = try eval(interp, &splice_rest.car, env, fuel);
                    const rest_expanded = try expandQuasiquote(interp, p.cdr, env, fuel, level);
                    return try appendLists(env.allocator, splice_result, rest_expanded);
                }
            }
            const new_car = try expandQuasiquote(interp, p.car, env, fuel, level);
            const new_cdr = try expandQuasiquote(interp, p.cdr, env, fuel, level);
            const new_pair = try env.allocator.create(core.Pair);
            new_pair.* = .{ .car = new_car, .cdr = new_cdr };
            return Value{ .pair = new_pair };
        },
        else => return try template.deep_clone(env.allocator),
    }
}

fn appendLists(allocator: std.mem.Allocator, list1: Value, list2: Value) ElzError!Value {
    if (list1 == .nil) return list2;
    if (list1 != .pair) return ElzError.InvalidArgument;
    const new_pair = try allocator.create(core.Pair);
    new_pair.* = .{
        .car = try list1.pair.car.deep_clone(allocator),
        .cdr = try appendLists(allocator, list1.pair.cdr, list2),
    };
    return Value{ .pair = new_pair };
}

// ============================================================================
// Import
// ============================================================================

fn evalImport(
    interp: *interpreter.Interpreter,
    rest: core.Value,
    env: *core.Environment,
    fuel: *u64,
) ElzError!core.Value {
    _ = env;
    _ = fuel;

    const arg_list = rest;
    if (arg_list == .nil) return ElzError.WrongArgumentCount;
    const first_pair = switch (arg_list) {
        .pair => |p| p,
        else => return ElzError.InvalidArgument,
    };
    const path_val = first_pair.car;
    const remaining = first_pair.cdr;
    if (remaining != .nil) return ElzError.WrongArgumentCount;

    const path_str = switch (path_val) {
        .string => |s| s,
        else => return ElzError.InvalidArgument,
    };

    if (interp.module_cache.get(path_str)) |cached_mod_ptr| {
        return core.Value{ .module = cached_mod_ptr };
    }

    const source_bytes = std.Io.Dir.cwd().readFileAlloc(interp.io, path_str, interp.allocator, .limited(1024 * 1024)) catch {
        interp.last_error_message = "Failed to read module file.";
        return ElzError.InvalidArgument;
    };
    defer interp.allocator.free(source_bytes);

    var forms = parser.readAll(source_bytes, interp.allocator) catch {
        interp.last_error_message = "Failed to parse module file.";
        return ElzError.InvalidArgument;
    };
    defer forms.deinit(interp.allocator);

    const module_env = try core.Environment.init(interp.allocator, interp.root_env);

    const form_it = forms.items;
    for (form_it) |form_node| {
        var local_fuel: u64 = 1_000_000;
        _ = try eval(interp, &form_node, module_env, &local_fuel);
    }

    const mod_ptr = try interp.allocator.create(core.Module);
    mod_ptr.* = .{
        .exports = std.StringHashMap(core.Value).init(interp.allocator),
    };

    var temp = std.ArrayListUnmanaged(struct { k: []const u8, v: core.Value }).empty;
    defer temp.deinit(interp.allocator);

    {
        var it = module_env.bindings.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.*.len > 0 and entry.key_ptr.*[0] == '_') continue;
            try temp.append(interp.allocator, .{ .k = entry.key_ptr.*, .v = entry.value_ptr.* });
        }
    }

    try mod_ptr.exports.ensureTotalCapacity(@intCast(temp.items.len));

    for (temp.items) |kv| {
        try mod_ptr.exports.put(kv.k, kv.v);
    }

    const cached_name = try interp.allocator.dupe(u8, path_str);
    try interp.module_cache.put(cached_name, mod_ptr);

    return core.Value{ .module = mod_ptr };
}

// ============================================================================
// Lambda / define-macro / macro expansion
// ============================================================================

fn evalLambda(rest: Value, env: *Environment) !Value {
    const p_formals = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.LambdaInvalidArguments,
    };
    const params_list = p_formals.car;
    const body = p_formals.cdr;
    if (body == .nil) return ElzError.LambdaInvalidArguments;

    var params_list_gc = core.ValueList.init(env.allocator);
    var rest_param_name: ?[]const u8 = null;

    switch (params_list) {
        .symbol => |s| {
            rest_param_name = try env.allocator.dupe(u8, s);
        },
        .nil => {},
        .pair => {
            var current_param = params_list;
            while (true) {
                switch (current_param) {
                    .pair => |pp| {
                        if (pp.car != .symbol) return ElzError.LambdaInvalidParams;
                        try params_list_gc.append(pp.car);
                        current_param = pp.cdr;
                    },
                    .nil => break,
                    .symbol => |s| {
                        rest_param_name = try env.allocator.dupe(u8, s);
                        break;
                    },
                    else => return ElzError.LambdaInvalidParams,
                }
            }
        },
        else => return ElzError.LambdaInvalidParams,
    }

    const proc = try env.allocator.create(UserDefinedProc);
    proc.* = .{
        .params = params_list_gc,
        .rest_param = rest_param_name,
        .body = try body.deep_clone(env.allocator),
        .env = env,
    };
    return Value{ .closure = proc };
}

fn evalDefineMacro(interp: *interpreter.Interpreter, rest: Value, env: *Environment) !Value {
    const p_sig = switch (rest) {
        .pair => |p| p,
        else => return ElzError.DefineInvalidArguments,
    };
    const signature = p_sig.car;
    const body = p_sig.cdr;
    const sig_pair = switch (signature) {
        .pair => |p| p,
        else => return ElzError.DefineInvalidArguments,
    };
    const macro_name = switch (sig_pair.car) {
        .symbol => |s| s,
        else => return ElzError.DefineInvalidSymbol,
    };
    var params_list = core.ValueList.init(env.allocator);
    var current_param = sig_pair.cdr;
    while (current_param != .nil) {
        const param_p = switch (current_param) {
            .pair => |p| p,
            else => return ElzError.LambdaInvalidParams,
        };
        if (param_p.car != .symbol) return ElzError.LambdaInvalidParams;
        try params_list.append(param_p.car);
        current_param = param_p.cdr;
    }
    const macro = try env.allocator.create(core.Macro);
    macro.* = .{
        .name = macro_name,
        .params = params_list,
        .body = try body.deep_clone(env.allocator),
        .env = env,
    };
    const macro_val = Value{ .macro = macro };
    try env.set(interp, macro_name, macro_val);
    return macro_val;
}

pub fn expandMacro(interp: *interpreter.Interpreter, m: *core.Macro, rest: Value, env: *Environment, fuel: *u64) ElzError!Value {
    var unevaluated_args = std.ArrayListUnmanaged(Value).empty;
    defer unevaluated_args.deinit(env.allocator);
    var current_node = rest;
    while (current_node != .nil) {
        const pair = switch (current_node) {
            .pair => |p| p,
            else => break,
        };
        try unevaluated_args.append(env.allocator, pair.car);
        current_node = pair.cdr;
    }
    if (unevaluated_args.items.len != m.params.items.len) return ElzError.WrongArgumentCount;
    const macro_env = try Environment.init(env.allocator, m.env);
    for (m.params.items, unevaluated_args.items) |param, arg| {
        try macro_env.set(interp, param.symbol, arg);
    }
    var body_node = m.body;
    var expansion: Value = .unspecified;
    while (body_node != .nil) {
        const pair = switch (body_node) {
            .pair => |p| p,
            else => break,
        };
        expansion = try eval(interp, &pair.car, macro_env, fuel);
        body_node = pair.cdr;
    }
    return expansion;
}

// ============================================================================
// letrec / try (direct-style, they call back into eval)
// ============================================================================

fn evalLetRec(interp: *interpreter.Interpreter, ast: Value, env: *Environment, fuel: *u64) ElzError!Value {
    if (ast != .pair) return ElzError.InvalidArgument;
    const top = ast.pair;
    const rest = top.cdr;
    if (rest == .nil or rest != .pair) return ElzError.InvalidArgument;

    const bindings_and_body = rest.pair;
    const bindings_val = bindings_and_body.car;
    const body_list = bindings_and_body.cdr;

    const new_env = try Environment.init(env.allocator, env);

    var current_binding_node = bindings_val;
    while (current_binding_node != .nil) {
        if (current_binding_node != .pair) return ElzError.InvalidArgument;
        const binding_cell = current_binding_node.pair;
        const binding = binding_cell.car;
        if (binding != .pair) return ElzError.InvalidArgument;
        const var_init = binding.pair;
        const var_sym_val = var_init.car;
        if (var_sym_val != .symbol) return ElzError.InvalidArgument;
        try new_env.set(interp, var_sym_val.symbol, Value.unspecified);
        current_binding_node = binding_cell.cdr;
    }

    current_binding_node = bindings_val;
    while (current_binding_node != .nil) {
        const binding_cell = current_binding_node.pair;
        const binding = binding_cell.car;
        const var_init = binding.pair;
        const var_sym_val = var_init.car;
        const init_tail = var_init.cdr;
        if (init_tail == .nil or init_tail != .pair) return ElzError.InvalidArgument;
        const init_pair = init_tail.pair;
        var init_expr = init_pair.car;
        if (init_pair.cdr != .nil) return ElzError.InvalidArgument;

        const value = try eval(interp, &init_expr, new_env, fuel);
        try new_env.update(interp, var_sym_val.symbol, value);

        current_binding_node = binding_cell.cdr;
    }

    if (body_list == .nil) return Value.nil;

    var body_node = body_list;
    var last: Value = Value.unspecified;
    while (true) {
        if (body_node != .pair) return ElzError.InvalidArgument;
        const bpair = body_node.pair;
        var expr = bpair.car;
        last = try eval(interp, &expr, new_env, fuel);
        if (bpair.cdr == .nil) break;
        body_node = bpair.cdr;
    }

    std.mem.doNotOptimizeAway(&new_env);
    return last;
}

fn evalTry(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) !Value {
    var try_body_forms = std.ArrayListUnmanaged(core.Value).empty;
    defer try_body_forms.deinit(env.allocator);
    var catch_clause: ?core.Value = null;
    var current_node = rest;
    while (current_node != .nil) {
        const node_p = switch (current_node) {
            .pair => |pair_val| pair_val,
            else => return ElzError.InvalidArgument,
        };
        const form = node_p.car;
        if (form == .pair and form.pair.car.is_symbol("catch")) {
            catch_clause = form;
            break;
        }
        try try_body_forms.append(env.allocator, form);
        current_node = node_p.cdr;
    }

    if (catch_clause == null) return ElzError.InvalidArgument;

    const catch_p = catch_clause.?.pair;
    const catch_args_p = switch (catch_p.cdr) {
        .pair => |pair_val| pair_val,
        else => return ElzError.InvalidArgument,
    };

    const err_symbol = catch_args_p.car;
    if (err_symbol != .symbol) return ElzError.InvalidArgument;
    const handler_body = catch_args_p.cdr;
    if (handler_body == .nil) return ElzError.InvalidArgument;

    // Snapshot the winder stack so we can unwind dynamic-wind after-thunks on error.
    const winders_before = interp.winders;

    var last_result: core.Value = .unspecified;
    var eval_error: ?ElzError = null;
    for (try_body_forms.items) |form| {
        last_result = eval(interp, &form, env, fuel) catch |err| {
            eval_error = err;
            break;
        };
    }

    if (eval_error) |_| {
        // Run after-thunks for any dynamic-wind frames that were entered after the try
        // started but never exited normally (error bypasses the CPS after-thunk machinery).
        var w = interp.winders;
        while (w != winders_before) {
            const winder = w.?;
            w = winder.next;
            interp.winders = w;
            const no_args = core.ValueList.init(env.allocator);
            _ = eval_winder_after(interp, winder.after, no_args, fuel);
        }

        const new_env = try Environment.init(env.allocator, env);
        const msg = interp.last_error_message orelse "An unknown error occurred.";
        const err_val = try Value.from(env.allocator, msg);
        try new_env.set(interp, err_symbol.symbol, err_val);
        var current_handler_node = handler_body;
        var handler_result: core.Value = .unspecified;
        while (current_handler_node != .nil) {
            const handler_p = current_handler_node.pair;
            handler_result = try eval(interp, &handler_p.car, new_env, fuel);
            current_handler_node = handler_p.cdr;
        }
        std.mem.doNotOptimizeAway(&new_env);
        return handler_result;
    } else {
        return last_result;
    }
}

/// Call a dynamic-wind after-thunk during error unwinding. Errors in after-thunks are
/// silently ignored so that the original error propagates cleanly.
fn eval_winder_after(interp: *interpreter.Interpreter, after_proc: Value, args: core.ValueList, fuel: *u64) void {
    const halt = allocCont(interp, .halt, null) catch return;
    var step: core.EvalStep = applyProc(interp, after_proc, args, interp.root_env, halt, fuel) catch return;
    while (true) {
        step = switch (step) {
            .eval => |e| evalStep(interp, e.ast, e.env, e.k, fuel) catch return,
            .apply => |a| applyK(interp, a.k, a.val, fuel) catch return,
            .done => return,
        };
    }
}

// ============================================================================
// Helper for case: eqv?
// ============================================================================

fn is_eqv(a: Value, b: Value) bool {
    return switch (a) {
        .number => |n| if (b == .number) n == b.number else false,
        .exact_integer => |n| if (b == .exact_integer) n == b.exact_integer else false,
        .rational => |r| if (b == .rational) r.numerator == b.rational.numerator and r.denominator == b.rational.denominator else false,
        .complex => |c| if (b == .complex) c.real == b.complex.real and c.imag == b.complex.imag else false,
        .boolean => |bl| if (b == .boolean) bl == b.boolean else false,
        .character => |c| if (b == .character) c == b.character else false,
        .symbol => |s| if (b == .symbol) std.mem.eql(u8, s, b.symbol) else false,
        .nil => b == .nil,
        else => false,
    };
}

// ============================================================================
// syntax-rules machinery (ported verbatim from develop)
// ============================================================================

fn is_literal_identifier(name: []const u8, literals: [][]const u8) bool {
    for (literals) |lit| {
        if (std.mem.eql(u8, lit, name)) return true;
    }
    return false;
}

fn is_ellipsis_marker(value: Value, ellipsis: []const u8) bool {
    if (ellipsis.len == 0) return false;
    if (value != .pair) return false;
    const car = value.pair.car;
    return car == .symbol and std.mem.eql(u8, car.symbol, ellipsis);
}

const PatternBinding = union(enum) {
    single: Value,
    repeated: []Value,
};

const Bindings = std.StringHashMapUnmanaged(PatternBinding);

fn collect_pattern_vars(
    allocator: std.mem.Allocator,
    pattern: Value,
    literals: [][]const u8,
    ellipsis: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    switch (pattern) {
        .symbol => |s| {
            if (std.mem.eql(u8, s, "_")) return;
            if (ellipsis.len > 0 and std.mem.eql(u8, s, ellipsis)) return;
            if (is_literal_identifier(s, literals)) return;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, s)) return;
            }
            try out.append(allocator, s);
        },
        .pair => |p| {
            try collect_pattern_vars(allocator, p.car, literals, ellipsis, out);
            try collect_pattern_vars(allocator, p.cdr, literals, ellipsis, out);
        },
        else => {},
    }
}

const MatchError = error{
    OutOfMemory,
    MissingPatternVar,
    NestedEllipsisUnsupported,
};

const special_form_names: []const []const u8 = &.{
    "quote",        "quasiquote", "unquote",      "unquote-splicing",
    "if",           "cond",       "case",         "and",
    "or",           "define",     "define-macro", "define-syntax",
    "syntax-rules", "set!",       "lambda",       "begin",
    "let",          "let*",       "letrec",       "do",
    "delay",        "try",        "catch",        "import",
    "else",         "...",        "_",
};

fn is_special_form_name(name: []const u8) bool {
    for (special_form_names) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn match_pattern(
    allocator: std.mem.Allocator,
    pattern: Value,
    input: Value,
    literals: [][]const u8,
    ellipsis: []const u8,
    bindings: *Bindings,
) MatchError!bool {
    switch (pattern) {
        .symbol => |s| {
            if (is_literal_identifier(s, literals)) {
                if (input != .symbol) return false;
                return std.mem.eql(u8, s, input.symbol);
            }
            if (std.mem.eql(u8, s, "_")) return true;
            try bindings.put(allocator, s, .{ .single = input });
            return true;
        },
        .nil => return input == .nil,
        .pair => |p| {
            if (is_ellipsis_marker(p.cdr, ellipsis)) {
                const tail_pattern = p.cdr.pair.cdr;
                if (tail_pattern == .nil) {
                    return try match_ellipsis_tail(allocator, p.car, input, literals, ellipsis, bindings);
                }
                return try match_ellipsis_non_trailing(allocator, p.car, tail_pattern, input, literals, ellipsis, bindings);
            }
            if (input != .pair) return false;
            const ip = input.pair;
            if (!try match_pattern(allocator, p.car, ip.car, literals, ellipsis, bindings)) return false;
            return try match_pattern(allocator, p.cdr, ip.cdr, literals, ellipsis, bindings);
        },
        .number => |n| {
            if (input != .number) return false;
            return n == input.number;
        },
        .boolean => |b| {
            if (input != .boolean) return false;
            return b == input.boolean;
        },
        .string => |s| {
            if (input != .string) return false;
            return std.mem.eql(u8, s, input.string);
        },
        .character => |c| {
            if (input != .character) return false;
            return c == input.character;
        },
        else => return false,
    }
}

fn match_ellipsis_tail(
    allocator: std.mem.Allocator,
    sub_pat: Value,
    input: Value,
    literals: [][]const u8,
    ellipsis: []const u8,
    bindings: *Bindings,
) MatchError!bool {
    var var_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer var_names.deinit(allocator);
    try collect_pattern_vars(allocator, sub_pat, literals, ellipsis, &var_names);

    var accumulators: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty;
    defer {
        for (accumulators.items) |*acc| acc.deinit(allocator);
        accumulators.deinit(allocator);
    }
    for (var_names.items) |_| {
        try accumulators.append(allocator, .empty);
    }

    var node = input;
    while (node == .pair) {
        var iter_bindings: Bindings = .empty;
        defer iter_bindings.deinit(allocator);
        const ok = try match_pattern(allocator, sub_pat, node.pair.car, literals, ellipsis, &iter_bindings);
        if (!ok) return false;
        for (var_names.items, 0..) |name, i| {
            const got = iter_bindings.get(name) orelse return error.MissingPatternVar;
            switch (got) {
                .single => |v| try accumulators.items[i].append(allocator, v),
                .repeated => return error.NestedEllipsisUnsupported,
            }
        }
        node = node.pair.cdr;
    }
    if (node != .nil) return false;

    for (var_names.items, 0..) |name, i| {
        const slice = try accumulators.items[i].toOwnedSlice(allocator);
        try bindings.put(allocator, name, .{ .repeated = slice });
    }
    return true;
}

// Handles patterns like (sub_pat ... fixed1 fixed2) where the ellipsis is non-trailing.
// Determines how many elements the ellipsis must consume, matches that prefix, then
// delegates the fixed suffix to a recursive match_pattern call.
fn match_ellipsis_non_trailing(
    allocator: std.mem.Allocator,
    sub_pat: Value,
    tail_pattern: Value,
    input: Value,
    literals: [][]const u8,
    ellipsis: []const u8,
    bindings: *Bindings,
) MatchError!bool {
    // Count required tail elements (elements after the ellipsis in the pattern).
    var tail_len: usize = 0;
    var tp = tail_pattern;
    while (tp == .pair) {
        tail_len += 1;
        tp = tp.pair.cdr;
    }

    // Count available input elements.
    var input_len: usize = 0;
    var node = input;
    while (node == .pair) {
        input_len += 1;
        node = node.pair.cdr;
    }
    if (node != .nil) return false;
    if (input_len < tail_len) return false;

    const ellipsis_count = input_len - tail_len;

    var var_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer var_names.deinit(allocator);
    try collect_pattern_vars(allocator, sub_pat, literals, ellipsis, &var_names);

    var accumulators: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty;
    defer {
        for (accumulators.items) |*acc| acc.deinit(allocator);
        accumulators.deinit(allocator);
    }
    for (var_names.items) |_| {
        try accumulators.append(allocator, .empty);
    }

    node = input;
    var i: usize = 0;
    while (i < ellipsis_count) : (i += 1) {
        var iter_bindings: Bindings = .empty;
        defer iter_bindings.deinit(allocator);
        const ok = try match_pattern(allocator, sub_pat, node.pair.car, literals, ellipsis, &iter_bindings);
        if (!ok) return false;
        for (var_names.items, 0..) |name, j| {
            const got = iter_bindings.get(name) orelse return error.MissingPatternVar;
            switch (got) {
                .single => |v| try accumulators.items[j].append(allocator, v),
                .repeated => return error.NestedEllipsisUnsupported,
            }
        }
        node = node.pair.cdr;
    }

    for (var_names.items, 0..) |name, j| {
        const slice = try accumulators.items[j].toOwnedSlice(allocator);
        try bindings.put(allocator, name, .{ .repeated = slice });
    }

    return try match_pattern(allocator, tail_pattern, node, literals, ellipsis, bindings);
}

fn collect_ellipsis_vars(
    allocator: std.mem.Allocator,
    template: Value,
    bindings: *const Bindings,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    switch (template) {
        .symbol => |s| {
            if (bindings.get(s)) |b| {
                if (b == .repeated) {
                    for (out.items) |existing| {
                        if (std.mem.eql(u8, existing, s)) return;
                    }
                    try out.append(allocator, s);
                }
            }
        },
        .pair => |p| {
            try collect_ellipsis_vars(allocator, p.car, bindings, out);
            try collect_ellipsis_vars(allocator, p.cdr, bindings, out);
        },
        else => {},
    }
}

fn expand_template(
    allocator: std.mem.Allocator,
    template: Value,
    ellipsis: []const u8,
    bindings: *const Bindings,
) ElzError!Value {
    switch (template) {
        .symbol => |s| {
            if (bindings.get(s)) |bound| {
                switch (bound) {
                    .single => |v| return try v.deep_clone(allocator),
                    .repeated => return ElzError.InvalidArgument,
                }
            }
            return Value{ .symbol = try allocator.dupe(u8, s) };
        },
        .pair => |p| {
            if (is_ellipsis_marker(p.cdr, ellipsis)) {
                const after = p.cdr.pair.cdr;
                const repeated_list = try expand_ellipsis(allocator, p.car, ellipsis, bindings);
                const tail = try expand_template(allocator, after, ellipsis, bindings);
                return try append_lists(allocator, repeated_list, tail);
            }
            const new_pair = try allocator.create(core.Pair);
            new_pair.* = .{
                .car = try expand_template(allocator, p.car, ellipsis, bindings),
                .cdr = try expand_template(allocator, p.cdr, ellipsis, bindings),
            };
            return Value{ .pair = new_pair };
        },
        else => return template.deep_clone(allocator),
    }
}

fn expand_ellipsis(
    allocator: std.mem.Allocator,
    sub_tmpl: Value,
    ellipsis: []const u8,
    bindings: *const Bindings,
) ElzError!Value {
    var ev_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ev_names.deinit(allocator);
    collect_ellipsis_vars(allocator, sub_tmpl, bindings, &ev_names) catch return ElzError.OutOfMemory;
    if (ev_names.items.len == 0) return ElzError.InvalidArgument;

    const count = blk: {
        const first = bindings.get(ev_names.items[0]).?.repeated.len;
        for (ev_names.items[1..]) |n| {
            if (bindings.get(n).?.repeated.len != first) return ElzError.InvalidArgument;
        }
        break :blk first;
    };

    var result_pairs: std.ArrayListUnmanaged(Value) = .empty;
    defer result_pairs.deinit(allocator);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var iter_bindings: Bindings = .empty;
        defer iter_bindings.deinit(allocator);
        var it = bindings.iterator();
        while (it.next()) |entry| {
            try iter_bindings.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        for (ev_names.items) |n| {
            const original = bindings.get(n).?;
            try iter_bindings.put(allocator, n, .{ .single = original.repeated[i] });
        }
        const expanded = try expand_template(allocator, sub_tmpl, ellipsis, &iter_bindings);
        try result_pairs.append(allocator, expanded);
    }

    var result: Value = .nil;
    var j: usize = result_pairs.items.len;
    while (j > 0) {
        j -= 1;
        const pair = try allocator.create(core.Pair);
        pair.* = .{ .car = result_pairs.items[j], .cdr = result };
        result = Value{ .pair = pair };
    }
    return result;
}

fn collect_introduced_identifiers(
    interp: *interpreter.Interpreter,
    allocator: std.mem.Allocator,
    template: Value,
    pattern_var_names: []const []const u8,
    def_env: *Environment,
    ellipsis: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) ElzError!void {
    switch (template) {
        .symbol => |s| {
            if (is_special_form_name(s)) return;
            // Do not hygiene-rename the ellipsis marker itself.
            if (ellipsis.len > 0 and std.mem.eql(u8, s, ellipsis)) return;
            for (pattern_var_names) |pv| {
                if (std.mem.eql(u8, pv, s)) return;
            }
            if (def_env.contains(s)) return;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, s)) return;
            }
            try out.append(allocator, s);
        },
        .pair => |p| {
            if (p.car.is_symbol("quote")) return;
            try collect_introduced_identifiers(interp, allocator, p.car, pattern_var_names, def_env, ellipsis, out);
            try collect_introduced_identifiers(interp, allocator, p.cdr, pattern_var_names, def_env, ellipsis, out);
        },
        else => {},
    }
}

fn fresh_hygiene_name(interp: *interpreter.Interpreter, allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    interp.gensym_counter += 1;
    return std.fmt.allocPrint(allocator, "{s}__h{d}", .{ base, interp.gensym_counter });
}

fn rename_template(
    allocator: std.mem.Allocator,
    template: Value,
    rename_map: *const std.StringHashMapUnmanaged([]const u8),
) ElzError!Value {
    switch (template) {
        .symbol => |s| {
            if (rename_map.get(s)) |renamed| {
                return Value{ .symbol = try allocator.dupe(u8, renamed) };
            }
            return Value{ .symbol = try allocator.dupe(u8, s) };
        },
        .pair => |p| {
            if (p.car.is_symbol("quote")) {
                return template.deep_clone(allocator);
            }
            const new_pair = try allocator.create(core.Pair);
            new_pair.* = .{
                .car = try rename_template(allocator, p.car, rename_map),
                .cdr = try rename_template(allocator, p.cdr, rename_map),
            };
            return Value{ .pair = new_pair };
        },
        else => return template.deep_clone(allocator),
    }
}

fn append_lists(allocator: std.mem.Allocator, head: Value, tail: Value) ElzError!Value {
    if (head == .nil) return tail;
    if (head != .pair) return ElzError.InvalidArgument;
    const new_pair = try allocator.create(core.Pair);
    new_pair.* = .{
        .car = head.pair.car,
        .cdr = try append_lists(allocator, head.pair.cdr, tail),
    };
    return Value{ .pair = new_pair };
}

pub fn expandSyntaxRules(
    interp: *interpreter.Interpreter,
    sr: *core.SyntaxRulesMacro,
    rest: Value,
    env: *Environment,
    fuel: *u64,
) ElzError!Value {
    _ = fuel;
    const allocator = env.allocator;
    const head_pair = try allocator.create(core.Pair);
    head_pair.* = .{ .car = Value{ .symbol = try allocator.dupe(u8, sr.name) }, .cdr = rest };
    const input = Value{ .pair = head_pair };

    for (sr.rules) |rule| {
        var bindings: Bindings = .empty;
        defer bindings.deinit(allocator);

        const matched = match_pattern(allocator, rule.pattern, input, sr.literals, sr.ellipsis, &bindings) catch return ElzError.OutOfMemory;
        if (matched) {
            var pattern_var_names: std.ArrayListUnmanaged([]const u8) = .empty;
            defer pattern_var_names.deinit(allocator);
            try collect_pattern_vars(allocator, rule.pattern, sr.literals, sr.ellipsis, &pattern_var_names);

            var introduced: std.ArrayListUnmanaged([]const u8) = .empty;
            defer introduced.deinit(allocator);
            try collect_introduced_identifiers(interp, allocator, rule.template, pattern_var_names.items, sr.env, sr.ellipsis, &introduced);

            var rename_map: std.StringHashMapUnmanaged([]const u8) = .empty;
            defer rename_map.deinit(allocator);
            for (introduced.items) |name| {
                const fresh = fresh_hygiene_name(interp, allocator, name) catch return ElzError.OutOfMemory;
                try rename_map.put(allocator, name, fresh);
            }

            const renamed_template = try rename_template(allocator, rule.template, &rename_map);
            return try expand_template(allocator, renamed_template, sr.ellipsis, &bindings);
        }
    }

    interp.last_error_message = std.fmt.allocPrint(allocator, "No matching syntax-rules pattern for '{s}'.", .{sr.name}) catch null;
    return ElzError.InvalidArgument;
}

fn evalLetSyntax(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) ElzError!Value {
    if (rest != .pair) return ElzError.InvalidArgument;
    const bindings_list = rest.pair.car;
    const body = rest.pair.cdr;

    // When there are macro bindings, scope them to a child environment so they do not
    // leak into the surrounding scope after the let-syntax form completes. When the
    // binding list is empty the outer env is used directly so that internal `define`
    // forms remain visible to the enclosing body (R5RS/R7RS body splicing semantics).
    const body_env = if (bindings_list != .nil)
        try core.Environment.init(env.allocator, env)
    else
        env;

    var node = bindings_list;
    while (node != .nil) {
        if (node != .pair) return ElzError.InvalidArgument;
        const binding = node.pair.car;
        if (binding != .pair) return ElzError.InvalidArgument;
        const name_val = binding.pair.car;
        if (name_val != .symbol) return ElzError.InvalidArgument;
        const tail = binding.pair.cdr;
        if (tail != .pair) return ElzError.InvalidArgument;
        const transformer_form = tail.pair.car;
        if (tail.pair.cdr != .nil) return ElzError.InvalidArgument;
        if (transformer_form != .pair) return ElzError.InvalidArgument;
        if (!transformer_form.pair.car.is_symbol("syntax-rules")) return ElzError.InvalidArgument;

        const sr = try buildSyntaxRules(body_env, name_val.symbol, transformer_form.pair.cdr);
        try body_env.set(interp, name_val.symbol, Value{ .syntax_rules = sr });
        node = node.pair.cdr;
    }

    if (body == .nil) return Value.unspecified;
    var body_node = body;
    var last: Value = .unspecified;
    while (body_node != .nil) {
        if (body_node != .pair) return ElzError.InvalidArgument;
        last = try eval(interp, &body_node.pair.car, body_env, fuel);
        body_node = body_node.pair.cdr;
    }
    return last;
}

fn evalDefineSyntax(interp: *interpreter.Interpreter, rest: Value, env: *Environment) ElzError!Value {
    if (rest != .pair) return ElzError.InvalidArgument;
    const name_val = rest.pair.car;
    if (name_val != .symbol) return ElzError.InvalidArgument;
    const tail = rest.pair.cdr;
    if (tail != .pair) return ElzError.InvalidArgument;
    const transformer_form = tail.pair.car;
    if (tail.pair.cdr != .nil) return ElzError.InvalidArgument;

    if (transformer_form != .pair) return ElzError.InvalidArgument;
    if (!transformer_form.pair.car.is_symbol("syntax-rules")) return ElzError.InvalidArgument;

    const sr = try buildSyntaxRules(env, name_val.symbol, transformer_form.pair.cdr);
    try env.set(interp, name_val.symbol, Value{ .syntax_rules = sr });
    return Value.unspecified;
}

fn buildSyntaxRules(env: *Environment, name: []const u8, body: Value) ElzError!*core.SyntaxRulesMacro {
    if (body != .pair) return ElzError.InvalidArgument;

    // Detect the R7RS extended form: (syntax-rules <ellipsis-sym> (literal...) rule...)
    // If body.car is a symbol rather than a list, it is the custom ellipsis identifier.
    var cursor = body;
    const ellipsis_raw: []const u8 = if (cursor.pair.car == .symbol) blk: {
        const e = cursor.pair.car.symbol;
        cursor = cursor.pair.cdr;
        if (cursor != .pair) return ElzError.InvalidArgument;
        break :blk e;
    } else "...";

    // When using the default "..." ellipsis, check whether it has been rebound in the
    // enclosing scope. If so, treat "..." as a regular identifier inside this macro.
    const ellipsis: []const u8 = if (std.mem.eql(u8, ellipsis_raw, "...") and env.contains("..."))
        ""
    else
        ellipsis_raw;

    const literals_val = cursor.pair.car;
    var rules_node = cursor.pair.cdr;

    var lit_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lit_names.deinit(env.allocator);
    var lit_node = literals_val;
    while (lit_node != .nil) {
        if (lit_node != .pair) return ElzError.InvalidArgument;
        const head = lit_node.pair.car;
        if (head != .symbol) return ElzError.InvalidArgument;
        try lit_names.append(env.allocator, try env.allocator.dupe(u8, head.symbol));
        lit_node = lit_node.pair.cdr;
    }

    var rules_list: std.ArrayListUnmanaged(core.SyntaxRule) = .empty;
    defer rules_list.deinit(env.allocator);
    while (rules_node != .nil) {
        if (rules_node != .pair) return ElzError.InvalidArgument;
        const rule_form = rules_node.pair.car;
        if (rule_form != .pair) return ElzError.InvalidArgument;
        const pattern = rule_form.pair.car;
        const rtail = rule_form.pair.cdr;
        if (rtail != .pair) return ElzError.InvalidArgument;
        const template = rtail.pair.car;
        if (rtail.pair.cdr != .nil) return ElzError.InvalidArgument;
        try rules_list.append(env.allocator, .{ .pattern = pattern, .template = template });
        rules_node = rules_node.pair.cdr;
    }

    const sr = try env.allocator.create(core.SyntaxRulesMacro);
    sr.* = .{
        .name = try env.allocator.dupe(u8, name),
        .literals = try lit_names.toOwnedSlice(env.allocator),
        .rules = try rules_list.toOwnedSlice(env.allocator),
        .env = env,
        .ellipsis = try env.allocator.dupe(u8, ellipsis),
    };
    return sr;
}

fn evalDelay(env: *Environment, rest: Value) ElzError!Value {
    if (rest != .pair) return ElzError.InvalidArgument;
    const expr = rest.pair.car;
    if (rest.pair.cdr != .nil) return ElzError.InvalidArgument;

    const promise = env.allocator.create(core.Promise) catch return ElzError.OutOfMemory;
    promise.* = .{
        .expr = expr,
        .env = env,
        .forced = false,
        .result = .unspecified,
    };
    return Value{ .promise = promise };
}

// ============================================================================
// Named let expansion (returns expanded AST for CPS trampoline)
// ============================================================================

fn expandNamedLetAST(
    interp: *interpreter.Interpreter,
    name: []const u8,
    rest: Value,
    env: *Environment,
) ElzError!Value {
    if (rest != .pair) return ElzError.InvalidArgument;
    const bindings_list = rest.pair.car;
    const body = rest.pair.cdr;
    if (body == .nil) return ElzError.InvalidArgument;

    const allocator = env.allocator;

    var var_list: Value = .nil;
    var var_tail: ?*core.Pair = null;
    var init_list: Value = .nil;
    var init_tail: ?*core.Pair = null;

    var node = bindings_list;
    while (node != .nil) {
        if (node != .pair) return ElzError.InvalidArgument;
        const binding = node.pair.car;
        if (binding != .pair) return ElzError.InvalidArgument;
        const var_val = binding.pair.car;
        if (var_val != .symbol) return ElzError.InvalidArgument;
        const init_tail_pair = binding.pair.cdr;
        if (init_tail_pair != .pair or init_tail_pair.pair.cdr != .nil) return ElzError.InvalidArgument;
        const init_val = init_tail_pair.pair.car;

        const var_pair = try allocator.create(core.Pair);
        var_pair.* = .{ .car = var_val, .cdr = .nil };
        if (var_tail) |t| {
            t.cdr = Value{ .pair = var_pair };
        } else {
            var_list = Value{ .pair = var_pair };
        }
        var_tail = var_pair;

        const init_pair = try allocator.create(core.Pair);
        init_pair.* = .{ .car = init_val, .cdr = .nil };
        if (init_tail) |t| {
            t.cdr = Value{ .pair = init_pair };
        } else {
            init_list = Value{ .pair = init_pair };
        }
        init_tail = init_pair;

        node = node.pair.cdr;
    }

    const lambda_after_params = try allocator.create(core.Pair);
    lambda_after_params.* = .{ .car = var_list, .cdr = body };
    const lambda_form_pair = try allocator.create(core.Pair);
    lambda_form_pair.* = .{ .car = Value{ .symbol = "lambda" }, .cdr = Value{ .pair = lambda_after_params } };
    const lambda_form = Value{ .pair = lambda_form_pair };

    const binding_after_name = try allocator.create(core.Pair);
    binding_after_name.* = .{ .car = lambda_form, .cdr = .nil };
    const binding_pair = try allocator.create(core.Pair);
    binding_pair.* = .{ .car = Value{ .symbol = try allocator.dupe(u8, name) }, .cdr = Value{ .pair = binding_after_name } };
    const single_binding_pair = try allocator.create(core.Pair);
    single_binding_pair.* = .{ .car = Value{ .pair = binding_pair }, .cdr = .nil };
    const bindings_value = Value{ .pair = single_binding_pair };

    const call_pair = try allocator.create(core.Pair);
    call_pair.* = .{ .car = Value{ .symbol = try allocator.dupe(u8, name) }, .cdr = init_list };
    const call_value = Value{ .pair = call_pair };

    const letrec_after_bindings = try allocator.create(core.Pair);
    letrec_after_bindings.* = .{ .car = call_value, .cdr = .nil };
    const letrec_bindings_and_body = try allocator.create(core.Pair);
    letrec_bindings_and_body.* = .{ .car = bindings_value, .cdr = Value{ .pair = letrec_after_bindings } };
    const letrec_form_pair = try allocator.create(core.Pair);
    letrec_form_pair.* = .{ .car = Value{ .symbol = "letrec" }, .cdr = Value{ .pair = letrec_bindings_and_body } };

    _ = interp;
    return Value{ .pair = letrec_form_pair };
}

// ============================================================================
// evalDo: direct-style with full iteration, returns last result
// ============================================================================

fn evalDo(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) ElzError!Value {
    if (rest != .pair) return ElzError.InvalidArgument;
    const bindings_pair = rest.pair;
    const bindings_list = bindings_pair.car;
    const after_bindings = bindings_pair.cdr;
    if (after_bindings != .pair) return ElzError.InvalidArgument;
    const test_clause = after_bindings.pair.car;
    const body = after_bindings.pair.cdr;

    if (test_clause != .pair) return ElzError.InvalidArgument;
    const test_expr = test_clause.pair.car;
    const result_exprs = test_clause.pair.cdr;

    var var_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer var_names.deinit(env.allocator);
    var init_exprs: std.ArrayListUnmanaged(Value) = .empty;
    defer init_exprs.deinit(env.allocator);
    var step_exprs: std.ArrayListUnmanaged(?Value) = .empty;
    defer step_exprs.deinit(env.allocator);

    var binding_node = bindings_list;
    while (binding_node != .nil) {
        if (binding_node != .pair) return ElzError.InvalidArgument;
        const binding = binding_node.pair.car;
        if (binding != .pair) return ElzError.InvalidArgument;
        const name_val = binding.pair.car;
        if (name_val != .symbol) return ElzError.InvalidArgument;
        const name_tail = binding.pair.cdr;
        if (name_tail != .pair) return ElzError.InvalidArgument;
        const init_val = name_tail.pair.car;
        const init_tail = name_tail.pair.cdr;

        var step_val: ?Value = null;
        if (init_tail == .pair) {
            step_val = init_tail.pair.car;
            if (init_tail.pair.cdr != .nil) return ElzError.InvalidArgument;
        } else if (init_tail != .nil) {
            return ElzError.InvalidArgument;
        }

        try var_names.append(env.allocator, name_val.symbol);
        try init_exprs.append(env.allocator, init_val);
        try step_exprs.append(env.allocator, step_val);

        binding_node = binding_node.pair.cdr;
    }

    const loop_env = try Environment.init(env.allocator, env);
    for (var_names.items, 0..) |name, i| {
        var init_expr = init_exprs.items[i];
        const v = try eval(interp, &init_expr, env, fuel);
        try loop_env.set(interp, name, v);
    }

    while (true) {
        var test_node = test_expr;
        const test_result = try eval(interp, &test_node, loop_env, fuel);
        const truthy = !(test_result == .boolean and test_result.boolean == false);
        if (truthy) {
            if (result_exprs == .nil) return Value.unspecified;
            var node = result_exprs;
            var last_result: Value = .unspecified;
            while (node != .nil) {
                if (node != .pair) return ElzError.InvalidArgument;
                last_result = try eval(interp, &node.pair.car, loop_env, fuel);
                node = node.pair.cdr;
            }
            return last_result;
        }

        var body_node = body;
        while (body_node != .nil) {
            if (body_node != .pair) return ElzError.InvalidArgument;
            _ = try eval(interp, &body_node.pair.car, loop_env, fuel);
            body_node = body_node.pair.cdr;
        }

        var new_values: std.ArrayListUnmanaged(Value) = .empty;
        defer new_values.deinit(env.allocator);
        for (step_exprs.items, 0..) |step_opt, i| {
            if (step_opt) |step| {
                var step_node = step;
                const v = try eval(interp, &step_node, loop_env, fuel);
                try new_values.append(env.allocator, v);
            } else {
                const v = try loop_env.get(var_names.items[i], interp);
                try new_values.append(env.allocator, v);
            }
        }
        for (var_names.items, 0..) |name, i| {
            try loop_env.update(interp, name, new_values.items[i]);
        }
    }
}

// ============================================================================
// bindClosureArgs: handle variadic closures
// ============================================================================

pub fn bindClosureArgs(
    interp: *interpreter.Interpreter,
    c: *UserDefinedProc,
    arg_vals: core.ValueList,
    env: *Environment,
) ElzError!*Environment {
    const fixed_count = c.params.items.len;
    if (c.rest_param == null) {
        if (fixed_count != arg_vals.items.len) return ElzError.WrongArgumentCount;
    } else {
        if (arg_vals.items.len < fixed_count) return ElzError.WrongArgumentCount;
    }

    const call_env = try Environment.init(env.allocator, c.env);
    for (c.params.items, 0..) |param, i| {
        try call_env.set(interp, param.symbol, arg_vals.items[i]);
    }
    if (c.rest_param) |rest_name| {
        var rest_list: Value = .nil;
        var i: usize = arg_vals.items.len;
        while (i > fixed_count) {
            i -= 1;
            const pair = try env.allocator.create(core.Pair);
            pair.* = .{ .car = arg_vals.items[i], .cdr = rest_list };
            rest_list = Value{ .pair = pair };
        }
        try call_env.set(interp, rest_name, rest_list);
    }
    return call_env;
}

// ============================================================================
// CPS evaluator core
// ============================================================================

pub fn evalStep(interp: *interpreter.Interpreter, ast: Value, env: *Environment, k: *core.Cont, fuel: *u64) ElzError!core.EvalStep {
    switch (ast) {
        .number, .exact_integer, .rational, .complex, .boolean, .character, .nil, .closure, .vm_closure, .macro, .procedure, .cont_aware_procedure, .continuation, .foreign_procedure, .opaque_pointer, .cell, .module, .vector, .hash_map, .port, .unspecified, .promise, .multi_values, .syntax_rules => {
            return .{ .apply = .{ .k = k, .val = ast } };
        },
        .string => |s| {
            return .{ .apply = .{ .k = k, .val = Value{ .string = try env.allocator.dupe(u8, s) } } };
        },
        .symbol => |sym| {
            const val = try env.get(sym, interp);
            return .{ .apply = .{ .k = k, .val = val } };
        },
        .pair => |p| {
            const first = p.car;
            const rest = p.cdr;

            // Check for syntax_rules macros first (before special form checks)
            if (first == .symbol) {
                const saved_msg = interp.last_error_message;
                if (env.get(first.symbol, interp)) |looked_up| {
                    if (looked_up == .syntax_rules) {
                        const expanded = try expandSyntaxRules(interp, looked_up.syntax_rules, rest, env, fuel);
                        return .{ .eval = .{ .ast = expanded, .env = env, .k = k } };
                    }
                    if (looked_up == .macro) {
                        const expansion = try expandMacro(interp, looked_up.macro, rest, env, fuel);
                        return .{ .eval = .{ .ast = expansion, .env = env, .k = k } };
                    }
                } else |_| {
                    interp.last_error_message = saved_msg;
                }
            }

            // Special forms
            if (first.is_symbol("quote")) {
                const v = try evalQuote(rest, env);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("quasiquote")) {
                const v = try evalQuasiquote(interp, rest, env, fuel);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("import")) {
                const v = try evalImport(interp, rest, env, fuel);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("lambda")) {
                const v = try evalLambda(rest, env);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("define-macro")) {
                const v = try evalDefineMacro(interp, rest, env);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("define-syntax")) {
                const v = try evalDefineSyntax(interp, rest, env);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("let-syntax") or first.is_symbol("letrec-syntax")) {
                const v = try evalLetSyntax(interp, rest, env, fuel);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("delay")) {
                const v = try evalDelay(env, rest);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("do")) {
                const v = try evalDo(interp, rest, env, fuel);
                return .{ .apply = .{ .k = k, .val = v } };
            }
            if (first.is_symbol("if")) {
                const p_test = switch (rest) {
                    .pair => |pr| pr,
                    else => return ElzError.IfInvalidArguments,
                };
                const p_cons = switch (p_test.cdr) {
                    .pair => |pr| pr,
                    else => return ElzError.IfInvalidArguments,
                };
                const consequent = p_cons.car;
                const alternative = switch (p_cons.cdr) {
                    .nil => Value.unspecified,
                    .pair => |alt_p| blk: {
                        if (alt_p.cdr != .nil) return ElzError.IfInvalidArguments;
                        break :blk alt_p.car;
                    },
                    else => return ElzError.IfInvalidArguments,
                };
                const next_k = try allocCont(interp, .{ .if_branch = .{ .consequent = consequent, .alternative = alternative, .env = env } }, k);
                return .{ .eval = .{ .ast = p_test.car, .env = env, .k = next_k } };
            }
            if (first.is_symbol("cond")) {
                return try evalCondStep(interp, rest, env, k);
            }
            if (first.is_symbol("case")) {
                return try evalCaseStep(interp, rest, env, k, fuel);
            }
            if (first.is_symbol("and")) {
                if (rest == .nil) return .{ .apply = .{ .k = k, .val = Value{ .boolean = true } } };
                const rp = rest.pair;
                if (rp.cdr == .nil) {
                    return .{ .eval = .{ .ast = rp.car, .env = env, .k = k } };
                }
                const next_k = try allocCont(interp, .{ .and_rest = .{ .rest = rp.cdr, .env = env } }, k);
                return .{ .eval = .{ .ast = rp.car, .env = env, .k = next_k } };
            }
            if (first.is_symbol("or")) {
                if (rest == .nil) return .{ .apply = .{ .k = k, .val = Value{ .boolean = false } } };
                const rp = rest.pair;
                if (rp.cdr == .nil) {
                    return .{ .eval = .{ .ast = rp.car, .env = env, .k = k } };
                }
                const next_k = try allocCont(interp, .{ .or_rest = .{ .rest = rp.cdr, .env = env } }, k);
                return .{ .eval = .{ .ast = rp.car, .env = env, .k = next_k } };
            }
            if (first.is_symbol("define")) {
                const p_name = switch (rest) {
                    .pair => |pr| pr,
                    else => return ElzError.DefineInvalidArguments,
                };
                const name_or_sig = p_name.car;
                const body = p_name.cdr;
                switch (name_or_sig) {
                    .symbol => |sym| {
                        const p_expr = switch (body) {
                            .pair => |pr| pr,
                            else => return ElzError.DefineInvalidArguments,
                        };
                        if (p_expr.cdr != .nil) return ElzError.DefineInvalidArguments;
                        const next_k = try allocCont(interp, .{ .define_bind = .{ .name = sym, .env = env } }, k);
                        return .{ .eval = .{ .ast = p_expr.car, .env = env, .k = next_k } };
                    },
                    .pair => |sig_pair| {
                        const fn_name_val = sig_pair.car;
                        const fn_name = if (fn_name_val == .symbol) fn_name_val.symbol else return ElzError.DefineInvalidSymbol;
                        const params = sig_pair.cdr;
                        var params_list_gc = core.ValueList.init(env.allocator);
                        var rest_param_name: ?[]const u8 = null;
                        var current_param = params;
                        walk: while (true) {
                            switch (current_param) {
                                .pair => |pp| {
                                    if (pp.car != .symbol) return ElzError.LambdaInvalidParams;
                                    try params_list_gc.append(pp.car);
                                    current_param = pp.cdr;
                                },
                                .nil => break :walk,
                                .symbol => |s| {
                                    rest_param_name = try env.allocator.dupe(u8, s);
                                    break :walk;
                                },
                                else => return ElzError.LambdaInvalidParams,
                            }
                        }
                        const proc = try env.allocator.create(UserDefinedProc);
                        proc.* = .{
                            .params = params_list_gc,
                            .rest_param = rest_param_name,
                            .body = try body.deep_clone(env.allocator),
                            .env = env,
                        };
                        const closure = Value{ .closure = proc };
                        try env.set(interp, fn_name, closure);
                        return .{ .apply = .{ .k = k, .val = closure } };
                    },
                    else => return ElzError.DefineInvalidSymbol,
                }
            }
            if (first.is_symbol("set!")) {
                const p_sym = switch (rest) {
                    .pair => |pr| pr,
                    else => return ElzError.SetInvalidArguments,
                };
                const symbol = p_sym.car;
                if (symbol != .symbol) return ElzError.SetInvalidSymbol;
                const p_expr = switch (p_sym.cdr) {
                    .pair => |pr| pr,
                    else => return ElzError.SetInvalidArguments,
                };
                if (p_expr.cdr != .nil) return ElzError.SetInvalidArguments;
                const next_k = try allocCont(interp, .{ .set_bind = .{ .name = symbol.symbol, .env = env } }, k);
                return .{ .eval = .{ .ast = p_expr.car, .env = env, .k = next_k } };
            }
            if (first.is_symbol("begin")) {
                if (rest == .nil) return .{ .apply = .{ .k = k, .val = Value.nil } };
                return evalBodyStep(interp, rest, env, k);
            }
            if (first.is_symbol("let") or first.is_symbol("let*")) {
                return try evalLetStep(interp, first.is_symbol("let*"), rest, env, k, fuel);
            }
            if (first.is_symbol("letrec")) {
                const result = try evalLetRec(interp, ast, env, fuel);
                return .{ .apply = .{ .k = k, .val = result } };
            }
            if (first.is_symbol("try")) {
                const result = try evalTry(interp, rest, env, fuel);
                return .{ .apply = .{ .k = k, .val = result } };
            }

            // Function application: eval operator, then operands
            const next_k = try allocCont(interp, .{ .eval_rator = .{ .rand_list = rest, .env = env } }, k);
            return .{ .eval = .{ .ast = first, .env = env, .k = next_k } };
        },
    }
}

pub fn evalBodyStep(interp: *interpreter.Interpreter, body: Value, env: *Environment, k: *core.Cont) ElzError!core.EvalStep {
    if (body == .nil) return .{ .apply = .{ .k = k, .val = .nil } };
    const p = body.pair;
    if (p.cdr == .nil) {
        return .{ .eval = .{ .ast = p.car, .env = env, .k = k } };
    }
    const next_k = try allocCont(interp, .{ .begin_rest = .{ .rest = p.cdr, .env = env } }, k);
    return .{ .eval = .{ .ast = p.car, .env = env, .k = next_k } };
}

fn evalLetStep(interp: *interpreter.Interpreter, is_star: bool, rest: Value, env: *Environment, k: *core.Cont, fuel: *u64) ElzError!core.EvalStep {
    const p_bindings = switch (rest) {
        .pair => |pr| pr,
        else => return ElzError.InvalidArgument,
    };

    // Named let: (let name ((var init) ...) body...)
    if (!is_star and p_bindings.car == .symbol) {
        const name = p_bindings.car.symbol;
        const expanded = try expandNamedLetAST(interp, name, p_bindings.cdr, env);
        return .{ .eval = .{ .ast = expanded, .env = env, .k = k } };
    }

    const bindings_list = p_bindings.car;
    const body = p_bindings.cdr;
    const new_env = try Environment.init(env.allocator, env);

    if (bindings_list == .nil) {
        if (body == .nil) return .{ .apply = .{ .k = k, .val = Value.nil } };
        return evalBodyStep(interp, body, new_env, k);
    }

    // For let* with no bindings remaining, just use evalBodyStep
    // For regular let (not star), we evaluate all inits in outer env.
    // The CPS let_bind frame tracks this.
    const first_binding_p = bindings_list.pair;
    const first_binding = first_binding_p.car;
    const var_p = switch (first_binding) {
        .pair => |pr| pr,
        else => return ElzError.InvalidArgument,
    };
    const var_sym = var_p.car;
    if (var_sym != .symbol) return ElzError.InvalidArgument;
    const init_p = switch (var_p.cdr) {
        .pair => |pr| pr,
        else => return ElzError.InvalidArgument,
    };
    const init_expr = init_p.car;
    const eval_env = if (is_star) new_env else env;

    _ = fuel;
    const next_k = try allocCont(interp, .{ .let_bind = .{
        .name = var_sym.symbol,
        .remaining = first_binding_p.cdr,
        .body = body,
        .new_env = new_env,
        .outer_env = env,
        .is_star = is_star,
    } }, k);
    return .{ .eval = .{ .ast = init_expr, .env = eval_env, .k = next_k } };
}

fn evalCondStep(interp: *interpreter.Interpreter, rest: Value, env: *Environment, k: *core.Cont) ElzError!core.EvalStep {
    const current_clause_node = rest;
    if (current_clause_node != .nil) {
        const clause_pair = switch (current_clause_node) {
            .pair => |cp| cp,
            else => return ElzError.InvalidArgument,
        };
        const clause = clause_pair.car;
        const clause_p = switch (clause) {
            .pair => |cp| cp,
            else => return ElzError.InvalidArgument,
        };
        const test_expr = clause_p.car;
        if (test_expr.is_symbol("else")) {
            const body = clause_p.cdr;
            if (body == .nil) return .{ .apply = .{ .k = k, .val = Value.nil } };
            return evalBodyStep(interp, body, env, k);
        }
        const rest_clauses = clause_pair.cdr;
        const cond_sym = Value{ .symbol = "cond" };
        const alt_pair = try env.allocator.create(core.Pair);
        alt_pair.* = .{ .car = cond_sym, .cdr = rest_clauses };
        const alt_form = Value{ .pair = alt_pair };

        const body = clause_p.cdr;
        if (body == .nil) {
            const next_k = try allocCont(interp, .{ .or_rest = .{ .rest = blk: {
                const p = try env.allocator.create(core.Pair);
                p.* = .{ .car = alt_form, .cdr = Value.nil };
                break :blk Value{ .pair = p };
            }, .env = env } }, k);
            return .{ .eval = .{ .ast = test_expr, .env = env, .k = next_k } };
        }

        // Detect the (test => proc) arrow clause form.
        // Only use arrow syntax when "=>" is not lexically rebound (R5RS §4.2.1).
        if (body == .pair and body.pair.car.is_symbol("=>") and !env.contains("=>")) {
            const arrow_rest = body.pair.cdr;
            if (arrow_rest != .pair) return ElzError.InvalidArgument;
            const proc_expr = arrow_rest.pair.car;
            const next_k = try allocCont(interp, .{ .cond_arrow_test_done = .{
                .proc_expr = proc_expr,
                .alternative = alt_form,
                .env = env,
            } }, k);
            return .{ .eval = .{ .ast = test_expr, .env = env, .k = next_k } };
        }

        const begin_sym = Value{ .symbol = "begin" };
        const begin_pair = try env.allocator.create(core.Pair);
        begin_pair.* = .{ .car = begin_sym, .cdr = body };
        const consequent = Value{ .pair = begin_pair };

        const next_k = try allocCont(interp, .{ .if_branch = .{ .consequent = consequent, .alternative = alt_form, .env = env } }, k);
        return .{ .eval = .{ .ast = test_expr, .env = env, .k = next_k } };
    }
    return .{ .apply = .{ .k = k, .val = Value.nil } };
}

fn evalCaseStep(interp: *interpreter.Interpreter, rest: Value, env: *Environment, k: *core.Cont, fuel: *u64) ElzError!core.EvalStep {
    const rest_pair = switch (rest) {
        .pair => |p| p,
        else => return ElzError.InvalidArgument,
    };
    var key_expr = rest_pair.car;
    const key = try eval(interp, &key_expr, env, fuel);

    var current_clause_node = rest_pair.cdr;
    while (current_clause_node != .nil) {
        const clause_pair = switch (current_clause_node) {
            .pair => |cp| cp,
            else => return ElzError.InvalidArgument,
        };
        const clause = clause_pair.car;
        const clause_p = switch (clause) {
            .pair => |cp| cp,
            else => return ElzError.InvalidArgument,
        };
        const datums = clause_p.car;
        const body = clause_p.cdr;

        if (datums.is_symbol("else")) {
            if (body == .nil) return .{ .apply = .{ .k = k, .val = Value.nil } };
            return evalBodyStep(interp, body, env, k);
        }

        var found = false;
        var datum_node = datums;
        while (datum_node != .nil) {
            const datum_pair = switch (datum_node) {
                .pair => |dp| dp,
                else => return ElzError.InvalidArgument,
            };
            if (is_eqv(key, datum_pair.car)) {
                found = true;
                break;
            }
            datum_node = datum_pair.cdr;
        }
        if (found) {
            if (body == .nil) return .{ .apply = .{ .k = k, .val = Value.nil } };
            return evalBodyStep(interp, body, env, k);
        }
        current_clause_node = clause_pair.cdr;
    }
    return .{ .apply = .{ .k = k, .val = Value.nil } };
}

// ============================================================================
// applyK: dispatch on continuation frame
// ============================================================================

pub fn applyK(interp: *interpreter.Interpreter, k: *core.Cont, val: Value, fuel: *u64) ElzError!core.EvalStep {
    switch (k.frame) {
        .halt => return .{ .done = val },
        .eval_rator => |er| {
            const proc = val;
            if (er.rand_list == .nil) {
                const empty = core.ValueList.init(er.env.allocator);
                return try applyProc(interp, proc, empty, er.env, k.next.?, fuel);
            }
            const rp = er.rand_list.pair;
            const done = core.ValueList.init(er.env.allocator);
            const next_k = try allocCont(interp, .{ .eval_rands = .{
                .proc = proc,
                .done = done,
                .rest = rp.cdr,
                .env = er.env,
            } }, k.next.?);
            return .{ .eval = .{ .ast = rp.car, .env = er.env, .k = next_k } };
        },
        .eval_rands => |er| {
            // Build a new args list from the existing done items plus val, rather than
            // mutating er.done in-place. Mutation breaks continuation re-entry because
            // the captured frame would have stale accumulated args on the second call.
            var new_done = core.ValueList.init(er.env.allocator);
            for (er.done.items) |v| try new_done.append(v);
            try new_done.append(val);
            if (er.rest == .nil) {
                return try applyProc(interp, er.proc, new_done, er.env, k.next.?, fuel);
            }
            const rp = er.rest.pair;
            const next_k = try allocCont(interp, .{ .eval_rands = .{
                .proc = er.proc,
                .done = new_done,
                .rest = rp.cdr,
                .env = er.env,
            } }, k.next.?);
            return .{ .eval = .{ .ast = rp.car, .env = er.env, .k = next_k } };
        },
        .if_branch => |ib| {
            const branch = if (isTruthy(val)) ib.consequent else ib.alternative;
            return .{ .eval = .{ .ast = branch, .env = ib.env, .k = k.next.? } };
        },
        .begin_rest => |br| {
            return try evalBodyStep(interp, br.rest, br.env, k.next.?);
        },
        .define_bind => |db| {
            try db.env.set(interp, db.name, val);
            return .{ .apply = .{ .k = k.next.?, .val = val } };
        },
        .set_bind => |sb| {
            try sb.env.update(interp, sb.name, val);
            return .{ .apply = .{ .k = k.next.?, .val = Value.nil } };
        },
        .and_rest => |ar| {
            if (!isTruthy(val)) return .{ .apply = .{ .k = k.next.?, .val = val } };
            if (ar.rest == .nil) return .{ .apply = .{ .k = k.next.?, .val = val } };
            const rp = ar.rest.pair;
            if (rp.cdr == .nil) {
                return .{ .eval = .{ .ast = rp.car, .env = ar.env, .k = k.next.? } };
            }
            const next_k = try allocCont(interp, .{ .and_rest = .{ .rest = rp.cdr, .env = ar.env } }, k.next.?);
            return .{ .eval = .{ .ast = rp.car, .env = ar.env, .k = next_k } };
        },
        .or_rest => |orr| {
            if (isTruthy(val)) return .{ .apply = .{ .k = k.next.?, .val = val } };
            if (orr.rest == .nil) return .{ .apply = .{ .k = k.next.?, .val = val } };
            const rp = orr.rest.pair;
            if (rp.cdr == .nil) {
                return .{ .eval = .{ .ast = rp.car, .env = orr.env, .k = k.next.? } };
            }
            const next_k = try allocCont(interp, .{ .or_rest = .{ .rest = rp.cdr, .env = orr.env } }, k.next.?);
            return .{ .eval = .{ .ast = rp.car, .env = orr.env, .k = next_k } };
        },
        .let_bind => |lb| {
            try lb.new_env.set(interp, lb.name, val);
            if (lb.remaining == .nil) {
                if (lb.body == .nil) return .{ .apply = .{ .k = k.next.?, .val = Value.nil } };
                return evalBodyStep(interp, lb.body, lb.new_env, k.next.?);
            }
            const rb_p = lb.remaining.pair;
            const binding = rb_p.car;
            const var_p = switch (binding) {
                .pair => |pr| pr,
                else => return ElzError.InvalidArgument,
            };
            const var_sym = var_p.car;
            if (var_sym != .symbol) return ElzError.InvalidArgument;
            const init_p = switch (var_p.cdr) {
                .pair => |pr| pr,
                else => return ElzError.InvalidArgument,
            };
            const init_expr = init_p.car;
            const eval_env = if (lb.is_star) lb.new_env else lb.outer_env;
            const next_k = try allocCont(interp, .{ .let_bind = .{
                .name = var_sym.symbol,
                .remaining = rb_p.cdr,
                .body = lb.body,
                .new_env = lb.new_env,
                .outer_env = lb.outer_env,
                .is_star = lb.is_star,
            } }, k.next.?);
            return .{ .eval = .{ .ast = init_expr, .env = eval_env, .k = next_k } };
        },
        .dyn_wind_before_done => |dw| {
            dw.winder.next = interp.winders;
            interp.winders = dw.winder;
            const no_args = core.ValueList.init(interp.allocator);
            return try applyProc(interp, dw.thunk, no_args, interp.root_env, k.next.?, fuel);
        },
        .dyn_wind_thunk_done => |dt| {
            interp.winders = dt.outer_winders;
            const after_k = try allocCont(interp, .{ .dyn_wind_after_done = .{ .thunk_result = val } }, k.next.?);
            const no_args = core.ValueList.init(interp.allocator);
            return try applyProc(interp, dt.after_proc, no_args, interp.root_env, after_k, fuel);
        },
        .dyn_wind_after_done => |da| {
            return .{ .apply = .{ .k = k.next.?, .val = da.thunk_result } };
        },
        .cond_arrow_test_done => |ca| {
            if (!isTruthy(val)) {
                return .{ .eval = .{ .ast = ca.alternative, .env = ca.env, .k = k.next.? } };
            }
            const next_k = try allocCont(interp, .{ .cond_arrow_proc_done = .{ .test_val = val, .env = ca.env } }, k.next.?);
            return .{ .eval = .{ .ast = ca.proc_expr, .env = ca.env, .k = next_k } };
        },
        .cond_arrow_proc_done => |ca| {
            var args = core.ValueList.init(ca.env.allocator);
            try args.append(ca.test_val);
            return try applyProc(interp, val, args, ca.env, k.next.?, fuel);
        },
    }
}

pub fn applyProc(interp: *interpreter.Interpreter, proc: Value, args: core.ValueList, env: *Environment, k: *core.Cont, fuel: *u64) ElzError!core.EvalStep {
    switch (proc) {
        .vm_closure => |cl| {
            // Run the VM closure via the VM machinery.
            var vm = @import("vm.zig").VM.init(interp) catch return ElzError.OutOfMemory;
            defer vm.deinit();
            // Push callee + args onto VM stack.
            vm.push(proc) catch return ElzError.StackOverflow;
            for (args.items) |arg| vm.push(arg) catch return ElzError.StackOverflow;
            vm.callVmClosure(cl, @intCast(args.items.len), false) catch |err| return err;
            const result = vm.run() catch |err| return err;
            return .{ .apply = .{ .k = k, .val = result } };
        },
        .closure => |c| {
            const call_env = try bindClosureArgs(interp, c, args, env);
            if (c.body == .nil) return .{ .apply = .{ .k = k, .val = Value.nil } };
            return evalBodyStep(interp, c.body, call_env, k);
        },
        .procedure => |prim| {
            const result = try prim(interp, env, args, fuel);
            return .{ .apply = .{ .k = k, .val = result } };
        },
        .cont_aware_procedure => |cap| {
            return try cap(interp, env, args, fuel, k);
        },
        .continuation => |cap| {
            const arg_val = if (args.items.len > 0) args.items[0] else Value.unspecified;
            return try invokeCapturedCont(interp, cap, arg_val, fuel);
        },
        .foreign_procedure => |ff| {
            const ffi = @import("ffi.zig");
            const prev_interp = ffi.active_interp;
            ffi.active_interp = interp;
            defer ffi.active_interp = prev_interp;
            const result = ff(env, args) catch |err| {
                interp.last_error_message = @errorName(err);
                return ElzError.ForeignFunctionError;
            };
            return .{ .apply = .{ .k = k, .val = result } };
        },
        else => return ElzError.NotAFunction,
    }
}

fn invokeCapturedCont(interp: *interpreter.Interpreter, cap: *core.CapturedCont, val: Value, fuel: *u64) ElzError!core.EvalStep {
    return try doWindChange(interp, interp.winders, cap.winders, cap.k, val, fuel);
}

fn doWindChange(interp: *interpreter.Interpreter, from: ?*core.Winder, to: ?*core.Winder, k: *core.Cont, val: Value, fuel: *u64) ElzError!core.EvalStep {
    if (from == to) {
        interp.winders = to;
        return .{ .apply = .{ .k = k, .val = val } };
    }

    var from_depth: usize = 0;
    var to_depth: usize = 0;
    var fp = from;
    while (fp) |f| {
        from_depth += 1;
        fp = f.next;
    }
    var tp = to;
    while (tp) |t| {
        to_depth += 1;
        tp = t.next;
    }

    fp = from;
    tp = to;
    var fd = from_depth;
    var td = to_depth;
    while (fd > td) {
        fp = fp.?.next;
        fd -= 1;
    }
    while (td > fd) {
        tp = tp.?.next;
        td -= 1;
    }
    while (fp != tp) {
        fp = fp.?.next;
        tp = tp.?.next;
    }
    const common = fp;

    var rewind_list: std.ArrayListUnmanaged(*core.Winder) = .empty;
    defer rewind_list.deinit(interp.allocator);
    tp = to;
    while (tp != common) {
        try rewind_list.append(interp.allocator, tp.?);
        tp = tp.?.next;
    }

    fp = from;
    while (fp != common) {
        const empty = core.ValueList.init(interp.allocator);
        _ = try eval_proc(interp, fp.?.after, empty, interp.root_env, fuel);
        fp = fp.?.next;
    }

    var i: usize = rewind_list.items.len;
    while (i > 0) {
        i -= 1;
        const w = rewind_list.items[i];
        const empty = core.ValueList.init(interp.allocator);
        _ = try eval_proc(interp, w.before, empty, interp.root_env, fuel);
    }

    interp.winders = to;
    return .{ .apply = .{ .k = k, .val = val } };
}

// ============================================================================
// Public entry points
// ============================================================================

inline fn checkFuelAndTime(interp: *interpreter.Interpreter, fuel: *u64) ElzError!void {
    interp.last_error_message = null;
    if (fuel.* == 0) return ElzError.ExecutionBudgetExceeded;
    fuel.* -= 1;

    if (interp.time_limit_ms) |limit_ms| {
        interp.time_check_counter +%= 1;
        if (interp.time_check_counter & 0xFF == 0) {
            if (interp.eval_start_ms) |start_ms| {
                const now = interpreter.currentTimeMs();
                if (now - start_ms >= @as(i64, @intCast(limit_ms))) {
                    return ElzError.TimeLimitExceeded;
                }
            }
        }
    }
}

pub fn eval(interp: *interpreter.Interpreter, ast_start: *const Value, env_start: *Environment, fuel: *u64) ElzError!Value {
    const halt = try allocCont(interp, .halt, null);
    var step: core.EvalStep = .{ .eval = .{ .ast = ast_start.*, .env = env_start, .k = halt } };
    while (true) {
        try checkFuelAndTime(interp, fuel);
        step = switch (step) {
            .eval => |e| try evalStep(interp, e.ast, e.env, e.k, fuel),
            .apply => |a| try applyK(interp, a.k, a.val, fuel),
            .done => |v| return v,
        };
    }
}

pub fn eval_proc(interp: *interpreter.Interpreter, proc: Value, args: core.ValueList, env: *Environment, fuel: *u64) ElzError!Value {
    const halt = try allocCont(interp, .halt, null);
    var step = try applyProc(interp, proc, args, env, halt, fuel);
    while (true) {
        try checkFuelAndTime(interp, fuel);
        step = switch (step) {
            .eval => |e| try evalStep(interp, e.ast, e.env, e.k, fuel),
            .apply => |a| try applyK(interp, a.k, a.val, fuel),
            .done => |v| return v,
        };
    }
}

// ============================================================================
// Tests
// ============================================================================

test "eval simple values" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("42", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 42), result.exact_integer);
}

test "eval quote" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(quote (1 2 3))", &fuel);
    try std.testing.expect(result == .pair);
}

test "eval if true branch" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(if #t 1 2)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 1), result.exact_integer);
}

test "eval if false branch" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(if #f 1 2)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 2), result.exact_integer);
}

test "eval nested if - regression for TCO bug" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(if #t (if #t (if #t 42 0) 0) 0)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 42), result.exact_integer);
}

test "eval cond" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(cond (#f 1) (#t 2) (else 3))", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 2), result.exact_integer);
}

test "eval and" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(and 1 2 3)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 3), result.exact_integer);
}

test "eval or" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(or #f 5)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 5), result.exact_integer);
}

test "eval define and lookup" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    _ = try interp.evalString("(define x 100)", &fuel);
    const result = try interp.evalString("x", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 100), result.exact_integer);
}

test "eval set!" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    _ = try interp.evalString("(define y 5)", &fuel);
    _ = try interp.evalString("(set! y 10)", &fuel);
    const result = try interp.evalString("y", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 10), result.exact_integer);
}

test "eval lambda" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("((lambda (x) (* x 2)) 7)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 14), result.exact_integer);
}

test "eval begin" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(begin 1 2 3)", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 3), result.exact_integer);
}

test "eval let" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(let ((x 5) (y 10)) (+ x y))", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 15), result.exact_integer);
}

test "eval let*" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(let* ((x 5) (y x)) (+ x y))", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 10), result.exact_integer);
}

test "eval letrec for recursion" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 10000;

    const result = try interp.evalString(
        "(letrec ((factorial (lambda (n) (if (<= n 1) 1 (* n (factorial (- n 1))))))) (factorial 5))",
        &fuel,
    );
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 120), result.exact_integer);
}

test "eval try/catch success" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(try (+ 1 2) (catch err 0))", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 3), result.exact_integer);
}

test "eval try/catch error" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(try (/ 1 0) (catch err 42))", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 42), result.exact_integer);
}

test "eval fuel exhaustion" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1;

    const result = interp.evalString("(+ 1 (+ 2 3))", &fuel);
    try std.testing.expectError(ElzError.ExecutionBudgetExceeded, result);
}

test "eval call/cc basic escape" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 10000;

    const result = try interp.evalString("(+ 1 (call/cc (lambda (k) (+ 2 (k 10)))))", &fuel);
    try std.testing.expect(result == .exact_integer);
    try std.testing.expectEqual(@as(i64, 11), result.exact_integer);
}

test "eval dynamic-wind basic" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 100000;

    _ = try interp.evalString("(define log '())", &fuel);
    _ = try interp.evalString(
        \\(dynamic-wind
        \\  (lambda () (set! log (cons 'before log)))
        \\  (lambda () (set! log (cons 'body log)))
        \\  (lambda () (set! log (cons 'after log))))
    , &fuel);
    const result = try interp.evalString("log", &fuel);
    try std.testing.expect(result == .pair);
    try std.testing.expect(result.pair.car == .symbol);
    try std.testing.expect(std.mem.eql(u8, result.pair.car.symbol, "after"));
}
