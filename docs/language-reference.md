# Element 0 Language Reference

Element 0 is a small Lisp dialect based on R7RS-small, implemented by Elz, a
compiler and bytecode virtual machine written in Zig. This document describes
the language as implemented. For the standard semantics of R7RS procedures,
see the [R7RS-small report](https://small.r7rs.org/); this reference lists
what Element 0 provides and details only behavior that is specific to it.
Deviations from the standard are collected in the last section.

## Lexical Syntax

Element 0 reads the full R7RS-small lexical syntax.

* Comments come in three forms. A line comment runs from `;` to the end of
  the line, `#| ... |#` is a nestable block comment, and `#;` comments out
  the following datum.
* Booleans are `#t`, `#f`, `#true`, and `#false`.
* Integers can carry a radix prefix (`#x10`, `#o17`, `#b101`, `#d16`) and an
  exactness prefix (`#e`, `#i`). `1/3` is an exact rational. `+inf.0`,
  `-inf.0`, and `+nan.0` are inexact reals. `3+4i` is a complex number in
  rectangular notation; an exact zero imaginary part, as in `3+0i`, denotes
  a real number.
* Characters are written `#\a`, by name (`#\space`, `#\newline`, `#\tab`,
  `#\return`, `#\alarm`, `#\backspace`, `#\delete`, `#\escape`, `#\null`),
  or by code point (`#\x41`). A character literal may be any single UTF-8
  character.
* Strings support the escapes `\n`, `\t`, `\r`, `\a`, `\b`, `\0`, `\\`,
  `\"`, and `\xHH...;` for a code point in hex.
* Symbols with unusual characters are written between pipes, as in
  `|two words|`, with the same escapes as strings.
* `#(1 2 3)` is a vector literal and `#u8(1 2 3)` is a bytevector literal.
* `'x`, `` `x ``, `,x`, and `,@x` abbreviate `quote`, `quasiquote`,
  `unquote`, and `unquote-splicing`.

## Special Forms

The core forms follow R7RS-small.

* Definitions: `define`, `define-values`, `define-syntax`,
  `define-record-type`, `define-library`, and the Elz-specific
  `define-macro`.
* Binding: `let`, `let*`, `letrec`, named `let`, `let-values`,
  `let*-values`, `let-syntax`, `letrec-syntax`, and `parameterize`.
* Conditionals: `if`, `cond` (including `=>` clauses), `case` (including
  `=>` clauses), `when`, `unless`, `and`, `or`, and `cond-expand`.
* Sequencing and iteration: `begin` and `do`.
* Quoting: `quote` and `quasiquote` with `unquote` and `unquote-splicing`.
* Assignment: `set!`.
* Lazy evaluation: `delay` and `delay-force`.
* Procedures: `lambda` with fixed, dotted-rest, and all-variadic parameter
  lists, and `case-lambda`.
* Exceptions: `guard`, plus the Elz-specific `try`/`catch` described below.
* Continuations: `reset` and `shift`, described below.
* Compile-time inclusion: `include` and `include-ci` splice the forms of the
  named files in place; `include-ci` folds symbols to lower case.
* Macros can signal misuse with `syntax-error`.

A lexically bound name shadows a special form of the same name, so
`(let ((if list)) (if 1 2 3))` calls the variable.

### Macros

`define-syntax` with `syntax-rules` implements hygienic pattern macros with
the full R7RS feature set. Patterns support nested and mid-list ellipsis,
dotted tails, the `_` wildcard, literal identifiers, and a custom ellipsis
identifier. Templates support consecutive ellipses for splicing and the
`(... <template>)` escape.

`define-macro` defines a procedural (non-hygienic) macro. The body receives
the unevaluated argument forms and returns a replacement form.

### Records

`define-record-type` follows R7RS.

```scheme
(define-record-type point
  (make-point x y)
  point?
  (x point-x set-point-x!)
  (y point-y))
```

Record types are distinct even when their names collide. Reading a field
through the wrong type's accessor raises an error.

## Standard Procedures

The R5RS-era core is complete; the R7RS-small additions listed here are
implemented as well. Procedures behave as the report specifies unless noted
in the deviations section.

* Equivalence: `eq?`, `eqv?`, `equal?`.
* Numbers: the arithmetic and comparison operators (n-ary, chained), the
  numeric predicates including `exact-integer?`, `finite?`, `infinite?`, and
  `nan?`, rounding and division families (`floor/`, `truncate/`, `quotient`,
  `remainder`, `modulo`, `gcd`, `lcm`), transcendental functions, `expt`,
  `exact-integer-sqrt`, `square`, `abs`, `min`, `max`, exactness conversion
  (`exact`, `inexact`), rational accessors (`numerator`, `denominator`,
  `rationalize`), complex constructors and accessors (`make-rectangular`,
  `make-polar`, `real-part`, `imag-part`, `magnitude`, `angle`), and radix
  aware `number->string` and `string->number`.
* Booleans: `not`, `boolean?`, `boolean=?`.
* Pairs and lists: the constructors and accessors, `set-car!`, `set-cdr!`,
  the full `caar` through `cddddr` family, `list`, `length`, `append`,
  `reverse`, `list-ref`, `list-set!`, `list-tail`, `list-copy`, `make-list`,
  `memq`, `memv`, `member`, `assq`, `assv`, `assoc` (the last two of each
  accept an optional comparator), `map` and `for-each` (stopping at the
  shortest list), `filter`, `fold-left`, and `fold-right`.
* Symbols: `symbol?`, `symbol=?`, `symbol->string`, `string->symbol`,
  `gensym`.
* Characters: the predicates, the case-sensitive and case-insensitive
  comparison chains, classification (`char-alphabetic?` and friends),
  `char-upcase`, `char-downcase`, `char-foldcase`, `digit-value`,
  `char->integer`, and `integer->char`.
* Strings: construction, access, mutation, the comparison chains,
  `substring`, `string-append`, `string-copy`, `string-copy!`,
  `string-fill!`, `string->list`, `list->string`, `string-map`,
  `string-for-each`, `string-upcase`, `string-downcase`, `string-foldcase`,
  `string-split`, and conversions to and from vectors and UTF-8
  bytevectors. Strings are UTF-8 and indexes count characters. Procedures
  with `start` and `end` arguments accept them as the report specifies.
* Vectors: construction, access, mutation, `vector-copy`, `vector-copy!`,
  `vector-append`, `vector-fill!`, `vector-map`, `vector-for-each`, and
  conversions to and from lists and strings.
* Bytevectors: the full section 6.9 set, including `bytevector-copy!` with
  overlapping-range support, `utf8->string`, and `string->utf8`.
* Control: `procedure?`, `apply`, `values`, `call-with-values`,
  `dynamic-wind`, `force`, `make-promise`, `promise?`, and `eval` with
  `environment` and `interaction-environment`.
* Ports and I/O: textual and binary ports over files, strings, and
  bytevectors, the `read` family with optional port arguments, the `write`
  family (`write` labels cyclic data with datum labels, `write-shared`
  labels all shared structure, `write-simple` labels nothing), `display`,
  `newline`, `write-string`, `write-char`, the u8 procedures, port
  predicates and open checks, `close-port`, `call-with-port`, the
  `current-input-port`, `current-output-port`, and `current-error-port`
  accessors, the `with-...-file` and `call-with-...-file` conveniences, and
  `load`.
* System interface: `command-line`, `exit`, `emergency-exit`,
  `get-environment-variable`, `get-environment-variables`, `features`,
  `current-second`, `current-jiffy`, and `jiffies-per-second`.

## Exceptions

The R7RS exception system is implemented in full.

* `raise` raises any object. `raise-continuable` allows the installed
  handler's return value to become the value of the raise expression.
* `with-exception-handler` installs a handler for the dynamic extent of a
  thunk. The handler runs with itself uninstalled. A handler returning from
  a non-continuable raise is itself an error.
* `error` raises an error object carrying a message and irritants, examined
  with `error-object?`, `error-object-message`, and
  `error-object-irritants`. `read-error?` and `file-error?` test the error
  kind.
* `guard` dispatches a raised object over cond-style clauses and reraises
  when no clause matches.

Elz also provides `try`/`catch`, a lower-level form that predates `guard`:

```scheme
(try (risky-thing)
     (catch e (recover e)))
```

The catch body receives the raised object, or a message string for internal
virtual machine errors. `guard` is implemented over `try`/`catch` and is the
recommended form.

## Continuations

Element 0 deliberately does not provide full first-class continuations.
`call-with-current-continuation` and `call/cc` are aliases for
`call-with-escape-continuation` (`call/ec`); the continuation they capture
is one-shot and upward-only, valid only during the dynamic extent of the
call. This supports early exit and exception-like control flow but not
generators or re-entry. Full `call/cc` cannot capture the Zig frames that
sit between Elz frames when embedded code calls back into the interpreter,
so this restriction is permanent; it matches the choices of other practical
embedded languages.

Composable control flow is provided by delimited continuations instead.

```scheme
(reset (+ 1 (shift k (+ (k 1) (k 2)))))   ; => 5
```

* `(reset body ...)` installs a prompt and evaluates the body.
* `(shift k body ...)` captures the computation between the call and the
  nearest enclosing prompt as the procedure `k`, unwinds to the prompt, and
  evaluates the body. Invoking `k` reinstates the captured computation under
  a fresh prompt. Continuations are multi-shot and remain valid after their
  prompt has returned.

Prompts do not cross native frames. A `shift` whose nearest `reset` is on
the other side of a Zig primitive (for example, inside a `map` callback)
raises an error rather than capturing across the boundary.

`dynamic-wind` before and after thunks do not re-fire when a captured
segment is reinstated.

## Libraries and Modules

`define-library` defines a named library with `export`, `import`, `begin`,
`include`, and `include-ci` clauses.

```scheme
(define-library (my utils)
  (export twice)
  (import (scheme base))
  (begin
    (define (twice x) (* 2 x))))

(import (my utils))
(twice 21)                                ; => 42
```

`(import (name ...))` binds a registered library's exports. Names beginning
with `scheme` or `elz` resolve to the built-in global environment. The
library body is evaluated in the global environment, matching how file
modules load; only the declared exports are bound by `import`, but internal
definitions are not hidden from the global namespace.

Elz's original module system is also available. `(import "path.elz")` is an
expression returning a module object whose exports are read with
`module-ref`.

## Elz Extensions

These features are not part of R7RS-small.

* Hash maps: `make-hash-map`, `hash-map?`, `hash-map-set!`, `hash-map-ref`,
  `hash-map-contains?`, `hash-map-remove!`, and `hash-map-count`, with
  string keys.
* Regular expressions: `regex-match?`, `regex-search`, `regex-replace`, and
  `regex-split`, backed by an NFA engine supporting literals, `.`, `*`,
  `+`, `?`, character classes, and anchors.
* JSON: `json-serialize` and `json-deserialize`.
* Formatting: `format` with the `~a`, `~s`, `~%`, and `~~` directives, and
  `value->string`.
* Files and OS: `file-exists?`, `delete-file`, `rename-file`,
  `current-directory`, `directory-list`, `getenv`, and `sleep-ms`.
* Time: `current-time`, `current-time-ms`, and `time->components`.
* List utilities: `take`, `drop`, `first`, `rest`, `head`, `tail`, `nth`,
  `indexof`, `last-element`, `last-pair`, `any?`, `every?`, `quicksort`,
  and `atom?`.

## Running and Embedding

The `elz-repl` binary starts an interactive session, or runs a file with
`--file`. Uncaught runtime errors report the error code, a message, the
source location as `At: file:line`, and the failing top-level form.

Elz embeds into Zig applications through the `Interpreter` API in
`src/lib.zig`, with foreign functions registered through the FFI described
in `AGENTS.md` and the API documentation. `SandboxFlags` restricts I/O and
other capabilities and can impose a wall-clock time limit.

## Deviations from R7RS-small

The vendored Chibi Scheme conformance suite passes 888 of 977 checks
(91 percent) as of 2026-08-30; run it with `make test-conformance`. The
known gaps follow.

* Integers are 64-bit and rationals use 64-bit components. There is no
  bignum arithmetic; overflow raises an error.
* `call/cc` captures escape-only continuations, as described above.
* Character and string case operations use a simple one-to-one case mapping
  covering ASCII, Latin-1, Greek, and Cyrillic. Multi-character special
  casings, such as the German sharp s, are not applied.
* `string-set!` and `string-fill!` cannot change a character's UTF-8 byte
  width in place.
* `syntax-rules` templates referencing bindings from the macro's definition
  environment can fail to resolve when the use site shadows those names;
  hygiene is rename-based rather than environment-based.
* Datum labels (`#0=`, `#0#`) are written by `write` but not yet read.
* The `#!fold-case` and `#!no-fold-case` reader directives are not
  supported.
* `define-library` evaluates its body in the global environment; private
  definitions leak into the global namespace even though `import` binds
  only the declared exports.
* Mutating a quoted literal is undefined behavior, as the report permits.
