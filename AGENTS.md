# AGENTS.md

Guidance for coding agents working on this repository. It covers what cannot be read off the code. For the layout, run `ls`; for the build targets, run `make help`; for dependencies, read `build.zig.zon`; for the embedding API, read `docs/embedding.md`.

## Mission

Element 0 is a small Lisp dialect based on R7RS-small. Elz, its implementation in Zig, embeds into Zig applications as a scripting engine. Priorities, in order:

1. Correctness and R7RS-small conformance (`ROADMAP.md` records the deliberate deviations).
2. A small, stable public API in `src/lib.zig`.
3. Maintainable, tested code.
4. Linux, macOS, Windows, and `wasm32-wasi` all build.

## Core Rules

- Prefer small, focused changes over large refactoring.
- Add comments only when they clarify non-obvious behavior.
- Do not add features, error handling, or abstractions beyond what the task needs.
- Do not push, tag, or release. Prepare the change and leave the remote to the maintainer.

## Writing Style

Applies to code comments, documentation pages, commit messages, and chat.

- Write in plain English with short sentences and everyday words. No colorful adjectives ("parser", not "robust parser").
- No em dashes. Restructure the sentence or use a semicolon.
- No colons in the middle of a sentence in new prose. A colon that introduces a code block or a list is fine. Reword existing text only when touching it anyway.
- Do not write that something "lives under" or "lives in" a path. Write "is in" or "is defined in".
- Oxford commas in inline lists.
- Headings in title case; minor words (a, an, the, and, but, or, for, in, on, at, to, by, of) stay lowercase unless first. Capitalize only the first part of a hyphenated compound ("Tail-call Detection").
- List items: sentence-case lead-in, never bold ("Upvalue capture: ..." not "**Upvalue Capture**: ..."). Prefer noun phrases for checklist items.
- Capitalize proper nouns (Zig, Scheme, Element 0, Elz, R7RS) and nothing else mid-sentence.
- Complete sentences, no made-up words or abbreviations, participial phrases only sparingly.

## Conventions

- Zig 0.16.0. The Makefile looks for it at `~/.local/share/zig/0.16.0/zig` before falling back to `PATH`.
- `zig fmt` is enforced; `make lint` checks it, `make format` applies it.
- Zig names are `snake_case` for functions and variables and `PascalCase` for types. Element 0 names are `kebab-case`.
- `src/elz/unicode.zig` is generated. Edit `tools/gen_unicode.py` or its template and regenerate; never edit the output.

## Architecture Rules

The pipeline is parser, compiler, VM, writer, tied together by `Interpreter` in `src/elz/interpreter.zig`. Its state is grouped by owner (`flags`, `last_error`, `budget`, `compiler`, `runtime`); the doc comments on those structs say what belongs where. Rules that the types do not enforce:

- A failing primitive returns `interp.fail(err, fmt, args)` with a message that names the operation and the offending operand (`core.typeName` gives the phrase for a value). Never write `last_error` fields directly.
- Built-ins are registered with `interp.definePrimitive(name, f)`, which also records the name so an unlabelled `WrongArgumentCount`, `InvalidArgument`, or `DivisionByZero` still gets attributed.
- A catch site calls `interp.last_error.clear()` after consuming a report.
- `core.Environment` does not know about the interpreter. A caller that wants a message on `SymbolNotFound` attaches it.
- Memory is Boehm-collected on native targets. On wasm, `gc.zig` substitutes an arena that frees nothing until `deinit`. Values must stay reachable from the interpreter, the VM stacks, or a Zig local; nothing else is a root.
- Primitives that call back into Element 0 go through `vm.callProc`, never a VM of their own.

## Validation

Run the narrowest target while iterating (`make test` for a Zig change, `make test-elz` for a language change) and `make test-all` plus `make lint` before declaring done. `make test-conformance` reports the R7RS score and must not go down.

Where tests go:

- Inline `test` blocks in the module they cover, for Zig-level behavior.
- `tests/test_*.elz` for language behavior. No language-facing change is complete without one. When unsure what the correct behavior is, add the case to `tests/test_edge_cases.elz` first.
- `tests/*_prop_test.zig` (Minish) for invariants such as round trips and crash resistance.
- `tests/*_integ_test.zig` for the public embedding API. `repl_integ_test.zig` spawns the built `elz-repl` (path in `build_options.repl_path`); any change to the REPL's output belongs there.

Prefer one targeted assertion per case over broad output comparisons, and keep tests deterministic.

## Documentation

- `src/lib.zig` is the public API. Keep its doc comments current and do not re-export internal types without deliberate intent.
- `docs/` is the MkDocs site and `README.md` is the front page. A change visible to users updates the page that describes it, and stale text found along the way is fixed in the same patch.
- Every code sample in the docs must run. Check it before committing.

## Review and Commit Hygiene

- Review output lists only `P0` (incorrect behavior, broken build or tests) and `P1` (likely bug, missing validation, platform handling) issues, each as severity, `file:line`, issue, why it matters, and the fix direction. No style-only feedback, no praise.
- One logical change per commit. A PR description states the behavioral change, the tests added, and whether it was verified interactively.
