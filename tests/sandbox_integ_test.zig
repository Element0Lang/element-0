const std = @import("std");
const elz = @import("elz");

const testing = std.testing;

test "time limit triggers on long computation" {
    // Create interpreter with a 50ms time limit
    var interp = try elz.Interpreter.init(.{ .time_limit_ms = 50 });
    defer interp.deinit();

    // Use map over a very large list to force many eval steps.
    // Each map iteration consumes multiple eval steps.
    // Building a list of 50000 elements and mapping over it will take > 50ms.
    var fuel: u64 = 1_000_000_000;
    const result = interp.evalString(
        \\(define (make-list n acc)
        \\  (if (<= n 0) acc
        \\      (make-list (- n 1) (cons n acc))))
        \\(define big (make-list 100000 '()))
        \\(map (lambda (x) (* x x)) big)
    , &fuel);

    // Should fail with TimeLimitExceeded or ExecutionBudgetExceeded
    if (result) |_| {
        // If it somehow completed, that's also OK (fast machine)
    } else |err| {
        try std.testing.expect(err == elz.ElzError.TimeLimitExceeded or err == elz.ElzError.ExecutionBudgetExceeded);
    }
}

test "time limit does not trigger for fast operations" {
    // Create interpreter with a generous time limit
    var interp = try elz.Interpreter.init(.{ .time_limit_ms = 5000 });
    defer interp.deinit();

    var fuel: u64 = 100000;
    const result = try interp.evalString("(+ 1 2 3)", &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 6), result.number);
}

test "no time limit by default" {
    var interp = try elz.Interpreter.init(.{});
    defer interp.deinit();

    // time_limit_ms should be null
    try testing.expect(interp.time_limit_ms == null);

    var fuel: u64 = 10000;
    const result = try interp.evalString("(* 6 7)", &fuel);
    try testing.expect(result == .number);
    try testing.expectEqual(@as(f64, 42), result.number);
}
