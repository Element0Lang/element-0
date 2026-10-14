const std = @import("std");
const elz = @import("elz");
const testing = std.testing;

fn eval(interp: *elz.Interpreter, source: []const u8) !elz.Value {
    var fuel: u64 = 1000000;
    return interp.evalString(source, &fuel);
}

test "native roots retain values across frequent collection" {
    var interp = try elz.Interpreter.init(.{ .heap_limit_bytes = 4 * 1024 * 1024 });
    defer interp.deinit();
    interp.gc_state.collect_every_instruction = true;
    var kept = try eval(&interp, "(vector (cons 1 2) \"kept\")");
    var root: elz.Root = .{};
    interp.protect(&root, &kept);
    defer root.deinit();
    for (0..10) |_| _ = try eval(&interp, "(cons 3 4)");
    try interp.collect();
    try testing.expectEqual(@as(i64, 1), kept.vector.items[0].pair.car.exact_integer);
    try testing.expectEqualStrings("kept", kept.vector.items[1].string.bytes);
    kept = .nil;
    try interp.collect();
    try testing.expect(interp.gc_state.collections > 10);
}

test "native pairs and cyclic graphs are traced and reclaimed" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();
    try interp.collect();
    const before = interp.gc_state.heap.bytes_used;
    const pair = try interp.allocator.create(elz.core.Pair);
    pair.* = .{ .car = .{ .exact_integer = 42 }, .cdr = .{ .pair = pair } };
    var value: elz.Value = .{ .pair = pair };
    const root = try interp.allocator.create(elz.Root);
    root.* = .{};
    interp.protect(root, &value);
    try interp.collect();
    try testing.expectEqual(@as(i64, 42), value.pair.cdr.pair.car.exact_integer);
    root.deinit();
    interp.allocator.destroy(root);
    try interp.collect();
    try testing.expectEqual(before, interp.gc_state.heap.bytes_used);
}

test "closures macros records and continuations survive instruction collections" {
    var interp = try elz.Interpreter.init(.{ .heap_limit_bytes = 4 * 1024 * 1024 });
    defer interp.deinit();
    interp.gc_state.collect_every_instruction = true;
    _ = try eval(
        &interp,
        "(define (counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n))) " ++
            "(define c (counter)) " ++
            "(define-syntax twice (syntax-rules () ((_ x) (+ x x)))) " ++
            "(define-record-type <gc-box> (make-gc-box x) gc-box? (x gc-box-x)) " ++
            "(define b (make-gc-box (cons 10 20)))",
    );
    try interp.collect();
    try testing.expectEqual(@as(i64, 1), (try eval(&interp, "(c)")).exact_integer);
    try testing.expectEqual(@as(i64, 2), (try eval(&interp, "(c)")).exact_integer);
    try testing.expectEqual(@as(i64, 24), (try eval(&interp, "(twice 12)")).exact_integer);
    try testing.expectEqual(@as(i64, 10), (try eval(&interp, "(car (gc-box-x b))")).exact_integer);
    try testing.expectEqual(@as(i64, 42), (try eval(&interp, "(call/cc (lambda (k) (k 42) 0))")).exact_integer);
    try testing.expectEqual(@as(i64, 7), (try eval(&interp, "(reset (+ 1 (shift k (k 6))))")).exact_integer);
}

test "allocation stress stays within a fixed heap and OOM preserves roots" {
    var interp = try elz.Interpreter.init(.{ .heap_limit_bytes = 4 * 1024 * 1024 });
    defer interp.deinit();
    _ = try eval(&interp, "(define kept (cons 42 0))");
    try testing.expectEqual(@as(i64, 0), (try eval(
        &interp,
        "(let loop ((n 4000)) (if (= n 0) n (begin (make-vector 100) (loop (- n 1)))))",
    )).exact_integer);
    try testing.expect(interp.gc_state.collections > 0);
    try testing.expectError(error.OutOfMemory, eval(&interp, "(make-vector 3000000)"));
    try interp.collect();
    try testing.expectEqual(@as(i64, 42), (try eval(&interp, "(car kept)")).exact_integer);
    try testing.expect(interp.gc_state.heap.bytes_used <= 4 * 1024 * 1024);
    try testing.expectError(error.OutOfMemory, elz.Interpreter.init(.{ .heap_limit_bytes = 128 }));
}

fn native_callback(cb: elz.ffi.ElzCallback) !elz.Value {
    const interp = elz.ffi.active_interp.?;
    const first = try cb.call(&.{});
    try testing.expectError(error.CollectionUnsafe, interp.collect());
    _ = try cb.call(&.{});
    return first;
}

test "native callback intermediates survive nested execution" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();
    interp.gc_state.collect_every_instruction = true;
    try elz.define_foreign_func(interp.root_env, "native-test", native_callback);
    const result = try eval(&interp, "(car (native-test (lambda () (cons 42 0))))");
    try testing.expectEqual(@as(i64, 42), result.exact_integer);
}

test "independent interpreters and arbitrary root removal" {
    var first = try elz.Interpreter.init(.{});
    defer first.deinit();
    var second = try elz.Interpreter.init(.{});
    defer second.deinit();
    var a = try eval(&first, "(cons 11 0)");
    var ra: elz.Root = .{};
    first.protect(&ra, &a);
    var b = try eval(&first, "(cons 22 0)");
    var rb: elz.Root = .{};
    first.protect(&rb, &b);
    ra.deinit();
    defer rb.deinit();
    try second.collect();
    try first.collect();
    try testing.expectEqual(@as(i64, 22), b.pair.car.exact_integer);
}

test "empty native buffers retain their capacity across collection" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();
    var items = std.ArrayList(elz.Value).empty;
    defer items.deinit(interp.allocator);
    try items.ensureTotalCapacity(interp.allocator, 32);
    var root: elz.Root = .{};
    interp.protect(&root, &items);
    defer root.deinit();
    try interp.collect();
    try items.append(interp.allocator, .{ .exact_integer = 42 });
    try interp.collect();
    try testing.expectEqual(@as(i64, 42), items.items[0].exact_integer);
}

test "collection closes unreachable file ports and retains rooted ports" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();
    var port = try eval(&interp, "(open-input-file \"AGENTS.md\")");
    var root: elz.Root = .{};
    interp.protect(&root, &port);
    defer root.deinit();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{port.port.kind.file.file.handle});
    try interp.collect();
    _ = try std.Io.Dir.cwd().statFile(interp.io, path, .{});
    port = .nil;
    try interp.collect();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(interp.io, path, .{}));
    try testing.expectEqual(@as(usize, 0), interp.gc_state.file_ports.items.len);
}

test "interpreter teardown closes file ports" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var interp = try elz.Interpreter.init(.{});
    var alive = true;
    defer if (alive) interp.deinit();
    const port = try eval(&interp, "(open-input-file \"AGENTS.md\")");
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{port.port.kind.file.file.handle});
    const io = interp.io;
    interp.deinit();
    alive = false;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
}
