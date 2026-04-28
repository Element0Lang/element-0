const core = @import("core.zig");
const ffi = @import("ffi.zig");
const lists = @import("./primitives/lists.zig");
const math = @import("./primitives/math.zig");
const predicates = @import("./primitives/predicates.zig");
const strings = @import("./primitives/strings.zig");
const control = @import("./primitives/control.zig");
const io = @import("./primitives/io.zig");
const modules = @import("./primitives/modules.zig");
const process = @import("./primitives/process.zig");
const vectors = @import("./primitives/vectors.zig");
const hashmaps = @import("./primitives/hashmaps.zig");
const ports = @import("./primitives/ports.zig");
const os = @import("./primitives/os.zig");
const datetime = @import("./primitives/datetime.zig");
const format_mod = @import("./primitives/format.zig");
const json_mod = @import("./primitives/json.zig");
const regex_mod = @import("./primitives/regex.zig");
const interpreter = @import("interpreter.zig");

/// Populates the interpreter's root environment with mathematical primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_math(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "+", core.Value{ .procedure = math.add });
    try interp.root_env.set(interp, "-", core.Value{ .procedure = math.sub });
    try interp.root_env.set(interp, "*", core.Value{ .procedure = math.mul });
    try interp.root_env.set(interp, "/", core.Value{ .procedure = math.div });
    try interp.root_env.set(interp, "<=", core.Value{ .procedure = math.le });
    try interp.root_env.set(interp, "<", core.Value{ .procedure = math.lt });
    try interp.root_env.set(interp, ">=", core.Value{ .procedure = math.ge });
    try interp.root_env.set(interp, ">", core.Value{ .procedure = math.gt });
    try interp.root_env.set(interp, "=", core.Value{ .procedure = math.eq_num });
    try interp.root_env.set(interp, "sqrt", core.Value{ .procedure = math.sqrt });
    try interp.root_env.set(interp, "sin", core.Value{ .procedure = math.sin });
    try interp.root_env.set(interp, "cos", core.Value{ .procedure = math.cos });
    try interp.root_env.set(interp, "tan", core.Value{ .procedure = math.tan });
    try interp.root_env.set(interp, "asin", core.Value{ .procedure = math.asin });
    try interp.root_env.set(interp, "acos", core.Value{ .procedure = math.acos });
    try interp.root_env.set(interp, "atan", core.Value{ .procedure = math.atan });
    try interp.root_env.set(interp, "quotient", core.Value{ .procedure = math.quotient });
    try interp.root_env.set(interp, "remainder", core.Value{ .procedure = math.remainder });
    try interp.root_env.set(interp, "modulo", core.Value{ .procedure = math.modulo });
    try interp.root_env.set(interp, "gcd", core.Value{ .procedure = math.gcd });
    try interp.root_env.set(interp, "lcm", core.Value{ .procedure = math.lcm });
    try interp.root_env.set(interp, "log", core.Value{ .procedure = math.log });
    try interp.root_env.set(interp, "max", core.Value{ .procedure = math.max });
    try interp.root_env.set(interp, "min", core.Value{ .procedure = math.min });
    try interp.root_env.set(interp, "%", core.Value{ .procedure = math.mod });
    try interp.root_env.set(interp, "floor", core.Value{ .procedure = math.floor_fn });
    try interp.root_env.set(interp, "ceiling", core.Value{ .procedure = math.ceiling });
    try interp.root_env.set(interp, "round", core.Value{ .procedure = math.round_fn });
    try interp.root_env.set(interp, "truncate", core.Value{ .procedure = math.truncate });
    try interp.root_env.set(interp, "expt", core.Value{ .procedure = math.expt });
    try interp.root_env.set(interp, "exp", core.Value{ .procedure = math.exp_fn });
    try interp.root_env.set(interp, "even?", core.Value{ .procedure = math.even_p });
    try interp.root_env.set(interp, "odd?", core.Value{ .procedure = math.odd_p });
    try interp.root_env.set(interp, "zero?", core.Value{ .procedure = math.zero_p });
    try interp.root_env.set(interp, "positive?", core.Value{ .procedure = math.positive_p });
    try interp.root_env.set(interp, "negative?", core.Value{ .procedure = math.negative_p });
    try interp.root_env.set(interp, "complex?", core.Value{ .procedure = math.complex_p });
    try interp.root_env.set(interp, "real?", core.Value{ .procedure = math.real_p });
    try interp.root_env.set(interp, "rational?", core.Value{ .procedure = math.rational_p });
    try interp.root_env.set(interp, "exact?", core.Value{ .procedure = math.exact_p });
    try interp.root_env.set(interp, "inexact?", core.Value{ .procedure = math.inexact_p });
    try interp.root_env.set(interp, "exact->inexact", core.Value{ .procedure = math.exact_to_inexact });
    try interp.root_env.set(interp, "inexact->exact", core.Value{ .procedure = math.inexact_to_exact });
}

/// Populates the interpreter's root environment with list manipulation primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_lists(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "cons", core.Value{ .procedure = lists.cons });
    try interp.root_env.set(interp, "car", core.Value{ .procedure = lists.car });
    try interp.root_env.set(interp, "cdr", core.Value{ .procedure = lists.cdr });
    try interp.root_env.set(interp, "list", core.Value{ .procedure = lists.list });
    try interp.root_env.set(interp, "length", core.Value{ .procedure = lists.list_length });
    try interp.root_env.set(interp, "append", core.Value{ .procedure = lists.append });
    try interp.root_env.set(interp, "reverse", core.Value{ .procedure = lists.reverse });
    try interp.root_env.set(interp, "map", core.Value{ .procedure = lists.map });
    try interp.root_env.set(interp, "list-ref", core.Value{ .procedure = lists.list_ref });
    try interp.root_env.set(interp, "list-tail", core.Value{ .procedure = lists.list_tail });
    try interp.root_env.set(interp, "memq", core.Value{ .procedure = lists.memq });
    try interp.root_env.set(interp, "assq", core.Value{ .procedure = lists.assq });
    try interp.root_env.set(interp, "pair?", core.Value{ .procedure = lists.is_pair });
    try interp.root_env.set(interp, "set-car!", core.Value{ .procedure = lists.set_car });
    try interp.root_env.set(interp, "set-cdr!", core.Value{ .procedure = lists.set_cdr });
}

/// Populates the interpreter's root environment with predicate primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_predicates(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "null?", core.Value{ .procedure = predicates.is_null });
    try interp.root_env.set(interp, "boolean?", core.Value{ .procedure = predicates.is_boolean });
    try interp.root_env.set(interp, "symbol?", core.Value{ .procedure = predicates.is_symbol });
    try interp.root_env.set(interp, "number?", core.Value{ .procedure = predicates.is_number });
    try interp.root_env.set(interp, "string?", core.Value{ .procedure = predicates.is_string });
    try interp.root_env.set(interp, "list?", core.Value{ .procedure = predicates.is_list });
    try interp.root_env.set(interp, "pair?", core.Value{ .procedure = predicates.is_pair });
    try interp.root_env.set(interp, "procedure?", core.Value{ .procedure = predicates.is_procedure });
    try interp.root_env.set(interp, "eq?", core.Value{ .procedure = predicates.is_eq });
    try interp.root_env.set(interp, "eqv?", core.Value{ .procedure = predicates.is_eqv });
    try interp.root_env.set(interp, "equal?", core.Value{ .procedure = predicates.is_equal });
    try interp.root_env.set(interp, "char?", core.Value{ .procedure = predicates.is_char });
    try interp.root_env.set(interp, "integer?", core.Value{ .procedure = predicates.is_integer });
    try interp.root_env.set(interp, "not", core.Value{ .procedure = predicates.logical_not });
}

/// Populates the interpreter's root environment with string manipulation primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_strings(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "symbol->string", core.Value{ .procedure = strings.symbol_to_string });
    try interp.root_env.set(interp, "string->symbol", core.Value{ .procedure = strings.string_to_symbol });
    try interp.root_env.set(interp, "string-length", core.Value{ .procedure = strings.string_length });
    try interp.root_env.set(interp, "string-append", core.Value{ .procedure = strings.string_append });
    try interp.root_env.set(interp, "char=?", core.Value{ .procedure = strings.char_eq });
    try interp.root_env.set(interp, "char<?", core.Value{ .procedure = strings.char_lt });
    try interp.root_env.set(interp, "char>?", core.Value{ .procedure = strings.char_gt });
    try interp.root_env.set(interp, "char<=?", core.Value{ .procedure = strings.char_le });
    try interp.root_env.set(interp, "char>=?", core.Value{ .procedure = strings.char_ge });
    try interp.root_env.set(interp, "char-ci=?", core.Value{ .procedure = strings.char_ci_eq });
    try interp.root_env.set(interp, "char-ci<?", core.Value{ .procedure = strings.char_ci_lt });
    try interp.root_env.set(interp, "char-ci>?", core.Value{ .procedure = strings.char_ci_gt });
    try interp.root_env.set(interp, "char-ci<=?", core.Value{ .procedure = strings.char_ci_le });
    try interp.root_env.set(interp, "char-ci>=?", core.Value{ .procedure = strings.char_ci_ge });
    try interp.root_env.set(interp, "char-alphabetic?", core.Value{ .procedure = strings.char_alphabetic_p });
    try interp.root_env.set(interp, "char-numeric?", core.Value{ .procedure = strings.char_numeric_p });
    try interp.root_env.set(interp, "char-whitespace?", core.Value{ .procedure = strings.char_whitespace_p });
    try interp.root_env.set(interp, "char-upper-case?", core.Value{ .procedure = strings.char_upper_case_p });
    try interp.root_env.set(interp, "char-lower-case?", core.Value{ .procedure = strings.char_lower_case_p });
    try interp.root_env.set(interp, "char-upcase", core.Value{ .procedure = strings.char_upcase });
    try interp.root_env.set(interp, "char-downcase", core.Value{ .procedure = strings.char_downcase });
    try interp.root_env.set(interp, "char->integer", core.Value{ .procedure = strings.char_to_integer });
    try interp.root_env.set(interp, "integer->char", core.Value{ .procedure = strings.integer_to_char });
    try interp.root_env.set(interp, "string-ref", core.Value{ .procedure = strings.string_ref });
    try interp.root_env.set(interp, "substring", core.Value{ .procedure = strings.substring });
    try interp.root_env.set(interp, "number->string", core.Value{ .procedure = strings.number_to_string });
    try interp.root_env.set(interp, "string->number", core.Value{ .procedure = strings.string_to_number });
    try interp.root_env.set(interp, "string-split", core.Value{ .procedure = strings.string_split });
    try interp.root_env.set(interp, "make-string", core.Value{ .procedure = strings.make_string });
    try interp.root_env.set(interp, "string=?", core.Value{ .procedure = strings.string_eq });
    try interp.root_env.set(interp, "string<?", core.Value{ .procedure = strings.string_lt });
    try interp.root_env.set(interp, "string>?", core.Value{ .procedure = strings.string_gt });
    try interp.root_env.set(interp, "string<=?", core.Value{ .procedure = strings.string_le });
    try interp.root_env.set(interp, "string>=?", core.Value{ .procedure = strings.string_ge });
    try interp.root_env.set(interp, "string-ci=?", core.Value{ .procedure = strings.string_ci_eq });
    try interp.root_env.set(interp, "string-ci<?", core.Value{ .procedure = strings.string_ci_lt });
    try interp.root_env.set(interp, "string-ci>?", core.Value{ .procedure = strings.string_ci_gt });
    try interp.root_env.set(interp, "string-ci<=?", core.Value{ .procedure = strings.string_ci_le });
    try interp.root_env.set(interp, "string-ci>=?", core.Value{ .procedure = strings.string_ci_ge });
    try interp.root_env.set(interp, "string", core.Value{ .procedure = strings.string_constructor });
    try interp.root_env.set(interp, "string-copy", core.Value{ .procedure = strings.string_copy });
    try interp.root_env.set(interp, "string-set!", core.Value{ .procedure = strings.string_set });
    try interp.root_env.set(interp, "string-fill!", core.Value{ .procedure = strings.string_fill });
    try interp.root_env.set(interp, "string->list", core.Value{ .procedure = strings.string_to_list });
    try interp.root_env.set(interp, "list->string", core.Value{ .procedure = strings.list_to_string });
    try interp.root_env.set(interp, "gensym", core.Value{ .procedure = strings.gensym });
}

/// Populates the interpreter's root environment with control-related primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_control(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "apply", core.Value{ .procedure = control.apply });
    try interp.root_env.set(interp, "eval", core.Value{ .procedure = control.eval_proc });
    try interp.root_env.set(interp, "force", core.Value{ .procedure = control.force });
    try interp.root_env.set(interp, "values", core.Value{ .procedure = control.values });
    try interp.root_env.set(interp, "call-with-values", core.Value{ .procedure = control.call_with_values });
    try interp.root_env.set(interp, "with-input-from-file", core.Value{ .procedure = control.with_input_from_file });
    try interp.root_env.set(interp, "with-output-to-file", core.Value{ .procedure = control.with_output_to_file });
    try interp.root_env.set(interp, "call-with-escape-continuation", core.Value{ .procedure = control.call_with_escape_continuation });
    try interp.root_env.set(interp, "call/ec", core.Value{ .procedure = control.call_with_escape_continuation });
}

/// Populates the interpreter's root environment with I/O primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_io(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "display", core.Value{ .procedure = io.display });
    try interp.root_env.set(interp, "write", core.Value{ .procedure = io.write_proc });
    try interp.root_env.set(interp, "newline", core.Value{ .procedure = io.newline });
    try interp.root_env.set(interp, "load", core.Value{ .procedure = io.load });
    try interp.root_env.set(interp, "read-string", core.Value{ .procedure = io.read_string });
}

/// Populates the interpreter's root environment with module-related primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_modules(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "module-ref", core.Value{ .procedure = modules.module_ref });
}

/// Populates the interpreter's root environment with process-related primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_process(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "exit", core.Value{ .procedure = process.exit });
}

/// Populates the interpreter's root environment with OS/filesystem primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_os(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "getenv", core.Value{ .procedure = os.getenv });
    try interp.root_env.set(interp, "file-exists?", core.Value{ .procedure = os.file_exists });
    try interp.root_env.set(interp, "delete-file", core.Value{ .procedure = os.delete_file });
    try interp.root_env.set(interp, "current-directory", core.Value{ .procedure = os.current_directory });
    try interp.root_env.set(interp, "directory-list", core.Value{ .procedure = os.directory_list });
    try interp.root_env.set(interp, "rename-file", core.Value{ .procedure = os.rename_file });
}

/// Populates the interpreter's root environment with date/time primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_datetime(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "current-time", core.Value{ .procedure = datetime.current_time });
    try interp.root_env.set(interp, "current-time-ms", core.Value{ .procedure = datetime.current_time_ms });
    try interp.root_env.set(interp, "time->components", core.Value{ .procedure = datetime.time_to_components });
    try interp.root_env.set(interp, "sleep-ms", core.Value{ .procedure = datetime.sleep_ms });
}

/// Populates the interpreter's root environment with vector manipulation primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_vectors(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "make-vector", core.Value{ .procedure = vectors.make_vector });
    try interp.root_env.set(interp, "vector", core.Value{ .procedure = vectors.vector });
    try interp.root_env.set(interp, "vector-length", core.Value{ .procedure = vectors.vector_length });
    try interp.root_env.set(interp, "vector-ref", core.Value{ .procedure = vectors.vector_ref });
    try interp.root_env.set(interp, "vector-set!", core.Value{ .procedure = vectors.vector_set });
    try interp.root_env.set(interp, "vector-fill!", core.Value{ .procedure = vectors.vector_fill });
    try interp.root_env.set(interp, "vector?", core.Value{ .procedure = vectors.is_vector });
    try interp.root_env.set(interp, "list->vector", core.Value{ .procedure = vectors.list_to_vector });
    try interp.root_env.set(interp, "vector->list", core.Value{ .procedure = vectors.vector_to_list });
}

/// Populates the interpreter's root environment with hash map primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_hashmaps(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "make-hash-map", core.Value{ .procedure = hashmaps.make_hash_map });
    try interp.root_env.set(interp, "hash-map-set!", core.Value{ .procedure = hashmaps.hash_map_set });
    try interp.root_env.set(interp, "hash-map-ref", core.Value{ .procedure = hashmaps.hash_map_get });
    try interp.root_env.set(interp, "hash-map-remove!", core.Value{ .procedure = hashmaps.hash_map_remove });
    try interp.root_env.set(interp, "hash-map-contains?", core.Value{ .procedure = hashmaps.hash_map_contains });
    try interp.root_env.set(interp, "hash-map-count", core.Value{ .procedure = hashmaps.hash_map_count });
    try interp.root_env.set(interp, "hash-map?", core.Value{ .procedure = hashmaps.is_hash_map });
}

/// Populates the interpreter's root environment with formatting primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_format(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "format", core.Value{ .procedure = format_mod.format });
    try interp.root_env.set(interp, "value->string", core.Value{ .procedure = format_mod.value_to_string });
}

/// Populates the interpreter's root environment with JSON serialization primitive functions.
pub fn populate_json(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "json-serialize", core.Value{ .procedure = json_mod.json_serialize });
    try interp.root_env.set(interp, "json-deserialize", core.Value{ .procedure = json_mod.json_deserialize });
}

/// Populates the interpreter's root environment with regex primitive functions.
pub fn populate_regex(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "regex-match?", core.Value{ .procedure = regex_mod.regex_match });
    try interp.root_env.set(interp, "regex-search", core.Value{ .procedure = regex_mod.regex_search });
    try interp.root_env.set(interp, "regex-replace", core.Value{ .procedure = regex_mod.regex_replace });
    try interp.root_env.set(interp, "regex-split", core.Value{ .procedure = regex_mod.regex_split });
}

/// Populates the interpreter's root environment with all primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_globals(interp: *interpreter.Interpreter) !void {
    try populate_math(interp);
    try populate_lists(interp);
    try populate_predicates(interp);
    try populate_strings(interp);
    try populate_control(interp);
    try populate_io(interp);
    try populate_modules(interp);
    try populate_process(interp);
    try populate_hashmaps(interp);
}

/// Populates the interpreter's root environment with port (file I/O) primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_ports(interp: *interpreter.Interpreter) !void {
    try interp.root_env.set(interp, "open-input-file", core.Value{ .procedure = ports.open_input_file });
    try interp.root_env.set(interp, "open-output-file", core.Value{ .procedure = ports.open_output_file });
    try interp.root_env.set(interp, "close-input-port", core.Value{ .procedure = ports.close_input_port });
    try interp.root_env.set(interp, "close-output-port", core.Value{ .procedure = ports.close_output_port });
    try interp.root_env.set(interp, "read-line", core.Value{ .procedure = ports.read_line });
    try interp.root_env.set(interp, "read-char", core.Value{ .procedure = ports.read_char });
    try interp.root_env.set(interp, "peek-char", core.Value{ .procedure = ports.peek_char });
    try interp.root_env.set(interp, "char-ready?", core.Value{ .procedure = ports.char_ready_p });
    try interp.root_env.set(interp, "write-char", core.Value{ .procedure = ports.write_char });
    try interp.root_env.set(interp, "write-port", core.Value{ .procedure = ports.write_to_port });
    try interp.root_env.set(interp, "input-port?", core.Value{ .procedure = ports.is_input_port });
    try interp.root_env.set(interp, "output-port?", core.Value{ .procedure = ports.is_output_port });
    try interp.root_env.set(interp, "port?", core.Value{ .procedure = ports.is_port });
    try interp.root_env.set(interp, "eof-object?", core.Value{ .procedure = ports.eof_object_p });
    try interp.root_env.set(interp, "current-input-port", core.Value{ .procedure = ports.current_input_port });
    try interp.root_env.set(interp, "current-output-port", core.Value{ .procedure = ports.current_output_port });
    try interp.root_env.set(interp, "read", core.Value{ .procedure = ports.read });
}

/// Defines a foreign function in the given environment.
/// This function uses `ffi.makeForeignFunc` to create a wrapper around a Zig function,
/// making it callable from Elz.
///
/// Parameters:
/// - `env`: The environment in which to define the foreign function.
/// - `name`: The name of the function as it will be known in Elz.
/// - `func`: The Zig function to be exposed to Elz. This must be a comptime-known function.
pub fn define_foreign_func(env: *core.Environment, name: []const u8, comptime func: anytype) !void {
    const ff = ffi.makeForeignFunc(func);
    const owned_name = try env.allocator.dupe(u8, name);
    try env.bindings.put(owned_name, core.Value{ .foreign_procedure = ff });
}

const std = @import("std");

test "populate_math adds math functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_math = true }) catch unreachable;
    defer interp.deinit();

    // Check that + is defined
    const plus = try interp.root_env.get("+", &interp);
    try std.testing.expect(plus == .procedure);

    // Check other math functions
    const sqrt = try interp.root_env.get("sqrt", &interp);
    try std.testing.expect(sqrt == .procedure);
}

test "populate_lists adds list functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_lists = true }) catch unreachable;
    defer interp.deinit();

    const cons = try interp.root_env.get("cons", &interp);
    try std.testing.expect(cons == .procedure);

    const car = try interp.root_env.get("car", &interp);
    try std.testing.expect(car == .procedure);
}

test "populate_predicates adds predicate functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_predicates = true }) catch unreachable;
    defer interp.deinit();

    const is_null = try interp.root_env.get("null?", &interp);
    try std.testing.expect(is_null == .procedure);

    const is_eq = try interp.root_env.get("eq?", &interp);
    try std.testing.expect(is_eq == .procedure);
}

test "populate_strings adds string functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_strings = true }) catch unreachable;
    defer interp.deinit();

    const str_len = try interp.root_env.get("string-length", &interp);
    try std.testing.expect(str_len == .procedure);
}

test "populate_io adds io functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_io = true }) catch unreachable;
    defer interp.deinit();

    const display = try interp.root_env.get("display", &interp);
    try std.testing.expect(display == .procedure);
}

test "define_foreign_func creates callable function" {
    const allocator = std.testing.allocator;

    const env = try allocator.create(core.Environment);
    env.* = .{
        .bindings = std.StringHashMap(core.Value).init(allocator),
        .outer = null,
        .allocator = allocator,
    };
    defer allocator.destroy(env);
    defer {
        var it = env.bindings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        env.bindings.deinit();
    }

    const testFn = struct {
        fn add(a: f64, b: f64) f64 {
            return a + b;
        }
    }.add;

    try define_foreign_func(env, "my-add", testFn);

    const val = env.bindings.get("my-add");
    try std.testing.expect(val != null);
    try std.testing.expect(val.? == .foreign_procedure);
}
