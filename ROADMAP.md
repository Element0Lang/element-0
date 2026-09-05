# Roadmap

This document includes the roadmap for the Element 0 programming language and Elz.
It outlines the features to be implemented and their current status.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change without notice.

### Design Decisions

* Continuations are delimited, not first-class. Elz provides escape continuations
  (`call/ec`, with `call-with-current-continuation` as an alias) and delimited
  continuations (`shift`/`reset`) instead of full re-entrant `call/cc`. Full
  `call/cc` interacts badly with the Zig FFI boundary because native frames cannot be
  captured. Delimited continuations cover the practical use cases, such as generators,
  early exit, and async patterns. This is a deliberate, permanent departure from the
  standard, and it matches what practical embedded Schemes do.
* The numeric tower is kept. Exact integers of arbitrary size, exact rationals, complex
  numbers, and exact/inexact tagging are implemented.

---

## Implemented

### Host API and FFI

* Embedding API: `Interpreter` and `Environment` structs, `init`/`deinit` lifecycle,
  `evalString`, and global variable definition from Zig.
* FFI: variadic Zig functions, graceful error propagation, opaque pointers to Zig
  data, complex Zig struct passing, Elz closures as Zig callbacks, and automatic
  conversions for `bool`, `[]const u8`, and `?T`.
* Sandboxing: a sandboxed mode that restricts I/O and sensitive operations, and
  execution time limits (`time_limit_ms` in `SandboxFlags`) backed by a VM fuel counter.

### Language Core

The R7RS-small core is complete and verified by the test suite and the vendored
conformance suite.

* Data types: booleans, the full numeric tower, symbols, pairs and lists, characters,
  UTF-8 strings, procedures and closures, vectors, hash maps, and ports.
* Special forms: `quote`, `if`, `define`, `set!`, `lambda` (fixed, variadic, and
  dotted-rest), `begin`, `let`/`let*`/`letrec` (including named `let`), `cond`, `case`,
  `and`, `or`, `when`, `unless`, `do`, `delay`, and internal definitions.
* Bytecode VM: stack-based with call frames and upvalues. Proper tail calls are
  implemented with a dedicated `tail_call` opcode that reuses the current frame.
* Macros: `define-syntax`, `let-syntax`, `letrec-syntax`, and `syntax-rules` with nested
  and mid-list ellipsis, custom ellipsis identifiers, and hygiene (introduced identifiers
  resolve from the definition scope), plus `define-macro` for procedural macros.
* Standard procedures: equivalence and type predicates, the full pair and list section,
  numeric operations with radix-aware `number->string` and `string->number`, the full
  string and character sections (including all `-ci` comparisons), vectors, hash maps,
  `apply`, `eval`, `delay`/`force`, `values`/`call-with-values`, `dynamic-wind`, and
  `call/ec`.
* I/O: `read`, `write`, `display`, file ports, `read-line`, `read-char`, `peek-char`,
  `char-ready?`, `current-input-port`, `current-output-port`, `with-input-from-file`,
  `call-with-input-file` and friends, and `load`.
* Beyond R7RS-small: error handling (`try`/`catch`), a module system, regular expressions
  (NFA engine), `format`, JSON serialization, OS and filesystem procedures, date and
  time, `gensym`, and list utilities (`filter`, `fold-left`, and `fold-right`).

---

## Phase 1: Numeric Completeness and Small Library Gaps

This phase is leaf work; each item is a new primitive over machinery that already
exists. The complex and rational values already exist in the tower, so this phase
exposes the standard interface to them.

* Exact integers of arbitrary size
    * [x] Integer arithmetic, comparison, division, `gcd`, `lcm`, `expt`, and
      `exact-integer-sqrt` promote past the i64 range instead of overflowing
    * [ ] Rationals with components outside the i64 range
* Rational accessors
    * [x] `numerator`, `denominator`
    * [x] `rationalize`
* Complex accessors and constructors (`(scheme complex)`)
    * [x] `make-rectangular`, `make-polar`
    * [x] `real-part`, `imag-part`, `magnitude`, `angle`
* R7RS numeric names and predicates
    * [x] `exact`, `inexact` (keep `exact->inexact`/`inexact->exact` as aliases)
    * [x] `exact-integer?`, `exact-integer-sqrt`, `square`
    * [x] `finite?`, `infinite?`, `nan?`
    * [x] `floor/`, `floor-quotient`, `floor-remainder`
    * [x] `truncate/`, `truncate-quotient`, `truncate-remainder`
* Small list, string, vector, and character completions (mostly implementable in
  `std.elz`)
    * [x] `make-list`, `list-copy`, `list-set!`
    * [x] `string-map`, `string-for-each`, `string-copy!`
    * [x] `string-upcase`, `string-downcase`, `string-foldcase`, `char-foldcase`,
      `digit-value`
    * [x] `vector-map`, `vector-for-each`, `vector-copy`, `vector-copy!`,
      `vector-append`, `vector->string`, `string->vector`
    * [x] `symbol=?`, `boolean=?`
    * [x] `write-string`

## Phase 2: Full `syntax-rules` and Derived Syntax

Users hit missing ellipsis support immediately when porting Scheme macros, so this
phase has the highest value. It requires restructuring the matcher and expander in
`macros.zig` to track ellipsis depth per pattern variable.

* Expander rewrite
    * [x] Nested ellipsis patterns
    * [x] Mid-list (non-tail) ellipsis patterns
    * [x] `_` wildcard patterns
    * [x] Custom ellipsis identifier (`(syntax-rules ooo (lit ...) rules ...)`)
    * [x] `(<ellipsis> <template>)` escape in templates
    * [x] `syntax-error`
    * [x] Hygiene: introduced identifiers resolve from the definition scope, so
      use-site bindings cannot capture them and template keywords keep their
      meaning under shadowing
* Derived forms unlocked by the expander
    * [x] `let-values`, `let*-values`, `define-values`
    * [x] `case-lambda`
    * [x] `case` with `=>` clauses
    * [x] `cond-expand` (with a `features` procedure)

## Phase 3: R7RS Data Types and Port Completions

* Records
    * [x] `define-record-type` (a new tagged value in `core.zig` with constructor,
      predicate, accessors, and modifiers)
* Bytevectors (a good fit for Zig interop)
    * [x] `bytevector`, `make-bytevector`, `bytevector?`, `bytevector-length`
    * [x] `bytevector-u8-ref`, `bytevector-u8-set!`
    * [x] `bytevector-copy`, `bytevector-copy!`, `bytevector-append`
    * [x] `utf8->string`, `string->utf8`
    * [x] `#u8(...)` literals in the parser
* String ports
    * [x] `open-input-string`, `open-output-string`, `get-output-string`
* Binary ports
    * [x] `open-input-bytevector`, `open-output-bytevector`, `get-output-bytevector`
    * [x] `open-binary-input-file`, `open-binary-output-file`
    * [x] `read-u8`, `write-u8`, `peek-u8`, `u8-ready?`, `read-bytevector`,
      `read-bytevector!`, `write-bytevector`
    * [x] `binary-port?`, `textual-port?`
* Port plumbing
    * [x] `current-error-port`
    * [x] `close-port`, `call-with-port`, `flush-output-port`
    * [x] `input-port-open?`, `output-port-open?`
    * [x] `eof-object` (the constructor; the predicate exists)

## Phase 4: Exceptions, Parameters, and Environment

This phase aligns existing machinery (`try`/`catch`, modules, `getenv`, and
`current-time`) with the R7RS surface.

* Exceptions (mapped onto the existing `try`/`catch` mechanism)
    * [x] `raise`, `raise-continuable`
    * [x] `with-exception-handler`
    * [x] `guard`
    * [x] `error` (raises an error object through the try/catch channel)
    * [x] `error-object?`, `error-object-message`, `error-object-irritants`
    * [x] `read-error?`, `file-error?` (read and file errors raised by the runtime are
      error objects of the matching kind)
* Dynamic binding
    * [x] `make-parameter`, `parameterize`
* Process context (`(scheme process-context)`)
    * [x] `get-environment-variable` (a rename of `getenv`),
      `get-environment-variables`
    * [x] `command-line`, `emergency-exit` (`exit` exists)
* Time (`(scheme time)`, over the existing `current-time` and `current-time-ms`)
    * [x] `current-second`, `current-jiffy`, `jiffies-per-second`
* Lazy evaluation completions
    * [x] `promise?`, `delay-force` (`delay`, `force`, and `make-promise` exist)
* Eval and libraries
    * [x] `environment` for `eval`, and `interaction-environment` (opaque markers;
      Elz has a single global environment)
    * [x] `define-library` surface syntax lowering to the existing module system
      (body evaluates in the global environment like file modules; only declared
      exports are bound by `import`)
    * [x] `include`, `include-ci`
* Writer
    * [x] `write` with datum labels for cyclic data (required by R7RS),
      `write-shared`, `write-simple`

## Phase 5: Delimited Continuations

This phase adds `shift`/`reset` to the VM. Frames and the stack are already heap
slices, so capturing a delimited segment copies only the frames between the prompt and
the capture point.

* [x] `reset`/`shift` (prompt and capture opcodes, and segment copy and restore;
  continuations are multi-shot and survive their reset)
* [ ] `dynamic-wind` integration with captured segments (before and after thunks
  do not re-fire when a captured segment is reinstated)
* [x] FFI boundary rule (prompts are per VM run, so a shift inside a nested
  native call raises instead of capturing across the boundary)
* [ ] Documentation of the `call/cc` = `call/ec` semantics (the language reference was
  removed pending a rewrite; see the design decisions above)

---

## Beyond the Standard

* [x] Source locations in errors: the parser records each form's file and line,
  the compiler carries them into a per-instruction line table, and uncaught
  runtime errors report `At: file:line` and a backtrace of the calls that led
  to the failure (`Interpreter.collect_backtrace`).
* [x] R7RS conformance suite: Chibi Scheme's r7rs-tests.scm is vendored under
  `tests/vendor/` and runs via `make test-conformance`. Current score: 976 of
  977 checks pass. The remaining case re-enters a `dynamic-wind` through a full
  continuation. The suite reports but does not gate the build.
* [ ] Documentation: a language reference covering the lexical syntax, special forms,
  standard procedures, extensions, and deviations (removed pending a rewrite). The
  embedding API is covered by the generated API documentation.
* [ ] Performance: a benchmark suite tracked over time (see `benches/`).
* [x] WebAssembly: the library and examples build for `wasm32-wasi`, with an
  arena in place of the Boehm collector (memory is reclaimed only at `deinit`).
* [ ] A precise garbage collector, which would remove the C dependency, make
  memory use predictable, and give wasm builds real collection.
