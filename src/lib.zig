//! This module exposes the public API of Elz, the Element 0 scripting engine.
//! It provides a high-level interface for embedding Elz in Zig projects.

// Main scripting engine struct and its configuration.
pub const Interpreter = @import("elz/interpreter.zig").Interpreter;
pub const SandboxFlags = @import("elz/interpreter.zig").SandboxFlags;
pub const BacktraceFrame = @import("elz/interpreter.zig").BacktraceFrame;
pub const MAX_BACKTRACE_FRAMES = @import("elz/interpreter.zig").MAX_BACKTRACE_FRAMES;

// Core data types and errors.
pub const core = @import("elz/core.zig");
pub const Value = core.Value;
pub const Environment = core.Environment;
pub const ElzError = @import("elz/errors.zig").ElzError;
// GC utilities for embedders that allocate the Interpreter on the managed heap
// (like the REPL does); most embedders do not need these.
const _gc = @import("elz/gc.zig");
pub const gc_allocator: @import("std").mem.Allocator = _gc.allocator;
pub const gc_add_roots = _gc.add_roots;

// Helper functions for interacting with Elz values.
pub const write = @import("elz/writer.zig").write;
pub const listToSlice = @import("elz/api_helpers.zig").listToSlice;
pub const sliceToList = @import("elz/api_helpers.zig").sliceToList;

// FFI function for extending Elz with native Zig code, and the FFI module for
// the types a native function may take (`ffi.ElzCallback`, `ffi.Caster`).
pub const define_foreign_func = @import("elz/env_setup.zig").define_foreign_func;
pub const ffi = @import("elz/ffi.zig");

// Advanced API: Direct access to the parser, needed by the REPL.
// Use Interpreter.evalString for normal use; Interpreter.evalForm for per-form REPL loops.
pub const parser = @import("elz/parser.zig");
/// Names of the compiler's special forms, for tools such as REPL completion.
pub const special_form_names = @import("elz/compiler.zig").special_form_names;

// Pull inline `test` blocks from the implementation modules into `make test`. Each
// transitively imports `core`, `interpreter`, `compiler`, `vm`, and the primitives, so the
// full suite of inline unit tests runs together.
test {
    _ = @import("elz/core.zig");
    _ = @import("elz/parser.zig");
    _ = @import("elz/writer.zig");
    _ = @import("elz/primitives/control.zig");
    _ = @import("elz/primitives/format.zig");
    _ = @import("elz/primitives/hashmaps.zig");
    _ = @import("elz/primitives/io.zig");
    _ = @import("elz/primitives/lists.zig");
    _ = @import("elz/primitives/math.zig");
    _ = @import("elz/primitives/modules.zig");
    _ = @import("elz/primitives/ports.zig");
    _ = @import("elz/primitives/predicates.zig");
    _ = @import("elz/primitives/regex.zig");
    _ = @import("elz/primitives/strings.zig");
    _ = @import("elz/primitives/vectors.zig");
}
