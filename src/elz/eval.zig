const std = @import("std");
const core = @import("core.zig");
const Value = core.Value;
const UserDefinedProc = core.UserDefinedProc;
const Environment = core.Environment;
const ElzError = @import("errors.zig").ElzError;
const interpreter = @import("interpreter.zig");
const parser = @import("parser.zig");
const env_setup = @import("env_setup.zig");

/// Evaluates a list of expressions and returns a list of the results.
fn eval_expr_list(interp: *interpreter.Interpreter, list: Value, env: *Environment, fuel: *u64) ElzError!core.ValueList {
    var results = core.ValueList.init(env.allocator);
    var current_node = list;
    while (current_node != .nil) {
        const p = switch (current_node) {
            .pair => |pair_val| pair_val,
            else => return ElzError.InvalidArgument,
        };
        try results.append(try eval(interp, &p.car, env, fuel));
        current_node = p.cdr;
    }
    return results;
}

/// Evaluates a `letrec` special form.
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

/// Evaluates a `quote` special form.
fn evalQuote(rest: Value, env: *Environment) !Value {
    const p_arg = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.QuoteInvalidArguments,
    };
    if (p_arg.cdr != .nil) return ElzError.QuoteInvalidArguments;
    return try p_arg.car.deep_clone(env.allocator);
}

/// Evaluates a `quasiquote` special form.
/// Handles unquote (,) and unquote-splicing (,@) within templates.
fn evalQuasiquote(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) !Value {
    const p_arg = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.InvalidArgument,
    };
    if (p_arg.cdr != .nil) return ElzError.InvalidArgument;
    return try expandQuasiquote(interp, p_arg.car, env, fuel, 1);
}

/// Recursively expands a quasiquote template.
/// Level tracks nesting depth of quasiquotes.
fn expandQuasiquote(interp: *interpreter.Interpreter, template: Value, env: *Environment, fuel: *u64, level: usize) ElzError!Value {
    switch (template) {
        .pair => |p| {
            // Check for (unquote expr) or (unquote-splicing expr)
            if (p.car.is_symbol("unquote")) {
                if (level == 1) {
                    // Evaluate the unquoted expression
                    const unquote_rest = switch (p.cdr) {
                        .pair => |up| up,
                        else => return ElzError.InvalidArgument,
                    };
                    if (unquote_rest.cdr != .nil) return ElzError.InvalidArgument;
                    return try eval(interp, &unquote_rest.car, env, fuel);
                } else {
                    // Decrease level and continue
                    const new_cdr = try expandQuasiquote(interp, p.cdr, env, fuel, level - 1);
                    const new_pair = try env.allocator.create(core.Pair);
                    new_pair.* = .{ .car = p.car, .cdr = new_cdr };
                    return Value{ .pair = new_pair };
                }
            } else if (p.car.is_symbol("quasiquote")) {
                // Increase level for nested quasiquotes
                const new_cdr = try expandQuasiquote(interp, p.cdr, env, fuel, level + 1);
                const new_pair = try env.allocator.create(core.Pair);
                new_pair.* = .{ .car = p.car, .cdr = new_cdr };
                return Value{ .pair = new_pair };
            } else if (p.car == .pair) {
                // Check if first element is (unquote-splicing expr)
                const inner = p.car.pair;
                if (inner.car.is_symbol("unquote-splicing") and level == 1) {
                    const splice_rest = switch (inner.cdr) {
                        .pair => |sp| sp,
                        else => return ElzError.InvalidArgument,
                    };
                    if (splice_rest.cdr != .nil) return ElzError.InvalidArgument;
                    const splice_result = try eval(interp, &splice_rest.car, env, fuel);
                    // Append the spliced list to the rest
                    const rest_expanded = try expandQuasiquote(interp, p.cdr, env, fuel, level);
                    return try appendLists(env.allocator, splice_result, rest_expanded);
                }
            }
            // Normal pair - recurse on both car and cdr
            const new_car = try expandQuasiquote(interp, p.car, env, fuel, level);
            const new_cdr = try expandQuasiquote(interp, p.cdr, env, fuel, level);
            const new_pair = try env.allocator.create(core.Pair);
            new_pair.* = .{ .car = new_car, .cdr = new_cdr };
            return Value{ .pair = new_pair };
        },
        else => {
            // Self-quoting values
            return try template.deep_clone(env.allocator);
        },
    }
}

/// Helper: Append two lists for unquote-splicing.
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

/// Evaluates an `import` special form.
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

    const source_bytes = std.fs.cwd().readFileAlloc(interp.allocator, path_str, 1024 * 1024) catch {
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

    var temp = std.ArrayListUnmanaged(struct { k: []const u8, v: core.Value }){};
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

/// Evaluates an `if` special form.
fn evalIf(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value) !Value {
    const p_test = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.IfInvalidArguments,
    };
    const p_consequent = switch (p_test.cdr) {
        .pair => |p_rest| p_rest,
        else => return ElzError.IfInvalidArguments,
    };
    const condition = try eval(interp, &p_test.car, env, fuel);

    const is_true = switch (condition) {
        .boolean => |b| b,
        else => true,
    };

    if (is_true) {
        // Point to the car of p_consequent (heap-allocated in the AST)
        current_ast.* = &p_consequent.car;
        return .unspecified;
    } else {
        const p_alternative = switch (p_consequent.cdr) {
            .pair => |p_rest| p_rest,
            .nil => return Value.nil,
            else => return ElzError.IfInvalidArguments,
        };
        if (p_alternative.cdr != .nil) return ElzError.IfInvalidArguments;
        // Point to the car of p_alternative (heap-allocated in the AST)
        current_ast.* = &p_alternative.car;
        return .unspecified;
    }
}

/// Evaluates a `cond` special form.
fn evalCond(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value) !Value {
    var current_clause_node = rest;
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
        const test_expr = clause_p.car;
        if (test_expr.is_symbol("else")) {
            const body = clause_p.cdr;
            if (body == .nil) return ElzError.InvalidArgument;
            var current_body_node = body;
            while (current_body_node.pair.cdr != .nil) {
                _ = try eval(interp, &current_body_node.pair.car, env, fuel);
                current_body_node = current_body_node.pair.cdr;
            }
            current_ast.* = &current_body_node.pair.car;
            return .unspecified;
        }
        const condition = try eval(interp, &test_expr, env, fuel);
        const is_true = switch (condition) {
            .boolean => |b| b,
            else => true,
        };
        if (is_true) {
            const body = clause_p.cdr;
            if (body == .nil) return condition;
            var current_body_node = body;
            while (current_body_node.pair.cdr != .nil) {
                _ = try eval(interp, &current_body_node.pair.car, env, fuel);
                current_body_node = current_body_node.pair.cdr;
            }
            current_ast.* = &current_body_node.pair.car;
            return .unspecified;
        }
        current_clause_node = clause_pair.cdr;
    }
    return Value.nil;
}

/// Evaluates a `case` special form.
/// Syntax: (case key ((datum1 datum2 ...) expr1 ...) ... (else expr))
fn evalCase(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value) !Value {
    // Get the key expression
    const rest_pair = switch (rest) {
        .pair => |p| p,
        else => return ElzError.InvalidArgument,
    };
    const key = try eval(interp, &rest_pair.car, env, fuel);

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

        // Check for else clause
        if (datums.is_symbol("else")) {
            if (body == .nil) return Value.nil;
            var current_body_node = body;
            while (current_body_node.pair.cdr != .nil) {
                _ = try eval(interp, &current_body_node.pair.car, env, fuel);
                current_body_node = current_body_node.pair.cdr;
            }
            current_ast.* = &current_body_node.pair.car;
            return .unspecified;
        }

        // Check if key matches any datum in the list
        var found = false;
        var datum_node = datums;
        while (datum_node != .nil) {
            const datum_pair = switch (datum_node) {
                .pair => |dp| dp,
                else => return ElzError.InvalidArgument,
            };
            const datum = datum_pair.car;

            // Use eqv? semantics for comparison
            if (is_eqv(key, datum)) {
                found = true;
                break;
            }
            datum_node = datum_pair.cdr;
        }

        if (found) {
            if (body == .nil) return Value.nil;
            var current_body_node = body;
            while (current_body_node.pair.cdr != .nil) {
                _ = try eval(interp, &current_body_node.pair.car, env, fuel);
                current_body_node = current_body_node.pair.cdr;
            }
            current_ast.* = &current_body_node.pair.car;
            return .unspecified;
        }

        current_clause_node = clause_pair.cdr;
    }
    return Value.nil;
}

/// Helper for case: checks if two values are eqv?
fn is_eqv(a: Value, b: Value) bool {
    return switch (a) {
        .number => |n| if (b == .number) n == b.number else false,
        .boolean => |bl| if (b == .boolean) bl == b.boolean else false,
        .character => |c| if (b == .character) c == b.character else false,
        .symbol => |s| if (b == .symbol) std.mem.eql(u8, s, b.symbol) else false,
        .nil => b == .nil,
        else => false,
    };
}

/// Evaluates an `and` special form.
fn evalAnd(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value) !Value {
    if (rest == .nil) return Value{ .boolean = true };
    var current_node = rest;
    while (current_node.pair.cdr != .nil) {
        const result = try eval(interp, &current_node.pair.car, env, fuel);
        const is_true = switch (result) {
            .boolean => |b| b,
            else => true,
        };
        if (!is_true) return result;
        current_node = current_node.pair.cdr;
    }
    current_ast.* = &current_node.pair.car;
    return .unspecified;
}

/// Evaluates an `or` special form.
fn evalOr(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value) !Value {
    if (rest == .nil) return Value{ .boolean = false };
    var current_node = rest;
    while (current_node.pair.cdr != .nil) {
        const result = try eval(interp, &current_node.pair.car, env, fuel);
        const is_true = switch (result) {
            .boolean => |b| b,
            else => true,
        };
        if (is_true) return result;
        current_node = current_node.pair.cdr;
    }
    current_ast.* = &current_node.pair.car;
    return .unspecified;
}

/// Evaluates a `define` special form.
fn evalDefine(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) !Value {
    const p_name = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.DefineInvalidArguments,
    };
    const name_or_sig = p_name.car;
    const body = p_name.cdr;
    switch (name_or_sig) {
        .symbol => |symbol_name| {
            const p_expr = switch (body) {
                .pair => |p_rest| p_rest,
                else => return ElzError.DefineInvalidArguments,
            };
            if (p_expr.cdr != .nil) return ElzError.DefineInvalidArguments;
            const value = try eval(interp, &p_expr.car, env, fuel);
            try env.set(interp, symbol_name, value);
            return value;
        },
        .pair => |sig_pair| {
            const fn_name_val = sig_pair.car;
            const fn_name = if (fn_name_val == .symbol) fn_name_val.symbol else return ElzError.DefineInvalidSymbol;
            const params = sig_pair.cdr;
            var params_list_gc = core.ValueList.init(env.allocator);
            var current_param = params;
            while (current_param != .nil) {
                const param_p = switch (current_param) {
                    .pair => |pp| pp,
                    else => return ElzError.LambdaInvalidParams,
                };
                if (param_p.car != .symbol) return ElzError.LambdaInvalidParams;
                try params_list_gc.append(param_p.car);
                current_param = param_p.cdr;
            }
            const proc = try env.allocator.create(UserDefinedProc);
            proc.* = .{ .params = params_list_gc, .body = try body.deep_clone(env.allocator), .env = env };
            const closure = Value{ .closure = proc };
            try env.set(interp, fn_name, closure);
            return closure;
        },
        else => return ElzError.DefineInvalidSymbol,
    }
}

/// Evaluates a `set!` special form.
fn evalSet(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) !Value {
    const p_sym = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.SetInvalidArguments,
    };
    const symbol = p_sym.car;
    if (symbol != .symbol) return ElzError.SetInvalidSymbol;
    const p_expr = switch (p_sym.cdr) {
        .pair => |p_rest| p_rest,
        else => return ElzError.SetInvalidArguments,
    };
    if (p_expr.cdr != .nil) return ElzError.SetInvalidArguments;
    const value = try eval(interp, &p_expr.car, env, fuel);
    try env.update(interp, symbol.symbol, value);
    return Value.nil;
}

/// Evaluates a `define-macro` special form.
/// Syntax: (define-macro (name args...) body...)
fn evalDefineMacro(interp: *interpreter.Interpreter, rest: Value, env: *Environment) !Value {
    const p_sig = switch (rest) {
        .pair => |p| p,
        else => return ElzError.DefineInvalidArguments,
    };

    // Get (name args...) list
    const signature = p_sig.car;
    const body = p_sig.cdr;

    const sig_pair = switch (signature) {
        .pair => |p| p,
        else => return ElzError.DefineInvalidArguments,
    };

    // Get macro name
    const macro_name = switch (sig_pair.car) {
        .symbol => |s| s,
        else => return ElzError.DefineInvalidSymbol,
    };

    // Get parameters
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

    // Create macro
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

/// Evaluates a `lambda` special form.
fn evalLambda(rest: Value, env: *Environment) !Value {
    const p_formals = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.LambdaInvalidArguments,
    };
    const params_list = p_formals.car;
    const body = p_formals.cdr;
    if (body == .nil) return ElzError.LambdaInvalidArguments;
    var params_list_gc = core.ValueList.init(env.allocator);
    var current_param = params_list;
    while (current_param != .nil) {
        const param_p = switch (current_param) {
            .pair => |pp| pp,
            else => return ElzError.LambdaInvalidParams,
        };
        if (param_p.car != .symbol) return ElzError.LambdaInvalidParams;
        try params_list_gc.append(param_p.car);
        current_param = param_p.cdr;
    }
    const proc = try env.allocator.create(UserDefinedProc);
    proc.* = .{ .params = params_list_gc, .body = try body.deep_clone(env.allocator), .env = env };
    return Value{ .closure = proc };
}

/// Evaluates a `begin` special form.
fn evalBegin(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value) !Value {
    var current_node = rest;
    if (current_node == .nil) return .nil;
    while (current_node.pair.cdr != .nil) {
        _ = try eval(interp, &current_node.pair.car, env, fuel);
        current_node = current_node.pair.cdr;
    }
    current_ast.* = &current_node.pair.car;
    return .unspecified;
}

/// Evaluates a `let` or `let*` special form.
fn evalLet(interp: *interpreter.Interpreter, first: Value, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value, current_env: **Environment) !Value {
    const is_let_star = first.is_symbol("let*");
    const p_bindings = switch (rest) {
        .pair => |p_rest| p_rest,
        else => return ElzError.InvalidArgument,
    };
    const bindings_list = p_bindings.car;
    const body = p_bindings.cdr;
    const new_env = try Environment.init(env.allocator, env);
    var current_binding = bindings_list;
    while (current_binding != .nil) {
        const binding_p = switch (current_binding) {
            .pair => |p_rest| p_rest,
            else => return ElzError.InvalidArgument,
        };
        const binding = binding_p.car;
        const var_p = switch (binding) {
            .pair => |p_rest| p_rest,
            else => return ElzError.InvalidArgument,
        };
        const var_sym = var_p.car;
        if (var_sym != .symbol) return ElzError.InvalidArgument;
        const init_p = switch (var_p.cdr) {
            .pair => |p_rest| p_rest,
            else => return ElzError.InvalidArgument,
        };
        const init_expr = init_p.car;
        const eval_env = if (is_let_star) new_env else env;
        const value = try eval(interp, &init_expr, eval_env, fuel);
        try new_env.set(interp, var_sym.symbol, value);
        current_binding = binding_p.cdr;
    }

    var current_body_node = body;
    if (current_body_node == .nil) return .nil;
    while (current_body_node.pair.cdr != .nil) {
        _ = try eval(interp, &current_body_node.pair.car, new_env, fuel);
        current_body_node = current_body_node.pair.cdr;
    }
    current_ast.* = &current_body_node.pair.car;
    current_env.* = new_env;
    return .unspecified;
}

/// Evaluates a `try` special form.
fn evalTry(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) !Value {
    var try_body_forms = std.ArrayListUnmanaged(core.Value){};
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

    if (catch_clause == null) {
        return ElzError.InvalidArgument;
    }

    const catch_p = catch_clause.?.pair;
    const catch_args_p = switch (catch_p.cdr) {
        .pair => |pair_val| pair_val,
        else => return ElzError.InvalidArgument,
    };

    const err_symbol = catch_args_p.car;
    if (err_symbol != .symbol) {
        return ElzError.InvalidArgument;
    }
    const handler_body = catch_args_p.cdr;
    if (handler_body == .nil) {
        return ElzError.InvalidArgument;
    }

    var last_result: core.Value = .unspecified;
    var eval_error: ?ElzError = null;
    for (try_body_forms.items) |form| {
        last_result = eval(interp, &form, env, fuel) catch |err| {
            eval_error = err;
            break;
        };
    }

    if (eval_error) |_| {
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

/// Evaluates a macro expansion.
/// The macro's unevaluated arguments are bound to its parameters, the body is evaluated
/// to produce an expansion form, and that expansion is then evaluated in the calling environment.
fn evalMacroExpansion(interp: *interpreter.Interpreter, m: *core.Macro, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value) !Value {
    // Collect unevaluated args from the rest list
    var unevaluated_args = std.ArrayListUnmanaged(Value){};
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

    // Check arg count
    if (unevaluated_args.items.len != m.params.items.len) return ElzError.WrongArgumentCount;

    // Create a new environment with unevaluated args bound to macro params
    const macro_env = try Environment.init(env.allocator, m.env);
    for (m.params.items, unevaluated_args.items) |param, arg| {
        try macro_env.set(interp, param.symbol, arg);
    }

    // Evaluate the macro body to produce the expansion
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

    // Now evaluate the expansion in the calling environment via the trampoline
    const stored = try env.allocator.create(Value);
    stored.* = expansion;
    current_ast.* = stored;
    return .unspecified;
}

/// Evaluates a procedure application.
fn evalApplication(interp: *interpreter.Interpreter, first: Value, rest: Value, env: *Environment, fuel: *u64, current_ast: **const Value, current_env: **Environment) !Value {
    const proc_val = try eval(interp, &first, env, fuel);
    const arg_vals = try eval_expr_list(interp, rest, env, fuel);

    switch (proc_val) {
        .closure => |c| {
            if (c.params.items.len != arg_vals.items.len) return ElzError.WrongArgumentCount;

            var call_env = c.env;
            if (c.params.items.len > 0) {
                const new_env = try Environment.init(env.allocator, c.env);
                for (c.params.items, arg_vals.items) |param, arg| {
                    try new_env.set(interp, param.symbol, arg);
                }
                call_env = new_env;
            }

            var body_node = c.body;
            if (body_node == .nil) return .nil;

            while (body_node.pair.cdr != .nil) {
                _ = try eval(interp, &body_node.pair.car, call_env, fuel);
                body_node = body_node.pair.cdr;
            }

            current_env.* = call_env;
            current_ast.* = &body_node.pair.car;
            return .unspecified;
        },
        .procedure => |prim| return prim(interp, env, arg_vals, fuel),
        .foreign_procedure => |ff| {
            return ff(env, arg_vals) catch |err| {
                interp.last_error_message = @errorName(err);
                return ElzError.ForeignFunctionError;
            };
        },
        else => return ElzError.NotAFunction,
    }
}

/// Applies a procedure to a list of arguments.
/// This function is used to execute a procedure (either a closure or a primitive) with a given set of arguments.
/// It is not tail-recursive and should be used when the result of the procedure call is immediately needed.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
/// - `proc`: The procedure `Value` to apply.
/// - `args`: A `ValueList` of arguments to apply the procedure with.
/// - `env`: The environment in which to apply the procedure.
/// - `fuel`: A pointer to the execution fuel counter.
///
/// Returns:
/// The result of the procedure application, or an error if the application fails.
pub fn eval_proc(interp: *interpreter.Interpreter, proc: Value, args: core.ValueList, env: *Environment, fuel: *u64) ElzError!Value {
    switch (proc) {
        .closure => |c| {
            if (c.params.items.len != args.items.len) return ElzError.WrongArgumentCount;
            const new_env = try Environment.init(env.allocator, c.env);
            for (c.params.items, args.items) |param, arg| {
                try new_env.set(interp, param.symbol, arg);
            }
            var result: Value = .nil;
            var current_node = c.body;
            while (current_node != .nil) {
                const p = switch (current_node) {
                    .pair => |pair_val| pair_val,
                    else => return ElzError.InvalidArgument,
                };
                result = try eval(interp, &p.car, new_env, fuel);
                current_node = p.cdr;
            }
            std.mem.doNotOptimizeAway(&new_env);
            return result;
        },
        .procedure => |p| return p(interp, env, args, fuel),
        .foreign_procedure => |ff| {
            return ff(env, args) catch |err| {
                interp.last_error_message = @errorName(err);
                return ElzError.ForeignFunctionError;
            };
        },
        else => return ElzError.NotAFunction,
    }
}

/// Evaluates an Abstract Syntax Tree (AST) node in a given environment.
/// This is the main evaluation function of the interpreter. It uses a trampoline loop (`while (true)`)
/// to achieve tail-call optimization (TCO). Instead of making a recursive call for tail-position
/// expressions, it updates `current_ast` and `current_env` and continues the loop.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
/// - `ast_start`: A pointer to the initial AST `Value` to evaluate.
/// - `env_start`: The initial environment in which to evaluate the AST.
/// - `fuel`: A pointer to the execution fuel counter. This is decremented on each evaluation step.
///
/// Returns:
/// The result of the evaluation as a `Value`, or an error if evaluation fails.
pub fn eval(interp: *interpreter.Interpreter, ast_start: *const Value, env_start: *Environment, fuel: *u64) ElzError!Value {
    var current_ast = ast_start;
    var current_env = env_start;

    while (true) {
        std.mem.doNotOptimizeAway(&current_env);

        interp.last_error_message = null;
        if (fuel.* == 0) return ElzError.ExecutionBudgetExceeded;
        fuel.* -= 1;

        // Check time limit every 256 steps to minimize syscall overhead
        if (interp.time_limit_ms) |limit_ms| {
            interp.time_check_counter +%= 1;
            if (interp.time_check_counter & 0xFF == 0) {
                if (interp.eval_start_ms) |start_ms| {
                    const now = std.time.milliTimestamp();
                    if (now - start_ms >= @as(i64, @intCast(limit_ms))) {
                        return ElzError.TimeLimitExceeded;
                    }
                }
            }
        }

        const ast = current_ast;
        const env = current_env;

        switch (ast.*) {
            .number, .boolean, .character, .nil, .closure, .macro, .procedure, .foreign_procedure, .opaque_pointer, .cell, .module, .vector, .hash_map, .port, .unspecified => return ast.*,
            .string => |s| return Value{ .string = try env.allocator.dupe(u8, s) },
            .symbol => |sym| return env.get(sym, interp),
            .pair => |p| {
                const original_ast_ptr = current_ast;
                const first = p.car;
                const rest = p.cdr;

                // Check if first is a macro name before falling through to evalApplication
                const maybe_macro: ?*core.Macro = if (first == .symbol) blk: {
                    const looked_up = env.get(first.symbol, interp) catch break :blk null;
                    break :blk if (looked_up == .macro) looked_up.macro else null;
                } else null;

                const result = try if (maybe_macro) |m| evalMacroExpansion(interp, m, rest, env, fuel, &current_ast) else if (first.is_symbol("quote")) evalQuote(rest, env) else if (first.is_symbol("quasiquote")) evalQuasiquote(interp, rest, env, fuel) else if (first.is_symbol("import")) evalImport(interp, rest, env, fuel) else if (first.is_symbol("if")) evalIf(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("cond")) evalCond(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("case")) evalCase(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("and")) evalAnd(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("or")) evalOr(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("define")) evalDefine(interp, rest, env, fuel) else if (first.is_symbol("define-macro")) evalDefineMacro(interp, rest, env) else if (first.is_symbol("set!")) evalSet(interp, rest, env, fuel) else if (first.is_symbol("lambda")) evalLambda(rest, env) else if (first.is_symbol("begin")) evalBegin(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("let") or first.is_symbol("let*")) evalLet(interp, first, rest, env, fuel, &current_ast, &current_env) else if (first.is_symbol("letrec")) evalLetRec(interp, ast.*, env, fuel) else if (first.is_symbol("try")) evalTry(interp, rest, env, fuel) else evalApplication(interp, first, rest, env, fuel, &current_ast, &current_env);

                if (result == .unspecified) {
                    if (current_ast != original_ast_ptr) {
                        continue;
                    }
                }
                return result;
            },
        }
    }
}

test "eval simple values" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // Numbers are self-evaluating
    const result = try interp.evalString("42", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 42), result.number);
}

test "eval quote" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // Quote returns the unevaluated form
    const result = try interp.evalString("(quote (1 2 3))", &fuel);
    try std.testing.expect(result == .pair);
}

test "eval if true branch" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(if #t 1 2)", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 1), result.number);
}

test "eval if false branch" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(if #f 1 2)", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 2), result.number);
}

test "eval nested if - regression for TCO bug" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(if #t (if #t (if #t 42 0) 0) 0)", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 42), result.number);
}

test "eval cond" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(cond (#f 1) (#t 2) (else 3))", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 2), result.number);
}

test "eval and" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // and returns last value if all truthy
    const result = try interp.evalString("(and 1 2 3)", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 3), result.number);
}

test "eval or" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // or returns first truthy value
    const result = try interp.evalString("(or #f 5)", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 5), result.number);
}

test "eval define and lookup" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    _ = try interp.evalString("(define x 100)", &fuel);
    const result = try interp.evalString("x", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 100), result.number);
}

test "eval set!" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    _ = try interp.evalString("(define y 5)", &fuel);
    _ = try interp.evalString("(set! y 10)", &fuel);
    const result = try interp.evalString("y", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 10), result.number);
}

test "eval lambda" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("((lambda (x) (* x 2)) 7)", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 14), result.number);
}

test "eval begin" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(begin 1 2 3)", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 3), result.number);
}

test "eval let" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(let ((x 5) (y 10)) (+ x y))", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 15), result.number);
}

test "eval let*" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    // let* allows sequential binding
    const result = try interp.evalString("(let* ((x 5) (y x)) (+ x y))", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 10), result.number);
}

test "eval letrec for recursion" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 10000;

    const result = try interp.evalString(
        "(letrec ((factorial (lambda (n) (if (<= n 1) 1 (* n (factorial (- n 1))))))) (factorial 5))",
        &fuel,
    );
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 120), result.number);
}

test "eval try/catch success" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(try (+ 1 2) (catch err 0))", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 3), result.number);
}

test "eval try/catch error" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1000;

    const result = try interp.evalString("(try (/ 1 0) (catch err 42))", &fuel);
    try std.testing.expect(result == .number);
    try std.testing.expectEqual(@as(f64, 42), result.number);
}

test "eval fuel exhaustion" {
    var interp = interpreter.Interpreter.init(.{}) catch unreachable;
    defer interp.deinit();
    var fuel: u64 = 1; // Very limited fuel

    const result = interp.evalString("(+ 1 (+ 2 3))", &fuel);
    try std.testing.expectError(ElzError.ExecutionBudgetExceeded, result);
}
