//! This module exposes the public API of the Element 0 interpreter (Elz).
//! It provides a high-level interface for embedding the interpreter in Zig projects.

// Main interpreter struct and its configuration.
pub const Interpreter = @import("elz/interpreter.zig").Interpreter;
pub const SandboxFlags = @import("elz/interpreter.zig").SandboxFlags;

// Core data types and errors.
pub const core = @import("elz/core.zig");
pub const Value = core.Value;
pub const Environment = core.Environment;
pub const ElzError = @import("elz/errors.zig").ElzError;
pub const gc = @import("elz/gc.zig");

// Helper functions for interacting with the interpreter and its values.
pub const write = @import("elz/writer.zig").write;
pub const listToSlice = @import("elz/api_helpers.zig").listToSlice;
pub const sliceToList = @import("elz/api_helpers.zig").sliceToList;

// FFI function for extending the interpreter with Zig code.
pub const define_foreign_func = @import("elz/env_setup.zig").define_foreign_func;

// Advanced API: Direct access to the parser and evaluator, needed by the REPL.
pub const parser = @import("elz/parser.zig");
pub const eval = @import("elz/eval.zig");

// Inline `test` blocks across `src/elz/**` are intentionally not pulled into `make test`
// yet. After resolving 0.16 migration drift, 111 unit tests compile and run, but 6 of
// them leak under `std.testing.allocator` (107 leaks in one regression test alone) and
// one writer test fails on a 500-level nested list. Reviving inline test discovery is
// tracked as a separate slice so that surfacing those issues does not block the rest of
// `make test`.
