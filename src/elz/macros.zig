/// Macro expansion routines used by the compiler.
///
/// `expandMacro` handles `define-macro` transformers and `expandSyntaxRules`
/// handles `syntax-rules` transformers. Both are called by compiler.zig at
/// compile time.
const std = @import("std");
const core = @import("core.zig");
const Value = core.Value;
const Environment = core.Environment;
const ElzError = core.ElzError;
const interpreter = @import("interpreter.zig");

// ---------------------------------------------------------------------------
// define-macro expansion
// ---------------------------------------------------------------------------

fn cons(allocator: std.mem.Allocator, car: Value, cdr: Value) ElzError!Value {
    const p = allocator.create(core.Pair) catch return ElzError.OutOfMemory;
    p.* = .{ .car = car, .cdr = cdr };
    return Value{ .pair = p };
}

fn quoted(allocator: std.mem.Allocator, v: Value) ElzError!Value {
    return cons(allocator, Value{ .symbol = "quote" }, try cons(allocator, v, .nil));
}

/// Expands a define-macro transformer `m` applied to `rest` in `env`.
/// Called by compiler.zig at compile time.
///
/// The body is evaluated as `((lambda (params...) body...) 'arg1 'arg2 ...)`:
/// evalForm compiles against the root environment, so parameters must be bound
/// as lambda locals rather than in a runtime Environment the compiled code
/// cannot see.
pub fn expandMacro(interp: *interpreter.Interpreter, m: *core.Macro, rest: Value, env: *Environment, fuel: *u64) ElzError!Value {
    const allocator = env.allocator;

    const lambda_form = try cons(allocator, Value{ .symbol = "lambda" }, try cons(allocator, m.formals, m.body));

    var reversed_args: std.ArrayListUnmanaged(Value) = .empty;
    defer reversed_args.deinit(allocator);
    var current_node = rest;
    while (current_node == .pair) {
        try reversed_args.append(allocator, current_node.pair.car);
        current_node = current_node.pair.cdr;
    }

    var call_form: Value = .nil;
    var ai = reversed_args.items.len;
    while (ai > 0) {
        ai -= 1;
        call_form = try cons(allocator, try quoted(allocator, reversed_args.items[ai]), call_form);
    }
    call_form = try cons(allocator, lambda_form, call_form);

    return interp.evalForm(&call_form, fuel);
}

// ---------------------------------------------------------------------------
// syntax-rules expansion
// ---------------------------------------------------------------------------

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

/// A pattern-variable binding. A variable under n ellipses binds to a tree of
/// depth n: `single` at the leaves, `repeated` at each ellipsis level.
const PatternBinding = union(enum) {
    single: Value,
    repeated: []PatternBinding,
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
};

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
                return try match_ellipsis(allocator, p.car, p.cdr.pair.cdr, input, literals, ellipsis, bindings);
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

/// Matches `(sub_pat <ellipsis> . tail_pattern)` against input. Handles the
/// trailing, mid-list, and dotted-tail forms uniformly: the ellipsis consumes
/// input elements until only enough remain for the tail pattern's pair prefix,
/// and the remainder is matched against the tail pattern. Sub-pattern variables
/// bind one `repeated` level deeper, so nesting composes.
fn match_ellipsis(
    allocator: std.mem.Allocator,
    sub_pat: Value,
    tail_pattern: Value,
    input: Value,
    literals: [][]const u8,
    ellipsis: []const u8,
    bindings: *Bindings,
) MatchError!bool {
    var tail_min: usize = 0;
    var tp = tail_pattern;
    while (tp == .pair) {
        tail_min += 1;
        tp = tp.pair.cdr;
    }

    var input_pairs: usize = 0;
    var node = input;
    while (node == .pair) {
        input_pairs += 1;
        node = node.pair.cdr;
    }
    if (input_pairs < tail_min) return false;
    const repetitions = input_pairs - tail_min;

    var var_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer var_names.deinit(allocator);
    try collect_pattern_vars(allocator, sub_pat, literals, ellipsis, &var_names);

    var accumulators: std.ArrayListUnmanaged(std.ArrayListUnmanaged(PatternBinding)) = .empty;
    defer {
        for (accumulators.items) |*acc| acc.deinit(allocator);
        accumulators.deinit(allocator);
    }
    for (var_names.items) |_| {
        try accumulators.append(allocator, .empty);
    }

    node = input;
    var i: usize = 0;
    while (i < repetitions) : (i += 1) {
        var iter_bindings: Bindings = .empty;
        defer iter_bindings.deinit(allocator);
        const ok = try match_pattern(allocator, sub_pat, node.pair.car, literals, ellipsis, &iter_bindings);
        if (!ok) return false;
        for (var_names.items, 0..) |name, j| {
            const got = iter_bindings.get(name) orelse return error.MissingPatternVar;
            try accumulators.items[j].append(allocator, got);
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

/// Splices a list of lists into one list: ((1 2) (3)) becomes (1 2 3).
fn splice_level(allocator: std.mem.Allocator, list_of_lists: Value) ElzError!Value {
    if (list_of_lists == .nil) return .nil;
    if (list_of_lists != .pair) return ElzError.InvalidArgument;
    const rest = try splice_level(allocator, list_of_lists.pair.cdr);
    return append_lists(allocator, list_of_lists.pair.car, rest);
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
            // (<ellipsis> <template>) escapes ellipsis interpretation in <template>.
            if (ellipsis.len > 0 and p.car == .symbol and std.mem.eql(u8, p.car.symbol, ellipsis) and
                p.cdr == .pair and p.cdr.pair.cdr == .nil)
            {
                return expand_template(allocator, p.cdr.pair.car, "", bindings);
            }
            if (is_ellipsis_marker(p.cdr, ellipsis)) {
                // Count consecutive ellipses: each extra one splices a level.
                var after = p.cdr.pair.cdr;
                var extra: usize = 0;
                while (is_ellipsis_marker(after, ellipsis)) {
                    extra += 1;
                    after = after.pair.cdr;
                }
                var repeated_list = try expand_ellipsis(allocator, p.car, ellipsis, bindings, extra);
                while (extra > 0) : (extra -= 1) {
                    repeated_list = try splice_level(allocator, repeated_list);
                }
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

/// Expands one ellipsis level of `sub_tmpl`: iterates the variables that are
/// `repeated` in the current bindings, descending one binding level per
/// iteration element. `extra` counts additional consecutive ellipses in the
/// template; each recurses one more level before expanding the template.
fn expand_ellipsis(
    allocator: std.mem.Allocator,
    sub_tmpl: Value,
    ellipsis: []const u8,
    bindings: *const Bindings,
    extra: usize,
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
            try iter_bindings.put(allocator, n, original.repeated[i]);
        }
        const expanded = if (extra == 0)
            try expand_template(allocator, sub_tmpl, ellipsis, &iter_bindings)
        else
            try expand_ellipsis(allocator, sub_tmpl, ellipsis, &iter_bindings, extra - 1);
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

const special_form_names: []const []const u8 = &.{
    "quote",        "quasiquote",   "unquote",      "unquote-splicing",
    "if",           "cond",         "case",         "and",
    "or",           "define",       "define-macro", "define-syntax",
    "syntax-rules", "syntax-error", "set!",         "lambda",
    "begin",        "let",          "let*",         "letrec",
    "do",           "delay",        "try",          "catch",
    "import",       "else",         "...",          "_",
};

fn is_special_form_name(name: []const u8) bool {
    for (special_form_names) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
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

/// Builds a `SyntaxRulesMacro` from the body of a `(syntax-rules ...)` form.
/// `name` is the macro name (used for error messages), `body` is the cdr of the
/// `syntax-rules` pair (i.e. everything after the `syntax-rules` keyword), and
/// `env` is the definition environment captured into the transformer.
/// `ellipsis_locally_bound` is true when the caller's lexical scope contains a local binding
/// for `...` (e.g. `(let ((... 2)) (syntax-rules ...))`), which makes `...` an ordinary
/// identifier inside the macro rather than the ellipsis marker.
pub fn buildSyntaxRules(env: *Environment, name: []const u8, body: Value, ellipsis_locally_bound: bool) ElzError!*core.SyntaxRulesMacro {
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
    // enclosing scope (either as a compile-time local or as a runtime env binding).
    // If so, treat "..." as a regular identifier inside this macro.
    const ellipsis: []const u8 = if (std.mem.eql(u8, ellipsis_raw, "...") and
        (ellipsis_locally_bound or env.contains("...")))
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

/// Expands a syntax-rules transformer `sr` applied to `rest` in `env`.
/// Called by compiler.zig at compile time.
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
