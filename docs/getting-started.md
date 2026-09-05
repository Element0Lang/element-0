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

The prompt evaluates one or more forms per line and prints the value of the last one. History is kept in `history.txt` in the current directory. Type `.exit` or press Ctrl-D to leave.

```scheme
> (define (square x) (* x x))
> (map square '(1 2 3))
(1 4 9)
> (expt 2 100)
1267650600228229401496703205376
```

## Running a Script

```bash
./zig-out/bin/elz-repl --file examples/elz/e13-hello-world.elz
```

The value of the last top-level form is displayed unless it is unspecified. An uncaught error stops the run, prints the error code, message, and source location, and exits with status 1:

```
--- Runtime Error ---
ErrorCode: InvalidArgument
Message: Symbol 'undefined-name' not found.
At: script.elz:3
In form: (display (undefined-name 1))
```

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

The [Embedding Guide](embedding.md) covers the rest of the API: mapping richer Zig types, calling Element 0 closures from Zig, sandboxing, and error reporting.

## Running the Tests

```bash
make test-all          # Zig unit, property, and integration tests, plus the Element 0 test files
make test-conformance  # the vendored R7RS suite; prints a score
make lint              # zig fmt --check
```

`make help` lists every target.
