## Feature Roadmap

This document includes the roadmap for the Element 0 programming language and Elz.
It outlines the features to be implemented and their current status.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change without notice.

### 1. Host API and FFI

* **Embedding API**
    * [x] An `Interpreter` struct that manages all interpreter states.
    * [x] An `Environment` struct representing variable scopes.
    * [x] `init` and `deinit` functions for lifecycle management.
    * [x] `evalString` to execute Element 0 code from Zig.
    * [x] Define global variables from Zig via the root environment.
* **FFI**
    * [x] Support for variadic functions. Zig functions can accept a variable number of Element 0 arguments.
    * [x] Graceful error propagation from Zig functions to the Element 0 environment.
    * [x] Support for opaque pointers. Element 0 can hold references to Zig data structures.

### 2. R5RS Compliance

#### 2.1. Core Data Types and Representation

* [x] Booleans (`#t` and `#f`)
* [x] Numbers (floating-point)
* [x] Symbols
* [x] Pairs and Lists
* [x] Characters
* [x] Strings
* [x] Procedures (closures)
* [x] Vectors
* [x] Hash Maps
* [x] Ports

#### 2.2. Evaluation Semantics and Special Forms

* [x] Self-evaluating expressions
* [x] `quote`
* [x] `if`
* [x] `define`
* [x] `set!`
* [x] `lambda`
* [x] `begin`
* [x] `let`, `let*`, `letrec`
* [x] `cond`
* [x] `case`
* [x] `and`
* [x] `or`

#### 2.3. Standard Library Procedures

* **Equivalence Predicates**
    * [x] `eq?`, `eqv?`, `equal?`
* **Type Predicates**
    * [x] `null?`, `boolean?`, `symbol?`, `number?`, `list?`, `pair?`, `string?`
    * [x] `procedure?`, `char?`, `integer?`, `not`
* **Pair and List Manipulation**
    * [x] `cons`, `car`, `cdr`, `pair?`
    * [x] `list`, `length`, `append`, `reverse`, `map`
    * [x] `list-ref`, `list-tail`, `memq`, `assq`
    * [x] `set-car!`, `set-cdr!`
    * [x] `for-each`
* **Numeric Operations**
    * [x] `+`, `-`, `*`, `/`
    * [x] `=`, `<`, `>`, `<=`, `>=`
    * [x] `abs`, `sqrt`, `max`, `min`
    * [x] `floor`, `ceiling`, `round`, `truncate`
    * [x] `expt`, `exp`, `log`
    * [x] `even?`, `odd?`, `zero?`, `positive?`, `negative?`
* **Symbol Handling**
    * [x] `symbol->string`, `string->symbol`
* **String and Character Manipulation**
    * [x] `string-length`, `string-ref`, `char=?`, `char<?`, `char>?`, `char<=?`, `char>=?`
    * [x] `char->integer`, `integer->char`
* **Vector Manipulation**
    * [x] `vector`, `make-vector`, `vector-ref`, `vector-set!`, `vector-length`, `vector?`, `list->vector`, `vector->list`
* **Hash Map Manipulation**
    * [x] `make-hash-map`, `hash-map-set!`, `hash-map-ref`, `hash-map-remove!`, `hash-map-contains?`, `hash-map-count`, `hash-map?`

#### 2.4. Syntactic Extensions

* [x] `quasiquote` (`` ` ``), `unquote` (`,`), `unquote-splicing` (`,@`)

#### 2.5. Advanced Control Flow

* [x] `apply`
* [x] `eval`

#### 2.6. I/O System

* [x] `write`
* [x] `display`
* [x] `newline`
* [x] `load`
* [x] `read` (as `read-string`)
* [x] `open-input-file`, `open-output-file`, `close-input-port`, `close-output-port`
* [x] `read-line`, `read-char`, `write-port`, `input-port?`, `output-port?`, `eof-object?`

### 3. Expanded Standard Library

* [x] **Math Library**: More common mathematical functions (like trigonometric and logarithmic functions).
* [x] **List Utilities**: `filter`, `fold-left`, `fold-right`, and other common list processing functions.
* [x] **String Utilities**: `string-append`, `string-ref`, `substring`, `string-split`, `number->string`, `string->number`, `make-string`, `string=?`, `string<?`, `string>?`, `string<=?`, `string>=?`, `gensym` implemented.
* [x] **Regular Expressions**: `regex-match?`, `regex-search`, `regex-replace`, `regex-split` implemented with NFA-based engine supporting literals, `.`, `*`, `+`, `?`, character classes, and anchors.
* [x] **OS and Filesystem**: `getenv`, `file-exists?`, `delete-file`, `current-directory`, `directory-list`, `rename-file` implemented.
* [x] **Advanced I/O**: `format` procedure with `~a`, `~s`, `~%`, `~~` directives, and `value->string` implemented.
* [x] **Date and Time**: `current-time`, `current-time-ms`, `time->components`, `sleep-ms` implemented.

### 4. Advanced Language Features (Post-R5RS)

* [x] **Error Handling**: A mechanism for handling runtime errors, like `try/catch` or `with-handler`.
* [x] **Module System**: A system for organizing code into reusable and encapsulated modules.
* [x] `define-macro` (simple procedural macros)
* [ ] `syntax-rules` (hygienic macros) or similar system for compile-time metaprogramming.
* [x] `call-with-escape-continuation` (`call/ec`): Escape-only continuations for early returns. Full `call/cc` deferred pending CPS rewrite.

### 5. Better Host Integration and Embeddability

* **Advanced FFI**
    * [ ] Support for passing complex Zig structs.
    * [ ] Ability to pass Elz closures to Zig as callbacks.
    * [x] Automatic type conversions for `bool`, `[]const u8`, and `?T` (optional) types.
* **Sandboxing and Security**
    * [x] A sandboxed mode to restrict access to I/O and other sensitive operations.
    * [x] Host-level controls for execution time limits (`time_limit_ms` in `SandboxFlags`).
* **Serialization**
    * [x] `json-serialize` and `json-deserialize` for JSON round-tripping.
    * [x] `value->string` for S-expression serialization.
