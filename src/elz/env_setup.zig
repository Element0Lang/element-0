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
const records = @import("./primitives/records.zig");
const bytevectors = @import("./primitives/bytevectors.zig");
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
    try interp.definePrimitive("+", math.add);
    try interp.definePrimitive("-", math.sub);
    try interp.definePrimitive("*", math.mul);
    try interp.definePrimitive("/", math.div);
    try interp.definePrimitive("<=", math.le);
    try interp.definePrimitive("<", math.lt);
    try interp.definePrimitive(">=", math.ge);
    try interp.definePrimitive(">", math.gt);
    try interp.definePrimitive("=", math.eq_num);
    try interp.definePrimitive("sqrt", math.sqrt);
    try interp.definePrimitive("sin", math.sin);
    try interp.definePrimitive("cos", math.cos);
    try interp.definePrimitive("tan", math.tan);
    try interp.definePrimitive("asin", math.asin);
    try interp.definePrimitive("acos", math.acos);
    try interp.definePrimitive("atan", math.atan);
    try interp.definePrimitive("log", math.log);
    try interp.definePrimitive("max", math.max);
    try interp.definePrimitive("min", math.min);
    try interp.definePrimitive("%", math.mod);
    try interp.definePrimitive("exact", math.inexact_to_exact);
    try interp.definePrimitive("inexact", math.exact_to_inexact);
    try interp.definePrimitive("exact-integer?", math.exact_integer_p);
    try interp.definePrimitive("exact-integer-sqrt", math.exact_integer_sqrt);
    try interp.definePrimitive("square", math.square_fn);
    try interp.definePrimitive("finite?", math.finite_p);
    try interp.definePrimitive("infinite?", math.infinite_p);
    try interp.definePrimitive("nan?", math.nan_p);
    try interp.definePrimitive("floor/", math.floor_div);
    try interp.definePrimitive("floor-quotient", math.floor_quotient);
    try interp.definePrimitive("floor-remainder", math.floor_remainder);
    try interp.definePrimitive("truncate/", math.truncate_div);
    try interp.definePrimitive("truncate-quotient", math.truncate_quotient);
    try interp.definePrimitive("truncate-remainder", math.truncate_remainder);
    try interp.definePrimitive("numerator", math.numerator_fn);
    try interp.definePrimitive("denominator", math.denominator_fn);
    try interp.definePrimitive("rationalize", math.rationalize_fn);
    try interp.definePrimitive("make-rectangular", math.make_rectangular);
    try interp.definePrimitive("make-polar", math.make_polar);
    try interp.definePrimitive("real-part", math.real_part);
    try interp.definePrimitive("imag-part", math.imag_part);
    try interp.definePrimitive("magnitude", math.magnitude);
    try interp.definePrimitive("angle", math.angle);
    try interp.definePrimitive("floor", math.floor_fn);
    try interp.definePrimitive("ceiling", math.ceiling);
    try interp.definePrimitive("round", math.round_fn);
    try interp.definePrimitive("truncate", math.truncate);
    try interp.definePrimitive("expt", math.expt);
    try interp.definePrimitive("exp", math.exp_fn);
    try interp.definePrimitive("even?", math.even_p);
    try interp.definePrimitive("odd?", math.odd_p);
    try interp.definePrimitive("zero?", math.zero_p);
    try interp.definePrimitive("positive?", math.positive_p);
    try interp.definePrimitive("negative?", math.negative_p);
    try interp.definePrimitive("abs", math.abs_fn);
    try interp.definePrimitive("exact->inexact", math.exact_to_inexact);
    try interp.definePrimitive("inexact->exact", math.inexact_to_exact);
    try interp.definePrimitive("quotient", math.quotient);
    try interp.definePrimitive("remainder", math.remainder);
    try interp.definePrimitive("modulo", math.modulo);
    try interp.definePrimitive("gcd", math.gcd_fn);
    try interp.definePrimitive("lcm", math.lcm_fn);
}

/// Populates the interpreter's root environment with list manipulation primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_lists(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("cons", lists.cons);
    try interp.definePrimitive("car", lists.car);
    try interp.definePrimitive("cdr", lists.cdr);
    try interp.definePrimitive("list", lists.list);
    try interp.definePrimitive("length", lists.list_length);
    try interp.definePrimitive("append", lists.append);
    try interp.definePrimitive("reverse", lists.reverse);
    try interp.definePrimitive("map", lists.map);
    try interp.definePrimitive("list-ref", lists.list_ref);
    try interp.definePrimitive("list-tail", lists.list_tail);
    try interp.definePrimitive("list-set!", lists.list_set_bang);
    try interp.definePrimitive("memq", lists.memq);
    try interp.definePrimitive("assq", lists.assq);
    try interp.definePrimitive("pair?", lists.is_pair);
    try interp.definePrimitive("set-car!", lists.set_car);
    try interp.definePrimitive("set-cdr!", lists.set_cdr);
}

/// Populates the interpreter's root environment with predicate primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_predicates(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("null?", predicates.is_null);
    try interp.definePrimitive("boolean?", predicates.is_boolean);
    try interp.definePrimitive("symbol?", predicates.is_symbol);
    try interp.definePrimitive("number?", predicates.is_number);
    try interp.definePrimitive("string?", predicates.is_string);
    try interp.definePrimitive("list?", predicates.is_list);
    try interp.definePrimitive("pair?", predicates.is_pair);
    try interp.definePrimitive("procedure?", predicates.is_procedure);
    try interp.definePrimitive("eq?", predicates.is_eq);
    try interp.definePrimitive("eqv?", predicates.is_eqv);
    try interp.definePrimitive("equal?", predicates.is_equal);
    try interp.definePrimitive("char?", predicates.is_char);
    try interp.definePrimitive("integer?", predicates.is_integer);
    try interp.definePrimitive("exact?", predicates.exact_p);
    try interp.definePrimitive("inexact?", predicates.inexact_p);
    try interp.definePrimitive("rational?", predicates.rational_p);
    try interp.definePrimitive("real?", predicates.real_p);
    try interp.definePrimitive("complex?", predicates.complex_p);
    try interp.definePrimitive("not", predicates.logical_not);
}

/// Populates the interpreter's root environment with string manipulation primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_strings(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("symbol->string", strings.symbol_to_string);
    try interp.definePrimitive("string->symbol", strings.string_to_symbol);
    try interp.definePrimitive("string-length", strings.string_length);
    try interp.definePrimitive("string-append", strings.string_append);
    try interp.definePrimitive("char=?", strings.char_eq);
    try interp.definePrimitive("char<?", strings.char_lt);
    try interp.definePrimitive("char>?", strings.char_gt);
    try interp.definePrimitive("char<=?", strings.char_le);
    try interp.definePrimitive("char>=?", strings.char_ge);
    try interp.definePrimitive("char-ci=?", strings.char_ci_eq);
    try interp.definePrimitive("char-ci<?", strings.char_ci_lt);
    try interp.definePrimitive("char-ci>?", strings.char_ci_gt);
    try interp.definePrimitive("char-ci<=?", strings.char_ci_le);
    try interp.definePrimitive("char-ci>=?", strings.char_ci_ge);
    try interp.definePrimitive("char-alphabetic?", strings.char_alphabetic_p);
    try interp.definePrimitive("char-numeric?", strings.char_numeric_p);
    try interp.definePrimitive("char-whitespace?", strings.char_whitespace_p);
    try interp.definePrimitive("char-upper-case?", strings.char_upper_case_p);
    try interp.definePrimitive("char-lower-case?", strings.char_lower_case_p);
    try interp.definePrimitive("char-upcase", strings.char_upcase);
    try interp.definePrimitive("char-foldcase", strings.char_foldcase);
    try interp.definePrimitive("digit-value", strings.digit_value);
    try interp.definePrimitive("string-upcase", strings.string_upcase);
    try interp.definePrimitive("string-downcase", strings.string_downcase);
    try interp.definePrimitive("string-foldcase", strings.string_foldcase);
    try interp.definePrimitive("char-downcase", strings.char_downcase);
    try interp.definePrimitive("char->integer", strings.char_to_integer);
    try interp.definePrimitive("integer->char", strings.integer_to_char);
    try interp.definePrimitive("string-ref", strings.string_ref);
    try interp.definePrimitive("substring", strings.substring);
    try interp.definePrimitive("number->string", strings.number_to_string);
    try interp.definePrimitive("string->number", strings.string_to_number);
    try interp.definePrimitive("string-split", strings.string_split);
    try interp.definePrimitive("make-string", strings.make_string);
    try interp.definePrimitive("string=?", strings.string_eq);
    try interp.definePrimitive("string<?", strings.string_lt);
    try interp.definePrimitive("string>?", strings.string_gt);
    try interp.definePrimitive("string<=?", strings.string_le);
    try interp.definePrimitive("string>=?", strings.string_ge);
    try interp.definePrimitive("string-ci=?", strings.string_ci_eq);
    try interp.definePrimitive("string-ci<?", strings.string_ci_lt);
    try interp.definePrimitive("string-ci<=?", strings.string_ci_le);
    try interp.definePrimitive("string-ci>?", strings.string_ci_gt);
    try interp.definePrimitive("string-ci>=?", strings.string_ci_ge);
    try interp.definePrimitive("string-copy", strings.string_copy);
    try interp.definePrimitive("string->list", strings.string_to_list);
    try interp.definePrimitive("list->string", strings.list_to_string);
    try interp.definePrimitive("string-set!", strings.string_set_bang);
    try interp.definePrimitive("string-fill!", strings.string_fill_bang);
    try interp.definePrimitive("gensym", strings.gensym);
    try interp.definePrimitive("string", strings.string_from_chars);
}

/// Populates the interpreter's root environment with control-related primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_control(interp: *interpreter.Interpreter, flags: interpreter.SandboxFlags) !void {
    try interp.definePrimitive("apply", control.apply);
    try interp.definePrimitive("eval", control.eval_proc);
    try interp.definePrimitive("call-with-escape-continuation", control.call_with_escape_continuation);
    try interp.definePrimitive("call/ec", control.call_with_escape_continuation);
    try interp.definePrimitive("call-with-current-continuation", control.call_with_current_continuation);
    try interp.definePrimitive("call/cc", control.call_with_current_continuation);
    interp.runtime.callcc_fn = control.call_with_current_continuation;
    // dynamic-wind itself is defined in std.elz over these two, so its body
    // runs in the caller's VM run and continuations can be captured inside it.
    try interp.definePrimitive("%wind-push!", control.wind_push);
    try interp.definePrimitive("%wind-pop!", control.wind_pop);
    try interp.definePrimitive("force", control.force);
    try interp.definePrimitive("make-promise", control.make_promise);
    try interp.definePrimitive("%%make-delayed%%", control.make_delayed);
    try interp.definePrimitive("values", control.values);
    try interp.definePrimitive("error", control.error_fn);
    try interp.definePrimitive("raise", control.raise_fn);
    if (flags.enable_process) {
        try interp.definePrimitive("get-environment-variables", os.get_environment_variables);
    }
    try interp.definePrimitive("command-line", os.command_line);
    try interp.definePrimitive("promise?", predicates.promise_p);
    try interp.definePrimitive("raise-continuable", control.raise_continuable_fn);
    try interp.definePrimitive("with-exception-handler", control.with_exception_handler);
    // The built-in record type behind error objects; accessors live in std.elz.
    {
        const rtd = try interp.allocator.create(core.RecordType);
        const field_names = try interp.allocator.alloc([]const u8, 3);
        field_names[0] = "kind";
        field_names[1] = "message";
        field_names[2] = "irritants";
        rtd.* = .{ .name = "error-object", .field_names = field_names };
        interp.runtime.error_rtd = rtd;
        try interp.root_env.set("%error-rtd", core.Value{ .record_type = rtd });
    }
    try interp.definePrimitive("call-with-values", control.call_with_values);
    // Internal primitive backing the try/catch special form; not user-facing.
    try interp.definePrimitive("%%try%%", control.prim_try);
}

/// Populates the interpreter's root environment with I/O primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_io(interp: *interpreter.Interpreter, flags: interpreter.SandboxFlags) !void {
    try interp.definePrimitive("display", io.display);
    try interp.definePrimitive("write", io.write_proc);
    try interp.definePrimitive("write-shared", io.write_shared_proc);
    try interp.definePrimitive("write-simple", io.write_simple_proc);
    try interp.definePrimitive("newline", io.newline);
    // `load` reads and runs a file, so it also needs filesystem access.
    if (flags.enable_filesystem) {
        try interp.definePrimitive("load", io.load);
    }
    try interp.definePrimitive("read-string", io.read_string);
}

/// Populates the interpreter's root environment with module-related primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_modules(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("module-ref", modules.module_ref);
}

/// Populates the interpreter's root environment with process-related primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_process(interp: *interpreter.Interpreter, flags: interpreter.SandboxFlags) !void {
    // `exit` terminates the host process, so it is unavailable when process
    // access is disabled.
    if (!flags.enable_process) return;
    try interp.definePrimitive("exit", process.exit);
}

/// Populates the interpreter's root environment with OS/filesystem primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_os(interp: *interpreter.Interpreter, flags: interpreter.SandboxFlags) !void {
    if (flags.enable_process) {
        try interp.definePrimitive("getenv", os.getenv);
    }
    if (flags.enable_filesystem) {
        try interp.definePrimitive("file-exists?", os.file_exists);
        try interp.definePrimitive("delete-file", os.delete_file);
        try interp.definePrimitive("current-directory", os.current_directory);
        try interp.definePrimitive("directory-list", os.directory_list);
        try interp.definePrimitive("rename-file", os.rename_file);
    }
}

/// Populates the interpreter's root environment with date/time primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_datetime(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("current-time", datetime.current_time);
    try interp.definePrimitive("current-time-ms", datetime.current_time_ms);
    try interp.definePrimitive("time->components", datetime.time_to_components);
    try interp.definePrimitive("sleep-ms", datetime.sleep_ms);
}

/// Populates the interpreter's root environment with vector manipulation primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_vectors(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("make-vector", vectors.make_vector);
    try interp.definePrimitive("vector", vectors.vector);
    try interp.definePrimitive("vector-length", vectors.vector_length);
    try interp.definePrimitive("vector-ref", vectors.vector_ref);
    try interp.definePrimitive("vector-set!", vectors.vector_set);
    try interp.definePrimitive("vector?", vectors.is_vector);
    try interp.definePrimitive("list->vector", vectors.list_to_vector);
    try interp.definePrimitive("vector->list", vectors.vector_to_list);
    try interp.definePrimitive("vector-fill!", vectors.vector_fill_bang);
    try interp.definePrimitive("bytevector", bytevectors.bytevector);
    try interp.definePrimitive("make-bytevector", bytevectors.make_bytevector);
    try interp.definePrimitive("bytevector?", bytevectors.bytevector_p);
    try interp.definePrimitive("bytevector-length", bytevectors.bytevector_length);
    try interp.definePrimitive("bytevector-u8-ref", bytevectors.bytevector_u8_ref);
    try interp.definePrimitive("bytevector-u8-set!", bytevectors.bytevector_u8_set_bang);
    try interp.definePrimitive("bytevector-copy", bytevectors.bytevector_copy);
    try interp.definePrimitive("bytevector-copy!", bytevectors.bytevector_copy_bang);
    try interp.definePrimitive("bytevector-append", bytevectors.bytevector_append);
    try interp.definePrimitive("utf8->string", bytevectors.utf8_to_string);
    try interp.definePrimitive("string->utf8", bytevectors.string_to_utf8);
    try interp.definePrimitive("%make-record-type", records.make_record_type);
    try interp.definePrimitive("%make-record", records.make_record);
    try interp.definePrimitive("%record-of-type?", records.record_of_type_p);
    try interp.definePrimitive("%record-ref", records.record_ref);
    try interp.definePrimitive("%record-set!", records.record_set_bang);
}

/// Populates the interpreter's root environment with hash map primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_hashmaps(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("make-hash-map", hashmaps.make_hash_map);
    try interp.definePrimitive("hash-map-set!", hashmaps.hash_map_set);
    try interp.definePrimitive("hash-map-ref", hashmaps.hash_map_get);
    try interp.definePrimitive("hash-map-remove!", hashmaps.hash_map_remove);
    try interp.definePrimitive("hash-map-contains?", hashmaps.hash_map_contains);
    try interp.definePrimitive("hash-map-count", hashmaps.hash_map_count);
    try interp.definePrimitive("hash-map?", hashmaps.is_hash_map);
}

/// Populates the interpreter's root environment with formatting primitive functions.
///
/// Parameters:
/// - `interp`: A pointer to the interpreter instance.
pub fn populate_format(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("format", format_mod.format);
    try interp.definePrimitive("value->string", format_mod.value_to_string);
}

/// Populates the interpreter's root environment with JSON serialization primitive functions.
pub fn populate_json(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("json-serialize", json_mod.json_serialize);
    try interp.definePrimitive("json-deserialize", json_mod.json_deserialize);
}

/// Populates the interpreter's root environment with regex primitive functions.
pub fn populate_regex(interp: *interpreter.Interpreter) !void {
    try interp.definePrimitive("regex-match?", regex_mod.regex_match);
    try interp.definePrimitive("regex-search", regex_mod.regex_search);
    try interp.definePrimitive("regex-replace", regex_mod.regex_replace);
    try interp.definePrimitive("regex-split", regex_mod.regex_split);
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
pub fn populate_ports(interp: *interpreter.Interpreter, flags: interpreter.SandboxFlags) !void {
    if (flags.enable_filesystem) {
        try interp.definePrimitive("open-input-file", ports.open_input_file);
        try interp.definePrimitive("open-output-file", ports.open_output_file);
        try interp.definePrimitive("open-binary-input-file", ports.open_binary_input_file);
        try interp.definePrimitive("open-binary-output-file", ports.open_binary_output_file);
    }
    try interp.definePrimitive("eof-object", ports.eof_object);
    try interp.definePrimitive("open-input-bytevector", ports.open_input_bytevector);
    try interp.definePrimitive("open-output-bytevector", ports.open_output_bytevector);
    try interp.definePrimitive("get-output-bytevector", ports.get_output_bytevector);
    try interp.definePrimitive("read-u8", ports.read_u8);
    try interp.definePrimitive("peek-u8", ports.peek_u8);
    try interp.definePrimitive("u8-ready?", ports.u8_ready_p);
    try interp.definePrimitive("write-u8", ports.write_u8);
    try interp.definePrimitive("read-bytevector", ports.read_bytevector);
    try interp.definePrimitive("read-bytevector!", ports.read_bytevector_bang);
    try interp.definePrimitive("write-bytevector", ports.write_bytevector);
    try interp.definePrimitive("binary-port?", ports.binary_port_p);
    try interp.definePrimitive("textual-port?", ports.textual_port_p);
    try interp.definePrimitive("close-port", ports.close_port);
    try interp.definePrimitive("input-port-open?", ports.input_port_open_p);
    try interp.definePrimitive("output-port-open?", ports.output_port_open_p);
    try interp.definePrimitive("flush-output-port", ports.flush_output_port);
    try interp.definePrimitive("current-error-port", ports.current_error_port);
    try interp.definePrimitive("open-input-string", ports.open_input_string);
    try interp.definePrimitive("open-output-string", ports.open_output_string);
    try interp.definePrimitive("get-output-string", ports.get_output_string);
    try interp.definePrimitive("close-input-port", ports.close_input_port);
    try interp.definePrimitive("close-output-port", ports.close_output_port);
    try interp.definePrimitive("read-line", ports.read_line);
    try interp.definePrimitive("read-char", ports.read_char);
    try interp.definePrimitive("write-port", ports.write_to_port);
    try interp.definePrimitive("input-port?", ports.is_input_port);
    try interp.definePrimitive("output-port?", ports.is_output_port);
    try interp.definePrimitive("port?", ports.is_port);
    try interp.definePrimitive("eof-object?", ports.eof_object_p);
    try interp.definePrimitive("write-char", ports.write_char);
    try interp.definePrimitive("current-input-port", ports.current_input_port);
    try interp.definePrimitive("current-output-port", ports.current_output_port);
    try interp.definePrimitive("peek-char", ports.peek_char);
    try interp.definePrimitive("char-ready?", ports.char_ready_p);
    try interp.definePrimitive("set-current-output-port!", ports.set_current_output_port_bang);
    try interp.definePrimitive("set-current-input-port!", ports.set_current_input_port_bang);
    try interp.definePrimitive("read", ports.read);
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
    const plus = try interp.root_env.get("+");
    try std.testing.expect(plus == .procedure);

    // Check other math functions
    const sqrt = try interp.root_env.get("sqrt");
    try std.testing.expect(sqrt == .procedure);
}

test "populate_lists adds list functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_lists = true }) catch unreachable;
    defer interp.deinit();

    const cons = try interp.root_env.get("cons");
    try std.testing.expect(cons == .procedure);

    const car = try interp.root_env.get("car");
    try std.testing.expect(car == .procedure);
}

test "populate_predicates adds predicate functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_predicates = true }) catch unreachable;
    defer interp.deinit();

    const is_null = try interp.root_env.get("null?");
    try std.testing.expect(is_null == .procedure);

    const is_eq = try interp.root_env.get("eq?");
    try std.testing.expect(is_eq == .procedure);
}

test "populate_strings adds string functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_strings = true }) catch unreachable;
    defer interp.deinit();

    const str_len = try interp.root_env.get("string-length");
    try std.testing.expect(str_len == .procedure);
}

test "populate_io adds io functions" {
    var interp = interpreter.Interpreter.init(.{ .enable_io = true }) catch unreachable;
    defer interp.deinit();

    const display = try interp.root_env.get("display");
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
