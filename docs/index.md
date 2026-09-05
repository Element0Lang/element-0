# Element 0

Element 0 is a small Lisp dialect in the Scheme family, designed to be embedded in Zig applications as a scripting engine.
Elz is its implementation, a bytecode compiler and stack-based virtual machine written in Zig, with the Boehm-Demers-Weiser garbage collector underneath.

## Key Features

* Close to complete R7RS-small: proper tail calls, hygienic `syntax-rules`, records, bytevectors, string and binary ports, parameters, promises, and the exception system. The vendored Chibi Scheme conformance suite passes 976 of 977 checks.
* The full numeric tower: fixnums that promote to arbitrary-precision integers, exact rationals, inexact reals, and complex numbers, with exact comparison across all of them.
* Delimited continuations (`reset` and `shift`) that are multi-shot, plus escape continuations through `call/cc`.
* A small embedding API: one `Interpreter` struct, `evalString`, and `define_foreign_func`, which maps ordinary Zig function signatures to Scheme procedures.
* Sandboxing built in: capability flags for filesystem, process, and I/O access, a wall-clock limit, an instruction budget, and hard nesting limits, so untrusted scripts cannot crash or hang the host.
* Batteries a scripting user expects: JSON, regular expressions, hash maps, `format`, filesystem and time procedures, and Unicode strings with full case mappings.

## How It Fits Together

| Component | Purpose |
|---|---|
| `src/elz/parser.zig` | Reads source text into S-expressions. |
| `src/elz/compiler.zig` | Compiles forms to bytecode, expanding macros at compile time. |
| `src/elz/macros.zig` | The `syntax-rules` matcher and hygienic expander. |
| `src/elz/vm.zig` | Executes bytecode with call frames, upvalues, and prompts. |
| `src/elz/primitives/` | The built-in procedures, grouped by category. |
| `src/stdlib/std.elz` | The part of the standard library written in Element 0 itself. |
| `src/lib.zig` | The public embedding API. |
| `src/main.zig` | The `elz-repl` command-line program. |

## Documentation Sections

- [Getting Started](getting-started.md): building the REPL, running scripts, and adding Elz to a Zig project.
- [Language Reference](language-reference.md): lexical syntax, special forms, macros, exceptions, continuations, libraries, and deviations from R7RS-small.
- [Procedures](procedures.md): every built-in procedure, grouped by category.
- [Embedding Guide](embedding.md): the interpreter lifecycle, exposing Zig functions, sandboxing, and error handling.
- [Examples](examples.md): the example scripts and Zig programs in the repository.
- [Zig API Reference](zig-api/index.html): generated documentation of the Zig source.

!!! note
    Element 0 is in early development. Bugs and breaking changes are expected. Please report problems on the
    [issue tracker](https://github.com/Element0Lang/element-0/issues).
