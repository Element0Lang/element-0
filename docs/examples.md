# Examples

The repository ships runnable examples in two forms: Element 0 scripts under `examples/elz/`, and Zig programs under `examples/zig/` that embed the interpreter and expose Zig functions to it.

## Element 0 Scripts

Run any script with the REPL binary:

```bash
./zig-out/bin/elz-repl --file examples/elz/e4-factorial.elz
```

`make run-elz` runs every script; `make run-elz ELZ_EXAMPLE=e4-factorial` runs one.

| Script | What it shows |
|---|---|
| `e1-cons-car-cdr.elz` | Pairs: `cons`, `car`, and `cdr`. |
| `e2-simple-lambda.elz` | Anonymous procedures with `lambda`. |
| `e3-simple-math.elz` | Arithmetic on the numeric tower. |
| `e4-factorial.elz` | A recursive factorial. |
| `e5-map-lambda.elz` | `map` with a lambda. |
| `e6-let-bindings.elz` | Local bindings with `let`. |
| `e7-if-expressions.elz` | Conditionals with `if`. |
| `e8-list-manipulation.elz` | List construction and traversal. |
| `e9-tco-factorial.elz` | A loop written as a tail call, which runs in constant stack space. |
| `e10-closures.elz` | Closures and lexical scope. |
| `e11-list-processing.elz` | A tail-recursive `take` and other list processing. |
| `e12-io-display-vs-write.elz` | The difference between `display` and `write`. |
| `e13-hello-world.elz` | Hello, world. |
| `e14-greetings-lib.elz`, `e15-load-example.elz` | Splitting a program across files with `load`. |
| `e16-try-catch.elz` | Error handling with `try` and `catch`. |
| `e17-greetings-lib.elz`, `e18-import-example.elz` | File modules with `import` and `module-ref`. |
| `e19-import-optional-list-utils.elz` | Importing a module and using its procedures. |
| `e20-binary-search-tree.elz` | A binary search tree built from lists. |
| `e21-hash-table.elz` | Association lists as a lookup table. |
| `e22-sorting-algorithms.elz` | Several sorting algorithms. |
| `e23-functional-patterns.elz` | Higher-order functions and composition. |
| `e24-calculator.elz` | A calculator with an expression parser. |

## Zig Programs

Each program is built by `zig build` and can be run with `make run EXAMPLE=<name>` or `zig build run-<name>`.

| Program | What it shows |
|---|---|
| `e1_ffi_pow` | Exposing a two-argument Zig function (`zig-pow`) and calling it from a script. |
| `e2_ffi_list_increment` | Receiving arguments as a slice of values, walking an Element 0 list, and returning a new list. |
| `e3_ffi_sum_of_squares` | A variadic Zig function that receives all its arguments as a slice of values. |

The smallest complete embedding is `e1_ffi_pow`:

```zig
const std = @import("std");
const elz = @import("elz");

fn zig_pow(base: f64, exp: f64) f64 {
    return std.math.pow(f64, base, exp);
}

pub fn main() !void {
    var interpreter = try elz.Interpreter.init(.{});
    try elz.define_foreign_func(interpreter.root_env, "zig-pow", zig_pow);
    var fuel: u64 = 1000;
    const result = try interpreter.evalString("(zig-pow 2 8)", &fuel);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(interpreter.io, &buffer);
    try writer.interface.writeAll("Result: ");
    try elz.write(result, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}
```

## Snippets

A generator built from delimited continuations:

```scheme
(define (make-generator lst)
  (define return #f)
  (define (next)
    (reset
      (for-each (lambda (x) (shift k (set! next (lambda () (k #f))) x)) lst)
      'done))
  (lambda () (next)))

(define g (make-generator '(1 2 3)))
(g)   ; => 1
(g)   ; => 2
```

Exact arithmetic without overflow:

```scheme
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 30)            ; => 265252859812191058636308480000000
(exact->inexact 1/3) ; => 0.3333333333333333
(exact 1e20)         ; => 100000000000000000000
```

A hygienic macro:

```scheme
(define-syntax swap!
  (syntax-rules ()
    ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))

(let ((tmp 1) (other 2))
  (swap! tmp other)
  (list tmp other))    ; => (2 1)
```

Catching errors, including ones raised by the runtime:

```scheme
(guard (e ((file-error? e) 'no-such-file)
          ((error-object? e) (error-object-message e)))
  (open-input-file "/does/not/exist"))   ; => no-such-file
```
