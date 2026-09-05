# Procedures

Every procedure and syntactic form bound in the global environment, grouped by category. Names from R7RS-small behave as the [report](https://small.r7rs.org/) specifies; differences are listed in the [language reference](language-reference.md#deviations-from-r7rs-small). Names marked *Elz* are extensions.

Procedures written in Element 0 itself live in `src/stdlib/std.elz`; the rest are Zig primitives under `src/elz/primitives/`. Some groups can be removed from the environment by a sandbox flag, noted in each heading.

## Syntax

`define` `define-values` `define-syntax` `define-record-type` `define-library` `define-macro` (*Elz*)
`lambda` `case-lambda` `let` `let*` `letrec` `letrec*` `let-values` `let*-values` `let-syntax` `letrec-syntax` `parameterize`
`if` `cond` `case` `when` `unless` `and` `or` `cond-expand` `begin` `do`
`quote` `quasiquote` `unquote` `unquote-splicing` `set!` `delay` `delay-force` `make-promise`
`guard` `try` (*Elz*) `reset` (*Elz*) `shift` (*Elz*) `include` `include-ci` `import` `syntax-error` `syntax-rules`

## Equivalence and Types (`enable_predicates`)

`eq?` `eqv?` `equal?` `not`
`boolean?` `symbol?` `number?` `string?` `char?` `pair?` `null?` `list?` `vector?` `bytevector?` `procedure?` `promise?` `hash-map?` (*Elz*) `port?` `eof-object?`
`atom?` (*Elz*) `typename` (*Elz*)

## Numbers (`enable_math`)

Arithmetic and comparison procedures take any number of arguments; comparisons are chained.

`+` `-` `*` `/` `=` `<` `>` `<=` `>=` `!=` (*Elz*) `%` (*Elz*, remainder)
`quotient` `remainder` `modulo` `floor/` `floor-quotient` `floor-remainder` `truncate/` `truncate-quotient` `truncate-remainder` `gcd` `lcm`
`abs` `min` `max` `square` `sqrt` `exact-integer-sqrt` `expt` `exp` `log` (one or two arguments) `sin` `cos` `tan` `asin` `acos` `atan` (one or two arguments)
`floor` `ceiling` `round` `truncate` `numerator` `denominator` `rationalize`
`exact` `inexact` `exact->inexact` `inexact->exact` `number->string` `string->number` (both accept a radix)
`integer?` `rational?` `real?` `complex?` `exact?` `inexact?` `exact-integer?` `zero?` `positive?` `negative?` `odd?` `even?` `finite?` `infinite?` `nan?`
`make-rectangular` `make-polar` `real-part` `imag-part` `magnitude` `angle`
`avg` (*Elz*) `fib` (*Elz*)

## Booleans and Symbols

`boolean=?` `symbol=?` `symbol->string` `string->symbol` `gensym` (*Elz*)

## Pairs and Lists (`enable_lists`)

`cons` `car` `cdr` `set-car!` `set-cdr!` `caar` `cadr` `cdar` `cddr` and the three- and four-letter compositions through `cddddr`
`list` `make-list` `length` `append` `reverse` `list-tail` `list-ref` `list-set!` `list-copy` `copy-list` (*Elz*)
`memq` `memv` `member` `assq` `assv` `assoc` (`member` and `assoc` accept an optional comparison procedure)
`map` `for-each` (any number of lists) `apply`
`filter` `fold-left` `fold-right` `any?` `every?` `quicksort` `take` `drop` `first` `rest` `head` `tail` `nth` `indexof` `last-element` `last-pair` (all *Elz*)

## Characters

`char=?` `char<?` `char>?` `char<=?` `char>=?` `char-ci=?` `char-ci<?` `char-ci>?` `char-ci<=?` `char-ci>=?`
`char-alphabetic?` `char-numeric?` `char-whitespace?` `char-upper-case?` `char-lower-case?` `digit-value`
`char-upcase` `char-downcase` `char-foldcase` `char->integer` `integer->char`

Classification and case mapping cover all of Unicode.

## Strings (`enable_strings`)

Strings are UTF-8 and every index counts characters. Procedures that take `start` and `end` accept them as the report specifies.

`string` `make-string` `string-length` `string-ref` `string-set!` `string-fill!` `substring` `string-append` `string-copy` `string-copy!`
`string=?` `string<?` `string>?` `string<=?` `string>=?` `string-ci=?` `string-ci<?` `string-ci>?` `string-ci<=?` `string-ci>=?`
`string-upcase` `string-downcase` `string-foldcase` (full case mappings, so `(string-upcase "ß")` is `"SS"`)
`string->list` `list->string` `string->vector` `vector->string` `string->utf8` `utf8->string` `string-map` `string-for-each`
`string-split` (*Elz*)

## Vectors

`vector` `make-vector` `vector-length` `vector-ref` `vector-set!` `vector-fill!` `vector-copy` `vector-copy!` `vector-append`
`vector->list` `list->vector` `vector-map` `vector-for-each`

## Bytevectors

`bytevector` `make-bytevector` `bytevector-length` `bytevector-u8-ref` `bytevector-u8-set!` `bytevector-copy` `bytevector-copy!` `bytevector-append` `utf8->string` `string->utf8`

## Control

`procedure?` `apply` `values` `call-with-values` `dynamic-wind` `force` `make-promise` `eval` `environment` `interaction-environment` `null-environment` `scheme-report-environment`
`call-with-current-continuation` `call/cc` `call-with-escape-continuation` `call/ec` (all escape-only)
`make-parameter`

## Exceptions

`raise` `raise-continuable` `with-exception-handler` `error` `error-object?` `error-object-message` `error-object-irritants` `read-error?` `file-error?`

## Ports and Input and Output (`enable_io` for the first line)

`display` `write` `write-shared` `write-simple` `newline` `load` `read-string` (with an integer count it reads characters; with a string it parses one datum, *Elz*)
`read` `read-char` `peek-char` `read-line` `char-ready?` `write-char` `write-string` `write-port` (*Elz*)
`current-input-port` `current-output-port` `current-error-port` `set-current-input-port!` (*Elz*) `set-current-output-port!` (*Elz*)
`open-input-file` `open-output-file` `open-binary-input-file` `open-binary-output-file` `open-input-string` `open-output-string` `get-output-string` `open-input-bytevector` `open-output-bytevector` `get-output-bytevector`
`read-u8` `peek-u8` `u8-ready?` `write-u8` `read-bytevector` `read-bytevector!` `write-bytevector`
`input-port?` `output-port?` `binary-port?` `textual-port?` `input-port-open?` `output-port-open?` `close-port` `close-input-port` `close-output-port` `flush-output-port` `eof-object`
`call-with-port` `call-with-input-file` `call-with-output-file` `with-input-from-file` `with-output-to-file` `call-with-output-string` (*Elz*)

File-backed ports need `enable_filesystem`.

## Records

`define-record-type` creates a constructor, a predicate, accessors, and modifiers. The underlying primitives `%make-record-type`, `%make-record`, `%record-of-type?`, `%record-ref`, and `%record-set!` are internal.

## Hash Maps (*Elz*)

`make-hash-map` `hash-map-set!` `hash-map-ref` (optional default) `hash-map-contains?` `hash-map-remove!` `hash-map-count` `hash-map?`

Keys are strings or symbols.

## Formatting, JSON, and Regular Expressions (*Elz*)

`format` (directives `~a`, `~s`, `~%`, `~~`) `value->string`
`json-serialize` `json-deserialize` (objects become hash maps, arrays become lists, `null` becomes the empty list)
`regex-match?` `regex-search` `regex-replace` `regex-split`

## System (`enable_process`, `enable_filesystem`)

`command-line` `exit` `emergency-exit` `getenv` `get-environment-variable` `get-environment-variables` `features`
`file-exists?` `delete-file` `rename-file` `current-directory` `directory-list`
`current-second` `current-jiffy` `jiffies-per-second` `current-time` `current-time-ms` `time->components` `sleep-ms`

## Modules (*Elz*)

`import` (with a file path) returns a module object; `module-ref` reads an export from it. The R7RS `define-library` and `(import (name ...))` forms are described in the [language reference](language-reference.md#libraries-and-modules).
