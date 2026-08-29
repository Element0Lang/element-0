# Roadmap

This document includes the roadmap for the Element 0 programming language and Elz.
It outlines the features to be implemented and their current status.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change without notice.

### Design Decisions

* Continuations are delimited, not first-class. Elz provides escape continuations
  (`call/ec`, with `call-with-current-continuation` as an alias) and will add delimited
  continuations (`shift`/`reset`, Phase 5) instead of full re-entrant `call/cc`. Full
  `call/cc` interacts badly with the Zig FFI boundary because native frames cannot be
  captured. Delimited continuations cover the practical use cases, such as generators,
  early exit, and async patterns. This is a deliberate, permanent departure from the
  standard, and it matches what practical embedded Schemes do.
* The numeric tower is kept. Exact integers, exact rationals, complex numbers, and
  exact/inexact tagging are already implemented.

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

The R5RS core is complete and verified by the test suite.

* Data types: booleans, the full numeric tower, symbols, pairs and lists, characters,
  UTF-8 strings, procedures and closures, vectors, hash maps, and ports.
* Special forms: `quote`, `if`, `define`, `set!`, `lambda` (fixed, variadic, and
  dotted-rest), `begin`, `let`/`let*`/`letrec` (including named `let`), `cond`, `case`,
  `and`, `or`, `when`, `unless`, `do`, `delay`, and internal definitions.
* Bytecode VM: stack-based with call frames and upvalues. Proper tail calls are
  implemented with a dedicated `tail_call` opcode that reuses the current frame.
* Macros: `define-syntax`, `let-syntax`, `letrec-syntax`, and `syntax-rules` with tail
  ellipsis and identifier-renaming hygiene, plus `define-macro` for procedural macros.
  Nested and mid-list ellipsis are not yet supported; see Phase 2.
* Standard procedures: equivalence and type predicates, the full pair and list section,
  numeric operations with radix-aware `number->string` and `string->number`, the full
  string and character sections (including all `-ci` comparisons), vectors, hash maps,
  `apply`, `eval`, `delay`/`force`, `values`/`call-with-values`, `dynamic-wind`, and
  `call/ec`.
* I/O: `read`, `write`, `display`, file ports, `read-line`, `read-char`, `peek-char`,
  `char-ready?`, `current-input-port`, `current-output-port`, `with-input-from-file`,
  `call-with-input-file` and friends, and `load`.
* Beyond R5RS: error handling (`try`/`catch`), a module system, regular expressions
  (NFA engine), `format`, JSON serialization, OS and filesystem procedures, date and
  time, `gensym`, and list utilities (`filter`, `fold-left`, and `fold-right`).

---

## Phase 1: Numeric Completeness and Small Library Gaps

This phase is leaf work; each item is a new primitive over machinery that already
exists. The complex and rational values already exist in the tower, so this phase
exposes the standard interface to them.

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
    * [ ] Nested ellipsis patterns
    * [ ] Mid-list (non-tail) ellipsis patterns
    * [ ] `_` wildcard patterns
    * [ ] Custom ellipsis identifier (`(syntax-rules ooo (lit ...) rules ...)`)
    * [ ] `syntax-error`
* Derived forms unlocked by the expander
    * [ ] `let-values`, `let*-values`, `define-values`
    * [ ] `case-lambda`
    * [ ] `case` with `=>` clauses
    * [ ] `cond-expand` (with a `features` procedure)

## Phase 3: R7RS Data Types and Port Completions

* Records
    * [ ] `define-record-type` (a new tagged value in `core.zig` with constructor,
      predicate, accessors, and modifiers)
* Bytevectors (a good fit for Zig interop)
    * [ ] `bytevector`, `make-bytevector`, `bytevector?`, `bytevector-length`
    * [ ] `bytevector-u8-ref`, `bytevector-u8-set!`
    * [ ] `bytevector-copy`, `bytevector-copy!`, `bytevector-append`
    * [ ] `utf8->string`, `string->utf8`
* String ports
    * [x] `open-input-string`, `open-output-string`, `get-output-string`
* Binary ports
    * [ ] `open-input-bytevector`, `open-output-bytevector`, `get-output-bytevector`
    * [ ] `open-binary-input-file`, `open-binary-output-file`
    * [ ] `read-u8`, `write-u8`, `peek-u8`, `u8-ready?`, `read-bytevector`,
      `read-bytevector!`, `write-bytevector`
    * [ ] `binary-port?`, `textual-port?`
* Port plumbing
    * [ ] `current-error-port`
    * [ ] `close-port`, `call-with-port`, `flush-output-port`
    * [ ] `input-port-open?`, `output-port-open?`
    * [ ] `eof-object` (the constructor; the predicate exists)

## Phase 4: Exceptions, Parameters, and Environment

This phase aligns existing machinery (`try`/`catch`, modules, `getenv`, and
`current-time`) with the R7RS surface.

* Exceptions (mapped onto the existing `try`/`catch` mechanism)
    * [ ] `raise`, `raise-continuable`
    * [ ] `with-exception-handler`
    * [ ] `guard` (depends on the Phase 2 expander)
    * [ ] `error`, `error-object?`, `error-object-message`, `error-object-irritants`
    * [ ] `read-error?`, `file-error?`
* Dynamic binding
    * [ ] `make-parameter`, `parameterize`
* Process context (`(scheme process-context)`)
    * [ ] `get-environment-variable` (a rename of `getenv`),
      `get-environment-variables`
    * [ ] `command-line`, `emergency-exit` (`exit` exists)
* Time (`(scheme time)`, over the existing `current-time` and `current-time-ms`)
    * [ ] `current-second`, `current-jiffy`, `jiffies-per-second`
* Lazy evaluation completions
    * [ ] `promise?`, `delay-force` (`delay`, `force`, and `make-promise` exist)
* Eval and libraries
    * [ ] `environment` for `eval`, and `interaction-environment`
    * [ ] `define-library` surface syntax lowering to the existing module system
    * [ ] `include`, `include-ci`
* Writer
    * [ ] `write` with datum labels for cyclic data (required by R7RS),
      `write-shared`, `write-simple`

## Phase 5: Delimited Continuations

This phase adds `shift`/`reset` to the VM. Frames and the stack are already heap
slices, so capturing a delimited segment copies only the frames between the prompt and
the capture point.

* [ ] `reset`/`shift` (prompt and capture opcodes, and segment copy and restore)
* [ ] `dynamic-wind` integration with captured segments
* [ ] FFI boundary rule (an error when a `reset`/`shift` pair straddles a native frame)
* [ ] Documentation of the `call/cc` = `call/ec` semantics in the manual

---

## Beyond the Standard

* [ ] Source locations in errors: line and column tracked from the parser through to
  runtime error reports and stack traces.
* [ ] R7RS conformance suite: a vendored external test suite (e.g., Chibi's) as a
  conformance gate with a public compliance score.
* [ ] Documentation: a language reference covering every implemented procedure and the
  embedding API.
* [ ] Performance: a benchmark suite tracked over time (see `benches/`).
