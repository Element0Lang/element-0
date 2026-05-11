const std = @import("std");
const elz = @import("elz");

fn zig_pow(base: f64, exp: f64) f64 {
    return std.math.pow(f64, base, exp);
}

pub fn main() !void {
    var interpreter = try elz.Interpreter.init(.{});
    try elz.define_foreign_func(interpreter.root_env, "zig-pow", zig_pow);
    const source = "(zig-pow 2 8)";
    std.debug.print("Evaluating Element 0 code: {s}\n", .{source});
    var fuel: u64 = 1000;
    const result = try interpreter.evalString(source, &fuel);
    var buffer: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(interpreter.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("Result: ");
    try elz.write(result, stdout);
    try stdout.writeAll("\n");
    try stdout.flush();
}
