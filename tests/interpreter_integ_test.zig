const std = @import("std");
const elz = @import("elz");

const testing = std.testing;

// ---------------------------------------------------------------------------
// Interpreter initialization and lifecycle
// ---------------------------------------------------------------------------

test "interpreter initializes with default flags" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    // nil should be defined
    const nil_val = try interp.root_env.get("nil", &interp);
    try testing.expect(nil_val == .nil);
}

test "interpreter initializes with all features disabled" {
    var interp = try elz.Interpreter.init(.{
        .enable_math = false,
        .enable_lists = false,
        .enable_predicates = false,
        .enable_strings = false,
        .enable_io = false,
    });
    defer interp.deinit();

    // Basic evaluation should still work
    var fuel: u64 = 1000;
    const result = try interp.evalString("42", &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 42), result.number);
}

test "math disabled prevents arithmetic" {
    var interp = try elz.Interpreter.init(.{ .enable_math = false });
    defer interp.deinit();

    var fuel: u64 = 1000;
    try testing.expectError(elz.ElzError.SymbolNotFound, interp.evalString("(+ 1 2)", &fuel));
}

// ---------------------------------------------------------------------------
// Basic evaluation through the public API
// ---------------------------------------------------------------------------

test "evalString handles multiple expressions" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;
    const result = try interp.evalString("(define x 10) (define y 20) (+ x y)", &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 30), result.number);
}

test "evalString with lambda and closure" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;
    const result = try interp.evalString(
        \\(define (make-adder n)
        \\  (lambda (x) (+ n x)))
        \\(define add5 (make-adder 5))
        \\(add5 10)
    , &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 15), result.number);
}

test "evalString with recursive function" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 100000;
    const result = try interp.evalString(
        \\(define (factorial n)
        \\  (if (<= n 1) 1
        \\      (* n (factorial (- n 1)))))
        \\(factorial 10)
    , &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 3628800), result.number);
}

// ---------------------------------------------------------------------------
// Error propagation
// ---------------------------------------------------------------------------

test "symbol not found propagates" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 1000;
    try testing.expectError(elz.ElzError.SymbolNotFound, interp.evalString("undefined-var", &fuel));
}

test "fuel exhaustion propagates" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    // Use a non-TCO recursive function that will definitely exhaust fuel.
    // The (+ 1 ...) wrapper prevents tail-call optimization.
    var fuel: u64 = 100;
    try testing.expectError(
        elz.ElzError.ExecutionBudgetExceeded,
        interp.evalString("(letrec ((loop (lambda () (+ 1 (loop))))) (loop))", &fuel),
    );
}

test "division by zero propagates" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 1000;
    try testing.expectError(elz.ElzError.DivisionByZero, interp.evalString("(/ 1 0)", &fuel));
}

// ---------------------------------------------------------------------------
// Data types through the public API
// ---------------------------------------------------------------------------

test "string operations" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;
    const result = try interp.evalString(
        \\(string-append "hello" " " "world")
    , &fuel);
    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello world", result.string);
}

test "list operations" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;
    const result = try interp.evalString("(length '(1 2 3 4 5))", &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 5), result.number);
}

test "boolean operations" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;

    const r1 = try interp.evalString("(and #t #t #t)", &fuel);
    try testing.expect(r1 == .boolean);
    try testing.expect(r1.boolean == true);

    fuel = 10000;
    const r2 = try interp.evalString("(or #f #f #t)", &fuel);
    try testing.expect(r2 == .boolean);
    try testing.expect(r2.boolean == true);
}

test "vector operations" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;
    const result = try interp.evalString(
        \\(define v (vector 10 20 30))
        \\(vector-ref v 1)
    , &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 20), result.number);
}

// ---------------------------------------------------------------------------
// Standard library loaded correctly
// ---------------------------------------------------------------------------

test "stdlib functions available" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 100000;

    // filter from stdlib
    const result = try interp.evalString(
        \\(length (filter even? '(1 2 3 4 5 6)))
    , &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 3), result.number);
}

test "fold-left from stdlib" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 100000;
    const result = try interp.evalString(
        \\(fold-left + 0 '(1 2 3 4 5))
    , &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 15), result.number);
}

// ---------------------------------------------------------------------------
// Try/catch error handling
// ---------------------------------------------------------------------------

test "try/catch catches errors" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;
    const result = try interp.evalString(
        \\(try (/ 1 0) (catch err "caught"))
    , &fuel);
    try testing.expect(result == .string);
    try testing.expectEqualStrings("caught", result.string);
}

// ---------------------------------------------------------------------------
// Module system
// ---------------------------------------------------------------------------

test "quasiquote and unquote" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;
    _ = try interp.evalString("(define x 42)", &fuel);
    fuel = 10000;
    const result = try interp.evalString("(quasiquote (a (unquote x) b))", &fuel);
    // Should produce the list (a 42 b)
    try testing.expect(result == .pair);
    try testing.expect(result.pair.car.is_symbol("a"));
    const second = result.pair.cdr.pair;
    try testing.expect(second.car == .number);
    try testing.expectEqual(@as(f64, 42), second.car.number);
}

// ---------------------------------------------------------------------------
// Writer roundtrip through public API
// ---------------------------------------------------------------------------

test "write produces valid output" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    var fuel: u64 = 10000;
    const value = try interp.evalString("'(1 2 3)", &fuel);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try elz.write(value, fbs.writer());
    try testing.expectEqualStrings("(1 2 3)", fbs.getWritten());
}
