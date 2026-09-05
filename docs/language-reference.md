# Element 0 Language Reference

Element 0 is a small Lisp dialect based on R7RS-small, implemented by Elz, a
compiler and bytecode virtual machine written in Zig. This document describes
the language as implemented. For the standard semantics of R7RS procedures,
see the [R7RS-small report](https://small.r7rs.org/); this reference lists
what Element 0 provides and details only behavior that is specific to it.
The [Procedures](procedures.md) page lists every built-in procedure by name.
Deviations from the standard are collected in the last section.

## Lexical Syntax

Element 0 reads the full R7RS-small lexical syntax.

* Comments come in three forms. A line comment runs from `;` to the end of
  the line, `#| ... |#` is a nestable block comment, and `#;` comments out
  the following datum.
* Booleans are `#t`, `#f`, `#true`, and `#false`.
* Integers have no size limit. They can carry a radix prefix (`#x10`, `#o17`,
  `#b101`, `#d16`) and an exactness prefix (`#e`, `#i`) in either order;
  `#e1.5` reads as `3/2`. `1/3` is an exact rational. `+inf.0`, `-inf.0`,
  and `+nan.0` are inexact reals. `3+4i` is a complex number in rectangular
  notation; an exact zero imaginary part, as in `3+0i`, denotes a real
  number. Number syntax is strict: `inf`, `nan`, `1_000`, and `0x10` are
  symbols, not numbers.
* Characters are written `#\a`, by name (`#\space`, `#\newline`, `#\tab`,
  `#\return`, `#\alarm`, `#\backspace`, `#\delete`, `#\escape`, `#\null`),
  or by code point (`#\x41`). A character literal may be any single UTF-8
  character.
* Strings support the escapes `\n`, `\t`, `\r`, `\a`, `\b`, `\0`, `\\`,
  `\"`, `\|`, and `\xHH...;` for a code point in hex. A backslash before a
  line break continues the string on the next line with the surrounding
  whitespace removed.
* Symbols with unusual characters are written between pipes, as in
  `|two words|`, with the same escapes as strings.
* `#(1 2 3)` is a vector literal and `#u8(1 2 3)` is a bytevector literal.
* `'x`, `` `x ``, `,x`, and `,@x` abbreviate `quote`, `quasiquote`,
  `unquote`, and `unquote-splicing`.
* Datum labels `#n=` and `#n#` write and read shared and cyclic structure.
* The `#!fold-case` and `#!no-fold-case` directives switch case folding of
  symbols for the rest of the datum being read.

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
`(let ((if list)) (if 1 2 3))` calls the variable. A definition inside a body
likewise shadows a macro of the same name.

Definitions may appear at the start of any body, including inside `begin`
forms and as the output of macros such as `define-values` and
`define-record-type`. A `define` in expression position (inside `when`, an
`if` branch, or a `do` result) is a syntax error.

### Macros

`define-syntax` with `syntax-rules` implements hygienic pattern macros with
the full R7RS feature set. Patterns support nested and mid-list ellipsis,
dotted tails, the `_` wildcard, literal identifiers, and a custom ellipsis
identifier. Templates support consecutive ellipses for splicing and the
`(... <template>)` escape.

Hygiene works by renaming. Every identifier a template introduces gets a
fresh alias that remembers where the macro was defined, and the compiler
resolves the alias from that definition scope. A `let` at the use site cannot
capture a template's temporary, a use-site binding of `list` or `if` does not
change what a template's `list` or `if` means, and a template that refers to
a local variable of the function the macro was defined in reaches that
variable even from a nested scope that shadows the name.

Quoted data in a template is never renamed: `(quote x)`, the datum lists of
`case`, vector literals, and the parts of a quasiquotation that are not
unquoted appear in the output exactly as written.

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
* Errors detected by the runtime (a bad argument, an unbound variable, a
  failed file open, a malformed datum) are also error objects when caught
  by `guard` or `try`. Their message is the runtime's description, their
  irritants are empty, and file and read failures answer `file-error?` and
  `read-error?`.
* `guard` dispatches a raised object over cond-style clauses and reraises
  when no clause matches.

Elz also provides `try`/`catch`, a lower-level form that predates `guard`:

```scheme
(try (risky-thing)
     (catch e (recover e)))
```

The catch body receives the raised object, or an error object for internal
runtime errors. `guard` is implemented over `try`/`catch` and is the
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
raises an error rather than capturing across the boundary. `for-each` is
written in Element 0, so a `shift` inside it works.

A local variable that a closure captured inside the captured segment stays
shared: after `k` resumes the segment, the closure and the resumed code see
the same variable, and a value assigned in one invocation of `k` is visible
in the next.

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
  `hash-map-contains?`, `hash-map-remove!`, and `hash-map-count`. Keys are
  strings or symbols; a string and a symbol with the same characters are
  the same key.
* Regular expressions: `regex-match?`, `regex-search`, `regex-replace`, and
  `regex-split`, backed by a small NFA engine. Patterns support literals,
  `.`, `*`, `+`, `?`, bracket character classes, `^`, `$`, and backslash
  escapes of literal characters. Groups, alternation, counted repetition,
  and shorthand classes such as `\d` are not supported. `regex-replace`
  takes the pattern, the replacement, then the input string.
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
`src/lib.zig`; see the [Embedding Guide](embedding.md). `SandboxFlags`
restricts I/O and other capabilities and can impose a wall-clock time
limit, and an instruction budget bounds every evaluation.

Fixed limits keep hostile input from exhausting the native stack and are
reported as errors: expressions nest at most 1000 levels in the compiler and
2048 levels in the reader, a JSON document nests at most 512 levels, the VM
holds at most 65536 call frames, and callbacks from primitives (`map`,
`apply`, `call/cc`, `guard`, and the like) nest at most 600 levels deep.

## Deviations from R7RS-small

The vendored Chibi Scheme conformance suite passes 976 of 977 checks; run it
with `make test-conformance`. The known gaps follow.

* Exact integers have arbitrary size, but rationals use 64-bit components.
  A rational whose numerator or denominator would not fit, or a rational
  combined with an integer that does not fit, raises `Overflow`.
* `call/cc` captures escape-only continuations, as described above. This is
  the one failing conformance check: a `dynamic-wind` cannot be re-entered
  through a continuation.
* `shift` does not capture across a native primitive such as `map`.
* `dynamic-wind` before and after thunks do not re-fire when a captured
  segment is reinstated.
* `define-library` evaluates its body in the global environment; private
  definitions leak into the global namespace even though `import` binds
  only the declared exports.
* `string-ci=?` and the other case-insensitive comparisons compare full case
  foldings, but `char-upcase` and friends use the simple one-to-one
  mappings, as the report specifies. No locale-specific or final-sigma
  handling is applied.
* Mutating a quoted literal is allowed rather than an error.
* `exact-integer-sqrt`, `exact`, and `inexact` are complete, but
  `rationalize` and `numerator` on inexact numbers work within the 64-bit
  rational range only.
