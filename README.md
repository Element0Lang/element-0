<div align="center">
  <picture>
    <img alt="Element 0 Logo" src="logo.svg" height="35%" width="35%">
  </picture>
<br>

<h2>Element 0</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/Element0Lang/element-0/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/Element0Lang/element-0/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/Element0Lang/element-0/blob/main/LICENSE)
[![Docs](https://img.shields.io/badge/docs-read-blue?style=flat&labelColor=282c34&logo=read-the-docs)](https://Element0Lang.github.io/element-0/)
[![Examples](https://img.shields.io/badge/examples-view-green?style=flat&labelColor=282c34&logo=zig)](https://github.com/Element0Lang/element-0/tree/main/examples)
[![Zig](https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat&labelColor=282c34&logo=zig)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/release/Element0Lang/element-0.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/Element0Lang/element-0/releases/latest)

A small embeddable Lisp for the Zig ecosystem λ

</div>

---

Element 0 programming language is a new Lisp dialect inspired by Scheme.
It aims to be compliant with the [R5RS](https://www-sop.inria.fr/indes/fp/Bigloo/doc/r5rs-7.html) standard to a good
degree, but not limited to it.

This project provides an interpreter for the Element 0 language written in Zig.
The interpreter is named Elz (pronounced "el-zee") and can be integrated into Zig applications as a scripting engine.
In addition, Elz comes with a read-eval-print loop (REPL) for interactive development and testing, and
it can easily be extended using Zig code using foreign function interface (FFI) or Element 0 code.

### Why Element 0?

Having an embeddable scripting language is useful in a Zig project.
For example, you can write the core parts of your application in Zig for performance.
Then you can write features like plugins or configuration files in Element 0.
This lets you change parts of your application without the need to recompile the entire project.

### Features

* A good level of R5RS compliance with a growing standard library (see [std.elz](src/stdlib/std.elz))
* Easy to integrate into Zig projects as a lightweight and fast scripting engine
* Easy to extend with Zig functions via the use of FFI or writing Element 0 code
* Prepacked with a REPL for interactive development

See the [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> This project is in early development, so bugs and breaking changes are expected.
> Please use the [issues page](https://github.com/Element0Lang/element-0/issues) to report bugs or request features.

---

### Getting Started

#### Using the Standalone REPL

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
    // 1. Initialize the Elz interpreter.
    var interpreter = try elz.Interpreter.init(.{});

    const stdout = std.io.getStdOut().writer();

    // --- Example 1: Evaluate a simple string of Elz code ---
    std.debug.print("--- Evaluating simple Elz code ---\n", .{});
    const source1 = "(* 10 5)";
    var fuel1: u64 = 1000;
    const result1 = try interpreter.evalString(source1, &fuel1);

    try stdout.print("Result of {s} is: ", .{source1});
    try elz.write(result1, stdout);
    try stdout.print("\n\n", .{});


    // --- Example 2: Expose a Zig function to Elz and call it ---
    std.debug.print("--- Calling a Zig function from Elz ---\n", .{});

    // 2. Register your Zig function with the interpreter.
    // It will be available in Elz under the name "zig-mul".
    try elz.env_setup.define_foreign_func(
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
}
```

When you build and run this program, the output will be:

```bash
--- Evaluating simple Elz code ---
Result of (* 10 5) is: 50

--- Calling a Zig function from Elz ---
Result of (zig-mul 7 6) is: 42
```

> [!IMPORTANT]
> Elz is implemented and tested in Zig 0.16.0.

-----

### Documentation

You can find the full API documentation for the latest release of Elz [here](https://element0lang.github.io/element-0/).

Alternatively, you can use the `make docs` command to generate the API documentation for the current version of
Elz from the source code.
This will generate HTML documentation in the `docs/api` directory, which you can serve locally with `make serve-docs`
and view in your web browser at [http://localhost:8000](http://localhost:8000).

#### Standard Library

See the [std.elz](src/stdlib/std.elz) file for the full list of available items (like functions, variables, etc.)
in the standard library.

#### Examples

Check out the [examples](examples) directory for various usage examples,
including both Element 0 code and Zig FFI examples.

-----

### Contributing

Contributions are always welcome!
Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

Element 0 is licensed under the Apache License, Version 2.0 (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is made by [Conrad Barski, M.D.](https://www.lisperati.com/logo.html) with a few changes.
* This project uses [linenoise](https://github.com/antirez/linenoise) and [bdwgc](https://github.com/bdwgc/bdwgc) C
  libraries.
* This project uses the [Chilli](https://github.com/CogitatorTech/chilli) CLI framework.
