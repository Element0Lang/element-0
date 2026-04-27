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

/// Returns true when `name` appears in the literals slice.
fn is_literal_identifier(name: []const u8, literals: [][]const u8) bool {
    for (literals) |lit| {
        if (std.mem.eql(u8, lit, name)) return true;
    }
    return false;
}

/// Returns true when `pair_val` is a list whose first element is the symbol `...`. Used to
/// detect the syntax-rules ellipsis form `(P . (... . rest))` while pattern matching.
fn is_ellipsis_marker(value: Value) bool {
    return value == .pair and value.pair.car.is_symbol("...");
}

/// One pattern variable binding. Single bindings come from non-ellipsis pattern variables;
/// repeated bindings come from variables under one level of `...` and store one value per
/// matched iteration.
const PatternBinding = union(enum) {
    single: Value,
    repeated: []Value,
};

const Bindings = std.StringHashMapUnmanaged(PatternBinding);

/// Recursively collects names of pattern variables in `pattern`. Skips literals, `_`, and
/// the ellipsis marker.
fn collect_pattern_vars(
    allocator: std.mem.Allocator,
    pattern: Value,
    literals: [][]const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    switch (pattern) {
        .symbol => |s| {
            if (std.mem.eql(u8, s, "_")) return;
            if (std.mem.eql(u8, s, "...")) return;
            if (is_literal_identifier(s, literals)) return;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, s)) return;
            }
            try out.append(allocator, s);
        },
        .pair => |p| {
            try collect_pattern_vars(allocator, p.car, literals, out);
            try collect_pattern_vars(allocator, p.cdr, literals, out);
        },
        else => {},
    }
}

/// Errors that the syntax-rules matcher can raise. Declared explicitly to break an
/// inferred-error-set dependency loop between `match_pattern` and `match_ellipsis_tail`.
const MatchError = error{
    OutOfMemory,
    MissingPatternVar,
    NestedEllipsisUnsupported,
};

/// Names treated as syntactic keywords by the evaluator. Identifiers in this set are not
/// candidates for hygiene renaming, since they do not refer to environment bindings.
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

/// Pattern matcher for `syntax-rules`. Records pattern variable bindings into `bindings`.
/// Supports a single trailing ellipsis pattern of the form `(p ...)`.
fn match_pattern(
    allocator: std.mem.Allocator,
    pattern: Value,
    input: Value,
    literals: [][]const u8,
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
            // Detect tail ellipsis: pattern shape is `(P . (... . nil))`.
            if (is_ellipsis_marker(p.cdr) and p.cdr.pair.cdr == .nil) {
                return try match_ellipsis_tail(allocator, p.car, input, literals, bindings);
            }
            if (input != .pair) return false;
            const ip = input.pair;
            if (!try match_pattern(allocator, p.car, ip.car, literals, bindings)) return false;
            return try match_pattern(allocator, p.cdr, ip.cdr, literals, bindings);
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

/// Matches a tail-ellipsis sub-pattern against zero or more elements of an input list. The
/// matched values are recorded as repeated bindings on each variable in `sub_pat`.
fn match_ellipsis_tail(
    allocator: std.mem.Allocator,
    sub_pat: Value,
    input: Value,
    literals: [][]const u8,
    bindings: *Bindings,
) MatchError!bool {
    var var_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer var_names.deinit(allocator);
    try collect_pattern_vars(allocator, sub_pat, literals, &var_names);

    // Per-variable accumulators.
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
        const ok = try match_pattern(allocator, sub_pat, node.pair.car, literals, &iter_bindings);
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

/// Returns the names of repeated bindings that appear in `template`. Used to drive
/// ellipsis expansion.
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

/// Expands a template, substituting pattern variable bindings. Tail ellipsis templates
/// `(t ...)` repeat their sub-template once per ellipsis frame in the relevant variables.
fn expand_template(
    allocator: std.mem.Allocator,
    template: Value,
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
            // Detect tail ellipsis template: `(T . (... . rest))`.
            if (is_ellipsis_marker(p.cdr)) {
                const after = p.cdr.pair.cdr;
                const repeated_list = try expand_ellipsis(allocator, p.car, bindings);
                const tail = try expand_template(allocator, after, bindings);
                return try append_lists(allocator, repeated_list, tail);
            }
            const new_pair = try allocator.create(core.Pair);
            new_pair.* = .{
                .car = try expand_template(allocator, p.car, bindings),
                .cdr = try expand_template(allocator, p.cdr, bindings),
            };
            return Value{ .pair = new_pair };
        },
        else => return template.deep_clone(allocator),
    }
}

/// Expands a sub-template under ellipsis. Returns a Scheme list with one expansion per
/// matched frame.
fn expand_ellipsis(
    allocator: std.mem.Allocator,
    sub_tmpl: Value,
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
        const expanded = try expand_template(allocator, sub_tmpl, &iter_bindings);
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

/// Walks `template` and records every symbol that is a candidate for hygiene renaming:
/// symbols that are not pattern variables, not special forms, and not bound in the macro
/// definition's environment.
fn collect_introduced_identifiers(
    interp: *interpreter.Interpreter,
    allocator: std.mem.Allocator,
    template: Value,
    pattern_var_names: []const []const u8,
    def_env: *Environment,
    out: *std.ArrayListUnmanaged([]const u8),
) ElzError!void {
    switch (template) {
        .symbol => |s| {
            if (is_special_form_name(s)) return;
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
            try collect_introduced_identifiers(interp, allocator, p.car, pattern_var_names, def_env, out);
            try collect_introduced_identifiers(interp, allocator, p.cdr, pattern_var_names, def_env, out);
        },
        else => {},
    }
}

/// Returns a fresh symbol name based on `base`, using the interpreter's gensym counter.
fn fresh_hygiene_name(interp: *interpreter.Interpreter, allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    interp.gensym_counter += 1;
    return std.fmt.allocPrint(allocator, "{s}__h{d}", .{ base, interp.gensym_counter });
}

/// Renames symbols in `template` according to `rename_map`. Other nodes are left structurally
/// identical (still constructed via `expand_template`'s logic later).
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

/// Appends two Scheme lists, deep-cloning the head and reusing the tail.
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

/// Expands a `syntax-rules` macro invocation. Tries each rule in order; the first matching
/// rule's template is expanded with the captured pattern variable bindings.
fn expandSyntaxRules(
    interp: *interpreter.Interpreter,
    sr: *core.SyntaxRulesMacro,
    rest: Value,
    env: *Environment,
    fuel: *u64,
    current_ast: **const Value,
) ElzError!Value {
    const allocator = env.allocator;
    // Construct the input as (keyword . rest) so the pattern's leading element can be `_`.
    const head_pair = try allocator.create(core.Pair);
    head_pair.* = .{ .car = Value{ .symbol = try allocator.dupe(u8, sr.name) }, .cdr = rest };
    const input = Value{ .pair = head_pair };

    for (sr.rules) |rule| {
        var bindings: Bindings = .empty;
        defer bindings.deinit(allocator);

        const matched = match_pattern(allocator, rule.pattern, input, sr.literals, &bindings) catch return ElzError.OutOfMemory;
        if (matched) {
            // Hygiene: collect template-introduced identifiers and rename them with fresh
            // gensyms. Pattern variables and identifiers known to the macro's definition
            // environment pass through untouched.
            var pattern_var_names: std.ArrayListUnmanaged([]const u8) = .empty;
            defer pattern_var_names.deinit(allocator);
            try collect_pattern_vars(allocator, rule.pattern, sr.literals, &pattern_var_names);

            var introduced: std.ArrayListUnmanaged([]const u8) = .empty;
            defer introduced.deinit(allocator);
            try collect_introduced_identifiers(interp, allocator, rule.template, pattern_var_names.items, sr.env, &introduced);

            var rename_map: std.StringHashMapUnmanaged([]const u8) = .empty;
            defer rename_map.deinit(allocator);
            for (introduced.items) |name| {
                const fresh = fresh_hygiene_name(interp, allocator, name) catch return ElzError.OutOfMemory;
                try rename_map.put(allocator, name, fresh);
            }

            const renamed_template = try rename_template(allocator, rule.template, &rename_map);
            const expanded = try expand_template(allocator, renamed_template, &bindings);
            const expanded_ptr = try allocator.create(Value);
            expanded_ptr.* = expanded;
            current_ast.* = expanded_ptr;
            return Value.unspecified;
        }
    }

    interp.last_error_message = std.fmt.allocPrint(allocator, "No matching syntax-rules pattern for '{s}'.", .{sr.name}) catch null;
    _ = fuel;
    return ElzError.InvalidArgument;
}

/// Evaluates a `let-syntax` or `letrec-syntax` special form. Both bind transformer
/// values into a fresh environment and evaluate the body there. The two differ only in
/// the lexical scope used to compile each transformer; for the present implementation
/// (which captures the transformer's environment but does not yet allow transformers to
/// recursively reference each other inside templates) the difference is not observable.
fn evalLetSyntax(interp: *interpreter.Interpreter, rest: Value, env: *Environment, fuel: *u64) ElzError!Value {
    if (rest != .pair) return ElzError.InvalidArgument;
    const bindings_list = rest.pair.car;
    const body = rest.pair.cdr;

    const new_env = try Environment.init(env.allocator, env);

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

        const sr = try buildSyntaxRules(new_env, name_val.symbol, transformer_form.pair.cdr);
        try new_env.set(interp, name_val.symbol, Value{ .syntax_rules = sr });
        node = node.pair.cdr;
    }

    if (body == .nil) return Value.unspecified;
    var body_node = body;
    var last: Value = .unspecified;
    while (body_node != .nil) {
        if (body_node != .pair) return ElzError.InvalidArgument;
        last = try eval(interp, &body_node.pair.car, new_env, fuel);
        body_node = body_node.pair.cdr;
    }
    return last;
}

/// Evaluates a `define-syntax` special form: `(define-syntax name (syntax-rules (lit ...) (pat tmpl) ...))`.
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

/// Builds a `SyntaxRulesMacro` from the body of a `syntax-rules` form (the `(literals)
/// (pat tmpl) ...` tail).
fn buildSyntaxRules(env: *Environment, name: []const u8, body: Value) ElzError!*core.SyntaxRulesMacro {
    if (body != .pair) return ElzError.InvalidArgument;
    const literals_val = body.pair.car;
    var rules_node = body.pair.cdr;

    // Collect literal identifier names.
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

    // Collect pattern/template rules.
    var rules_list: std.ArrayListUnmanaged(core.SyntaxRule) = .empty;
    defer rules_list.deinit(env.allocator);
    while (rules_node != .nil) {
        if (rules_node != .pair) return ElzError.InvalidArgument;
        const rule_form = rules_node.pair.car;
        if (rule_form != .pair) return ElzError.InvalidArgument;
        const pattern = rule_form.pair.car;
        const tail = rule_form.pair.cdr;
        if (tail != .pair) return ElzError.InvalidArgument;
        const template = tail.pair.car;
        if (tail.pair.cdr != .nil) return ElzError.InvalidArgument;
        try rules_list.append(env.allocator, .{ .pattern = pattern, .template = template });
        rules_node = rules_node.pair.cdr;
    }

    const sr = try env.allocator.create(core.SyntaxRulesMacro);
    sr.* = .{
        .name = try env.allocator.dupe(u8, name),
        .literals = try lit_names.toOwnedSlice(env.allocator),
        .rules = try rules_list.toOwnedSlice(env.allocator),
        .env = env,
    };
    return sr;
}

/// Evaluates a `delay` special form. Captures the body expression and current environment
/// in a fresh promise without evaluating the expression.
/// Syntax: (delay expr)
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

/// Evaluates a `do` special form.
/// Syntax: (do ((var init step) ...) (test result ...) body ...)
/// Each binding may be `(var init)` (no step) or `(var init step)`.
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

    // Collect bindings into parallel slices for repeated stepping.
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

    // Bind initial values in a fresh scope.
    const loop_env = try Environment.init(env.allocator, env);
    for (var_names.items, 0..) |name, i| {
        var init_expr = init_exprs.items[i];
        const v = try eval(interp, &init_expr, env, fuel);
        try loop_env.set(interp, name, v);
    }

    // Iteration.
    while (true) {
        var test_node = test_expr;
        const test_result = try eval(interp, &test_node, loop_env, fuel);
        const truthy = !(test_result == .boolean and test_result.boolean == false);
        if (truthy) {
            if (result_exprs == .nil) return Value.unspecified;
            var node = result_exprs;
            var last: Value = .unspecified;
            while (node != .nil) {
                if (node != .pair) return ElzError.InvalidArgument;
                last = try eval(interp, &node.pair.car, loop_env, fuel);
                node = node.pair.cdr;
            }
            return last;
        }

        // Body for side effects.
        var body_node = body;
        while (body_node != .nil) {
            if (body_node != .pair) return ElzError.InvalidArgument;
            _ = try eval(interp, &body_node.pair.car, loop_env, fuel);
            body_node = body_node.pair.cdr;
        }

        // Evaluate all step expressions in the current bindings, then assign.
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

/// Evaluates a `try` special form.
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
                    var ts: std.c.timespec = undefined;
                    _ = std.c.clock_gettime(.REALTIME, &ts);
                    const now = @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
                    if (now - start_ms >= @as(i64, @intCast(limit_ms))) {
                        return ElzError.TimeLimitExceeded;
                    }
                }
            }
        }

        const ast = current_ast;
        const env = current_env;

        switch (ast.*) {
            .number, .boolean, .character, .nil, .closure, .macro, .procedure, .foreign_procedure, .opaque_pointer, .cell, .module, .vector, .hash_map, .port, .promise, .multi_values, .syntax_rules, .unspecified => return ast.*,
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

                const maybe_syntax: ?*core.SyntaxRulesMacro = if (first == .symbol and maybe_macro == null) blk: {
                    const looked_up = env.get(first.symbol, interp) catch break :blk null;
                    break :blk if (looked_up == .syntax_rules) looked_up.syntax_rules else null;
                } else null;

                const result = try if (maybe_macro) |m| evalMacroExpansion(interp, m, rest, env, fuel, &current_ast) else if (maybe_syntax) |s| expandSyntaxRules(interp, s, rest, env, fuel, &current_ast) else if (first.is_symbol("quote")) evalQuote(rest, env) else if (first.is_symbol("quasiquote")) evalQuasiquote(interp, rest, env, fuel) else if (first.is_symbol("import")) evalImport(interp, rest, env, fuel) else if (first.is_symbol("if")) evalIf(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("cond")) evalCond(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("case")) evalCase(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("and")) evalAnd(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("or")) evalOr(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("define")) evalDefine(interp, rest, env, fuel) else if (first.is_symbol("define-macro")) evalDefineMacro(interp, rest, env) else if (first.is_symbol("define-syntax")) evalDefineSyntax(interp, rest, env) else if (first.is_symbol("let-syntax") or first.is_symbol("letrec-syntax")) evalLetSyntax(interp, rest, env, fuel) else if (first.is_symbol("set!")) evalSet(interp, rest, env, fuel) else if (first.is_symbol("lambda")) evalLambda(rest, env) else if (first.is_symbol("begin")) evalBegin(interp, rest, env, fuel, &current_ast) else if (first.is_symbol("let") or first.is_symbol("let*")) evalLet(interp, first, rest, env, fuel, &current_ast, &current_env) else if (first.is_symbol("letrec")) evalLetRec(interp, ast.*, env, fuel) else if (first.is_symbol("delay")) evalDelay(env, rest) else if (first.is_symbol("do")) evalDo(interp, rest, env, fuel) else if (first.is_symbol("try")) evalTry(interp, rest, env, fuel) else evalApplication(interp, first, rest, env, fuel, &current_ast, &current_env);

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
