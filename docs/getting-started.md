# Getting Started

This guide covers building the interpreter, using the REPL, running script files, and adding Elz to a Zig project.

## Prerequisites

Building Elz needs Zig 0.16.0 and GNU Make. The garbage collector is compiled from vendored C sources, so a C compiler must be available, which Zig provides itself.

```bash
# Debian and Ubuntu
sudo apt-get install make
```

Zig is available from [ziglang.org/download](https://ziglang.org/download/). The Makefile looks for it at `~/.local/share/zig/0.16.0/zig` and falls back to `zig` on the `PATH`; override the location with `make ZIG=/path/to/zig <target>`.

## Build from Source

```bash
git clone https://github.com/Element0Lang/element-0.git
cd element-0
make build
```

This produces `zig-out/bin/elz-repl` and the FFI example programs. Prebuilt binaries for tagged releases are on the [release page](https://github.com/Element0Lang/element-0/releases).

## The REPL

```bash
make repl
```

The prompt shows the input number. It reads forms and prints each value with `write`, so strings show their quotes. A form that is still open at the end of a line continues on the next line behind a `...` prompt. The last three printed values are bound to `$1`, `$2`, and `$3`. Type `.exit` or press Ctrl-D to leave.

```scheme
[1]> (define (square x)
...    (* x x))
[2]> (map square '(1 2 3))
(1 4 9)
[3]> (apply + $1)
14
[4]> (expt 2 100)
1267650600228229401496703205376
```

An error prints its message, the input and line it came from, and the chain of calls that led to it. The session continues with all definitions intact, and `.error` shows the last report again.

```scheme
[5]> (define (g x) (car x))
[6]> (define (f x) (+ 1 (g x)))
[7]> (f 5)
Error: InvalidArgument
At: [5]:1
Backtrace:
  0: g  ([5]:1)
  1: f  ([6]:1)
  2: <top level>  ([7]:1)
```

On Linux and macOS the REPL has line editing, a history file at `~/.elz_history`, and Tab completion of global names and special forms. Ctrl-C discards the input typed so far. The Windows build reads plain lines from the console without these features.

If `~/.elzrc` exists, the REPL runs it before the first prompt, which is the place for personal helper definitions. Pass `--no-rc` to skip it, and `--quiet` to suppress the banner.

Lines that start with a dot and a letter are REPL commands.

| Command | Effect |
| --- | --- |
| `.help` | Show the command list. |
| `.load <file>` | Run a source file in the current session. Definitions stay available afterwards. |
| `.time <expr>` | Evaluate an expression and print how long it took. |
| `.apropos <prefix>` | List the global names that start with a prefix. |
| `.error` | Show the last error report again. |
| `.clear` | Clear the screen. |
| `.exit` | Leave the REPL. |

The `--eval` flag evaluates an expression from the command line, and `--interactive` drops into the REPL after running a file or expression, with its definitions loaded.

```bash
./zig-out/bin/elz-repl --eval '(expt 2 64)'
./zig-out/bin/elz-repl --interactive examples/elz/e14-greetings-lib.elz
```

## Running a Script

```bash
./zig-out/bin/elz-repl examples/elz/e13-hello-world.elz
```

The file can also be given with `--file`. Arguments after the file belong to the script, and `(command-line)` returns the file name followed by those arguments. Put `--` before an argument that starts with a dash.

```bash
./zig-out/bin/elz-repl script.elz input.txt -- --fast
```

The value of the last top-level form is displayed unless it is unspecified. An uncaught error stops the run, prints the error code, message, and source location, and exits with status 1:

```
--- Runtime Error ---
ErrorCode: SymbolNotFound
Message: Symbol 'undefined-name' not found.
At: script.elz:3
In form: (display (undefined-name 1))
```

When the failure happens inside a procedure, a `Backtrace:` section lists the calls that led to it.

`--bench N` runs the file N times and prints timing statistics, and `--verbose` prints what the program is doing.

## Using Elz from Zig

Add Elz as a dependency of your project. Replace `<branch_or_tag>` with a branch such as `main` or a release tag:

```bash
zig fetch --save=elz "https://github.com/Element0Lang/element-0/archive/<branch_or_tag>.tar.gz"
```

Then make the module available to your executable in `build.zig`:

```zig
const elz_dep = b.dependency("elz", .{});
exe.root_module.addImport("elz", elz_dep.module("elz"));
```

A minimal program that evaluates a script and calls back into Zig:

```zig
const std = @import("std");
const elz = @import("elz");

fn zig_multiply(a: f64, b: f64) f64 {
    return a * b;
}

pub fn main() !void {
    var interpreter = try elz.Interpreter.init(.{});
    defer interpreter.deinit();

    // Register a Zig function under the name `zig-mul`.
    try elz.define_foreign_func(interpreter.root_env, "zig-mul", zig_multiply);

    var fuel: u64 = 100_000;
    const result = try interpreter.evalString("(zig-mul 7 6)", &fuel);

    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(interpreter.io, &buffer);
    try elz.write(result, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}
```

The [Embedding Guide](embedding.md) covers the rest of the API, including richer Zig types, calling Element 0 closures from Zig, sandboxing, and error reporting.

## Running the Tests

```bash
make test-all          # Zig unit, property, and integration tests, plus the Element 0 test files
make test-conformance  # the vendored R7RS suite; prints a score
make lint              # zig fmt --check
```

`make help` lists every target.
