# AGENTS.md

This file provides guidance to coding agents collaborating on this repository.

## Mission

Element 0 is a small, embeddable Lisp dialect inspired by Scheme, implemented in Zig.
The interpreter (Elz) is designed to integrate into Zig applications as a scripting engine.
Priorities, in order:

1. Correctness and R5RS compliance where applicable.
2. Clean, minimal public API for embedding into Zig projects.
3. Maintainable and well-tested code.
4. Cross-platform support (Linux, macOS, and Windows).

## Core Rules

- Use English for code, comments, docs, and tests.
- Prefer small, focused changes over large refactoring.
- Add comments only when they clarify non-obvious behavior.
- Do not add features, error handling, or abstractions beyond what is needed for the current task.

## Repository Layout

- `src/lib.zig`: Main public API export module for embedding Elz as a library.
- `src/main.zig`: REPL entry point (`elz-repl` binary).
- `src/elz/core.zig`: Core value types, Environment, and Module definitions.
- `src/elz/interpreter.zig`: Main `Interpreter` struct.
- `src/elz/eval.zig`: Evaluation engine.
- `src/elz/parser.zig`: S-expression parser.
- `src/elz/env_setup.zig`: Environment initialization and FFI setup.
- `src/elz/ffi.zig`: Foreign function interface for calling Zig functions from Element 0.
- `src/elz/gc.zig`: Garbage collection wrapper (uses Boehm-Demers-Weiser GC).
- `src/elz/errors.zig`: Error types.
- `src/elz/writer.zig`: Value serialization and display.
- `src/elz/api_helpers.zig`: Public API helper functions.
- `src/elz/primitives/`: Built-in functions grouped by category (math, lists, strings, control, predicates, vectors, hashmaps, io, ports, datetime, os, modules, and process).
- `src/stdlib/std.elz`: Standard library written in Element 0 itself.
- `examples/zig/`: FFI examples showing how to call Zig functions from Element 0.
- `examples/elz/`: Element 0 script examples.
- `tests/`: Element 0 language-level tests (`test_stdlib.elz`, `test_advanced.elz`, `test_edge_cases.elz`, `test_regression.elz`, `test_module_lib.elz`).
- `.github/workflows/`: CI workflows (tests, lints, docs, and releases).
- `build.zig` / `build.zig.zon`: Zig build configuration and dependencies.
- `Makefile`: GNU Make wrapper around `zig build`.

## Architecture

### Interpreter Pipeline

Source code flows through: Parser (`parser.zig`) -> Evaluator (`eval.zig`) -> Writer (`writer.zig`).
The `Interpreter` struct in `interpreter.zig` ties these together and manages the root environment.

### Core / Primitives Split

- `src/elz/core.zig` defines the value types and environment model.
- `src/elz/primitives/` contains all built-in functions, each in a category-specific module.
- New built-in functions should be added to the appropriate primitives' module.

### FFI

Zig functions can be registered with the interpreter via `env_setup.define_foreign_func()`.
This is the primary extension mechanism for embedding use cases.

### Garbage Collection

Memory is managed by the Boehm-Demers-Weiser GC (`bdwgc`), wrapped in `gc.zig`. The GC is linked as a C library dependency.

### Dependencies

Managed via Zig's package manager (`build.zig.zon`):

- Chilli: CLI framework for the REPL.
- BDWGC (v8.2.12): Garbage collector.
- Linenoise (v2.0): Line editing for the REPL (POSIX only).

## Zig Conventions

- **Zig version**: 0.15.2.
- Formatting is enforced by `zig fmt`. Run `make format` before committing.
- Naming: `snake_case` for functions and variables, `PascalCase` for types and structs.
- Element 0 symbols use `kebab-case` (e.g., `zig-mul`, `string-length`).

## Required Validation

Run both test suites for any change:

| Target          | Command          | What It Runs                                     |
|-----------------|------------------|--------------------------------------------------|
| Zig unit tests  | `make test`      | Inline `test` blocks in `src/**/*.zig`           |
| Language tests  | `make test-elz`  | Element 0 test files in `tests/*.elz`            |
| Lint            | `make lint`      | Checks Zig formatting with `zig fmt --check`     |

For interactive exploration: `make repl`.

## First Contribution Flow

1. Read the relevant source module under `src/elz/`.
2. Implement the smallest possible change.
3. Add or update inline `test` blocks in the changed Zig module. Add Element 0 tests in `tests/` if language behavior changed.
4. Run `make test && make test-elz`.
5. Verify interactively with `make repl` if needed.

Good first tasks:

- Add a new built-in function in the appropriate `src/elz/primitives/` module.
- Add a new standard library function in `src/stdlib/std.elz`.
- Fix an edge case identified in `tests/test_edge_cases.elz`.
- Add a new FFI example in `examples/zig/`.

## Testing Expectations

- Zig unit tests live as inline `test` blocks in the module they cover (`src/elz/*.zig` and `src/elz/primitives/*.zig`).
- Language-level tests live in `tests/*.elz` and are run by the interpreter itself via `make test-elz`.
- No language-facing change is complete without an Element 0 test.

## Change Design Checklist

Before coding:

1. Identify which module(s) the change touches (core, primitives, parser, eval, etc.).
2. Consider whether the change requires updates to the standard library (`std.elz`).
3. Check cross-platform implications if the change touches OS or I/O primitives.

Before submitting:

1. `make test && make test-elz` passes.
2. `make lint` passes.
3. Docs updated if the public API surface changed.

## Commit and PR Hygiene

- Keep commits scoped to one logical change.
- PR descriptions should include:
    1. Behavioral change summary.
    2. Tests added or updated.
    3. Interactive verification done (yes/no).
