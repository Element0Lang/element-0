<div align="center">
  <picture>
    <img alt="Element 0 Logo" src="logo.svg" height="35%" width="35%">
  </picture>
<br>

<h2>Element 0</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/Element0Lang/element-0/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/Element0Lang/element-0/actions/workflows/tests.yml)
[![Docs](https://img.shields.io/badge/docs-read-blue?style=flat&labelColor=282c34&logo=read-the-docs)](https://Element0Lang.github.io/element-0/)
[![Examples](https://img.shields.io/badge/examples-view-green?style=flat&labelColor=282c34&logo=zig)](https://github.com/Element0Lang/element-0/tree/main/examples)
[![License](https://img.shields.io/badge/license-Apache--2.0-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/Element0Lang/element-0/blob/main/LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat&labelColor=282c34&logo=zig)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/release/Element0Lang/element-0.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/Element0Lang/element-0/releases/latest)

A small embeddable Lisp for the Zig ecosystem λ

</div>

---

Element 0 is a small scripting language that can be embedded in Zig applications.
It is a new Lisp dialect inspired by Scheme with features like first-class functions, macros, and a simple syntax.

This project provides an implmenation of Element 0 (a compiler and virtual machine).
The implementation is named Elz (pronounced "el-zee") and can be easily integrated into Zig applications as a scripting engine.

### Key Features

* Small langauge with a growing standard library (see [std.elz](src/stdlib/std.elz))
* Easy to integrate into Zig projects as a lightweight scripting engine
* Easy to extend with Zig functions via the use of FFI or directly writing Element 0 code
* A ggod tradeoff between performance and simplicity

See the [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features, and the
[language reference](docs/language-reference.md) for the language as implemented.

> [!IMPORTANT]
> This project is in early development, so bugs and breaking changes are expected.
> Please use the [issue page](https://github.com/Element0Lang/element-0/issues) to report bugs or request features.

---

### Getting Started

#### Using the Standalone REPL

##### A. Download Release Binaries

You can download the release binaries for Elz from the [release page](https://github.com/Element0Lang/element-0/releases).

##### B. Building from Source

1. Clone the repository
   ```sh
   git clone https://github.com/Element0Lang/element-0.git
   cd element-0
   ```

2. Build and run the REPL
   ```sh
   zig build repl && ./zig-out/bin/elz-repl
   ```

3. Run an Element 0 script file
    ```sh
    ./zig-out/bin/elz-repl --file examples/elz/e13-hello-world.elz
    ```

#### Embedding Elz in Zig Projects

You can add Elz to your project as a dependency and use it as a scripting engine.

##### Installation

Run the following command in the root directory of your project to add Elz as a dependency.

```sh
zig fetch --save=elz "https://github.com/Element0Lang/element-0/archive/<branch_or_tag>.tar.gz"
```

Replace `<branch_or_tag>` with the desired branch or release tag, like `main` (for the development version) or `v0.1.0`.
This command will download Elz and add it to Zig's global cache and update your project's `build.zig.zon` file.

##### Adding to Your Build Script

Next, modify your `build.zig` file. This will make the Elz library available to your application as a module.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 1. Get the Elz dependency object from the builder.
    const elz_dep = b.dependency("elz", .{});

    // 2. Create a module for the Elz library.
    const elz_module = elz_dep.module("elz");

    // 3. Add the module to your executable so you can @import("elz").
    exe.root_module.addImport("elz", elz_module);

    // 4. Link system libraries required by Elz.
    exe.linkSystemLibrary("c");

    b.installArtifact(exe);
}
```

##### Using Elz in Zig Applications

Finally, you can `@import("elz")` and use the interpreter in your Zig application.

The example below shows how to evaluate a simple script.
It also shows how to use the FFI to call a Zig function from Elz.

```zig
const std = @import("std");
const elz = @import("elz");

// Define a native Zig function you want to call from Elz.
fn zig_multiply(a: f64, b: f64) f64 {
    return a * b;
}

pub fn main() !void {
    // 1. Initialize the Elz interpreter (the compiler and VM)
    var interpreter = try elz.Interpreter.init(.{});
    defer interpreter.deinit();

    var buffer: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
    const stdout = &stdout_writer.interface;

    // --- Example 1: Evaluate a simple string of Elz code ---
    std.debug.print("--- Evaluating simple Elz code ---\n", .{});
    const source1 = "(* 10 5)";
    var fuel1: u64 = 1000;
    const result1 = try interpreter.evalString(source1, &fuel1);

    try stdout.print("Result of {s} is: ", .{source1});
    try elz.write(result1, stdout);
    try stdout.print("\n\n", .{});
    try stdout.flush();

    // --- Example 2: Expose a Zig function to Elz and call it ---
    std.debug.print("--- Calling a Zig function from Elz ---\n", .{});

    // 2. Register your Zig function with the interpreter.
    // It will be available in Elz under the name "zig-mul".
    try elz.define_foreign_func(
        interpreter.root_env,
        "zig-mul",
        zig_multiply,
    );

    // 3. Write and evaluate Elz code that calls your Zig function.
    const source2 = "(zig-mul 7 6)";
    var fuel2: u64 = 1000;
    const result2 = try interpreter.evalString(source2, &fuel2);

    try stdout.print("Result of {s} is: ", .{source2});
    try elz.write(result2, stdout);
    try stdout.print("\n", .{});
    try stdout.flush();
}
```

When you build and run this program, the output will be:

```
--- Evaluating simple Elz code ---
Result of (* 10 5) is: 50

--- Calling a Zig function from Elz ---
Result of (zig-mul 7 6) is: 42
```

##### Restricting What a Script Can Do

`Interpreter.init` takes a `SandboxFlags` value that selects which built-in capabilities the script can reach.
Every group is enabled by default.

```zig
var interpreter = try elz.Interpreter.init(.{
    .enable_filesystem = false, // No file ports, `load`, `include`, or module imports
    .enable_process = false, // No `exit` and no environment variables
    .time_limit_ms = 100, // Give up after 100 milliseconds
});
```

A disabled group's procedures are not bound at all, so a script that calls one gets a `SymbolNotFound` error.
The compile-time forms that read files (`include`, `include-ci`, and `import`) report `PermissionDenied` when the filesystem is disabled.
The other groups are `enable_math`, `enable_lists`, `enable_predicates`, `enable_strings`, and `enable_io`.

The `fuel` counter passed to `evalString` and `evalForm` bounds the number of VM instructions, including instructions run by
callbacks from primitives such as `map` and `apply`, and list primitives charge one unit per element they visit. A few fixed
limits also apply and report an error instead of exhausting the native stack: expressions nest at most 1000 levels in the
compiler and 2048 levels in the reader, a JSON document nests at most 512 levels, the VM holds at most 65536 call frames, and
primitive callbacks (`map`, `apply`, `call/cc`, `guard`, and the like) nest at most 600 levels deep.

-----

### Documentation

You can find the full API documentation for the latest release of Elz [here](https://element0lang.github.io/element-0/).

#### Standard Library

See the [std.elz](src/stdlib/std.elz) file for the full list of available items (like functions, variables, etc.) in the standard library.

#### Examples

Check out the [examples](examples) directory for Element 0 code and Zig FFI examples.

-----

### Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

Element 0 is licensed under the Apache License, Version 2.0 (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is made by [Conrad Barski, M.D.](https://www.lisperati.com/logo.html) with a few changes.
* [Bestline](https://github.com/jart/bestline) is used for the REPL's line editing and history features.
* [Chibi-Scheme](https://github.com/ashinn/chibi-scheme) R5RS test suite is used for compliance testing.
* [Chilli](https://github.com/CogitatorTech/chilli) is used for the CLI.
* [BDWGC](https://github.com/bdwgc/bdwgc) is used for the garbage collector.
