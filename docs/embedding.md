# Embedding Guide

Elz is designed to run inside a Zig application. The host creates an interpreter, exposes the functions scripts may call, evaluates code, and reads the results back. This guide covers that API. The generated [Zig API reference](zig-api/index.html) documents every declaration.

## The Interpreter

```zig
const elz = @import("elz");

var interp = try elz.Interpreter.init(.{});
defer interp.deinit();
```

`Interpreter.init` takes a `SandboxFlags` value (see [Sandboxing](#sandboxing)), sets up the garbage collector, builds the global environment with every enabled primitive, and loads the standard library. Creating an interpreter is not free (the standard library is compiled on every `init`), so keep one per script context rather than one per evaluation.

All memory that scripts allocate is managed by the Boehm-Demers-Weiser collector. The collector scans the stack and registers of the calling thread, so values held in Zig locals stay alive while they are in use. If you store an `Interpreter` or Element 0 values in memory the collector cannot see, such as a heap allocation from a different allocator, register that region with `elz.gc_add_roots`, or allocate it with `elz.gc_allocator` as the REPL does.

## Evaluating Code

```zig
var fuel: u64 = 1_000_000;
const value = try interp.evalString("(+ 1 2)", &fuel);
```

`evalString` parses every form in the string, compiles them, runs them, and returns the value of the last one. `fuel` is an instruction budget. Every VM instruction decrements it, including instructions run by callbacks from primitives such as `map` and `apply`, and list primitives charge one unit per element they visit. When it reaches zero the evaluation stops with `ElzError.ExecutionBudgetExceeded`. Pass `std.math.maxInt(u64)` when you do not want a budget.

`evalForm` evaluates a single already-parsed form. The REPL uses it with `elz.parser.readAll` to report errors per form:

```zig
var forms = try elz.parser.readAll(source, interp.allocator);
defer forms.deinit(interp.allocator);
for (forms.items) |form| {
    var fuel: u64 = std.math.maxInt(u64);
    const result = interp.evalForm(&form, &fuel) catch |err| {
        // interp.last_error_message, last_error_file, and last_error_line describe the failure
        return err;
    };
    _ = result;
}
```

Results are `elz.Value`, a tagged union. Common cases:

```zig
switch (value) {
    .exact_integer => |n| std.debug.print("{d}\n", .{n}),
    .number => |f| std.debug.print("{d}\n", .{f}),
    .string => |s| std.debug.print("{s}\n", .{s.bytes}),
    .boolean => |b| std.debug.print("{}\n", .{b}),
    .pair, .nil => {
        const items = try elz.listToSlice(interp.allocator, value);
        // ...
    },
    else => {},
}
```

`elz.write` prints any value in its written representation, `elz.listToSlice` and `elz.sliceToList` convert between Element 0 lists and Zig slices, and `elz.core.makeString` creates a string value from bytes you own.

## Exposing Zig Functions

`define_foreign_func` registers a Zig function as an Element 0 procedure. Argument and return types are converted automatically:

```zig
fn greet(name: []const u8) []const u8 { ... }
fn is_even(n: i64) bool { ... }

try elz.define_foreign_func(interp.root_env, "greet", greet);
try elz.define_foreign_func(interp.root_env, "even-number?", is_even);
```

Supported parameter types are `f64` and the other floats, integers of any width (range-checked, so a script passing `300` to a `u8` parameter gets an error), `bool`, `[]const u8` (strings and symbols), `?T` (`#f` maps to null), `elz.Value` for values passed through unchanged, Zig structs (mapped from Element 0 hash maps by field name), and `elz.ffi.ElzCallback`, which wraps an Element 0 procedure so Zig can call it. Return values convert the same way. Floats become inexact numbers, integers become exact integers, `bool` becomes a boolean, `[]const u8` becomes a fresh string, `void` becomes the empty list, optionals map null to `#f`, and structs become hash maps. A function may return an error union; a returned error becomes `ElzError.ForeignFunctionError` with the error name as the message.

Functions with zero, one, or two parameters are mapped directly. For more parameters, or a variable count, take the evaluated arguments as a slice:

```zig
fn sum(allocator: std.mem.Allocator, args: []const elz.Value) !elz.Value {
    _ = allocator;
    var total: i64 = 0;
    for (args) |a| {
        if (a != .exact_integer) return error.ExpectedInteger;
        total += a.exact_integer;
    }
    return .{ .exact_integer = total };
}
```

The first parameter must be exactly `std.mem.Allocator` and the second exactly `[]const elz.Value` for this form to be recognized. A procedure that needs the interpreter itself, for example to consult the fuel counter, can be bound directly as a `Value.procedure` with the primitive signature used in `src/elz/primitives/`; see `env_setup.zig` for how the built-ins are registered.

To call an Element 0 procedure from Zig, take an `ElzCallback` parameter and invoke it:

```zig
fn apply_twice(cb: elz.ffi.ElzCallback, x: elz.Value) !elz.Value {
    const once = try cb.call(&.{x});
    return cb.call(&.{once});
}
```

Scripts can also receive opaque Zig pointers (`Value.opaque_pointer`) and hand them back unchanged, which is how a host exposes handles to its own objects.

## Sandboxing

`SandboxFlags` selects what a script can reach. Every group is enabled by default.

```zig
var interp = try elz.Interpreter.init(.{
    .enable_filesystem = false, // no file ports, load, include, or module imports
    .enable_process = false,    // no exit and no environment variables
    .enable_io = false,         // no display, write, or read on the standard ports
    .time_limit_ms = 100,       // stop after 100 milliseconds of wall-clock time
});
```

A disabled group's procedures are not bound at all, so a script that calls one gets `SymbolNotFound`. The compile-time forms that read files (`include`, `include-ci`, and `import`) report `PermissionDenied` when the filesystem is disabled. The other groups are `enable_math`, `enable_lists`, `enable_predicates`, and `enable_strings`.

The time limit is checked every few hundred instructions and inside the list primitives, and starts with the outermost `evalString` or `evalForm` call, so nested evaluation (`eval`, `load`, macro expansion) cannot extend it. Combine it with the fuel counter for a deterministic bound.

Fixed limits protect the host from hostile input and report an error instead of exhausting the native stack. Expressions nest at most 1000 levels in the compiler and 2048 levels in the reader, a JSON document nests at most 512 levels, the VM holds at most 65536 call frames, and primitive callbacks (`map`, `apply`, `call/cc`, `guard`, and the like) nest at most 600 levels deep.

Scripts run on the calling thread, and an `Interpreter` is not thread-safe. Use one interpreter per thread.

## Error Handling

Every evaluation entry point returns `elz.ElzError!Value`. The error tag classifies the failure (`SymbolNotFound`, `InvalidArgument`, `WrongArgumentCount`, `DivisionByZero`, `UserError` for `raise` and `error`, `StackOverflow`, `ExecutionBudgetExceeded`, `TimeLimitExceeded`, and so on). Several fields on the interpreter add detail:

- `last_error_message`: a human-readable message, when one is available.
- `last_error_file` and `last_error_line`: the location of the failing form, when the source was read with location tracking (`parser.readAllTracked`, which `evalString` uses).
- `backtrace`: the call frames the error unwound through, innermost first, each with a procedure name, file, and line. It is filled only while `collect_backtrace` is true, because errors caught by `try` inside the script pay for the recording too. The REPL turns it on; embedders that show errors to users should do the same and clear the list before each evaluation.

A value raised by a script (`(raise 'oops)`) arrives as `UserError`; inside the script, `guard` and `with-exception-handler` see the raised object itself. Runtime errors caught inside a script are error objects with a kind, so `file-error?` and `read-error?` work on them.

Clear `last_error_message` before each evaluation if you display it, as the REPL does; it is only overwritten on failure.

## Modules and Files

When the filesystem is enabled, scripts can `(load "file.elz")`, `(include "file.elz")`, and `(import "module.elz")`, all relative to the process working directory. `define-library` and `(import (name ...))` provide R7RS-style libraries within a program. See the [Language Reference](language-reference.md#libraries-and-modules).

## The REPL as a Reference

`src/main.zig` is a complete embedding. It allocates the interpreter with `gc_allocator`, registers its memory as a GC root, captures `argv` for `command-line`, and runs a read-eval-print loop with `evalForm` and per-form error reporting. The programs in `examples/zig/` are smaller and show the FFI patterns above.
