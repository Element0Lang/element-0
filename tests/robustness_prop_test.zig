const std = @import("std");
const elz = @import("elz");
const minish = @import("minish");
const gen = minish.gen;

// The reader, the compiler, and the JSON parser accept untrusted input. These
// properties check that arbitrary input produces a value or an error, never a
// crash, and that the JSON string encoding round-trips.

const reader_chars = "()#;'`,.\"\\|abx01 \n\t+-e/@!=[]{}\xc3\xa9";

test "property: reading arbitrary text never crashes" {
    const allocator = std.testing.allocator;
    try minish.check(
        allocator,
        gen.string(.{ .min_len = 0, .max_len = 40, .charset = .custom, .custom_chars = reader_chars }),
        struct {
            fn property(text: []const u8) !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                var forms = elz.parser.readAll(text, arena.allocator()) catch return;
                forms.deinit(arena.allocator());
            }
        }.property,
        .{ .num_runs = 500 },
    );
}

test "property: evaluating arbitrary text never crashes" {
    const allocator = std.testing.allocator;
    try minish.check(
        allocator,
        gen.string(.{ .min_len = 0, .max_len = 30, .charset = .custom, .custom_chars = reader_chars }),
        struct {
            fn property(text: []const u8) !void {
                var interp = elz.Interpreter.init(.{ .enable_filesystem = false, .enable_process = false }) catch return;
                defer interp.deinit();
                var fuel: u64 = 20_000;
                _ = interp.evalString(text, &fuel) catch return;
            }
        }.property,
        .{ .num_runs = 200 },
    );
}

test "property: json-deserialize of arbitrary text never crashes" {
    const allocator = std.testing.allocator;
    try minish.check(
        allocator,
        gen.string(.{ .min_len = 0, .max_len = 40, .charset = .custom, .custom_chars = "[]{}:,\"\\utrflsn0123456789.eE+- " }),
        struct {
            fn property(text: []const u8) !void {
                var interp = elz.Interpreter.init(.{}) catch return;
                defer interp.deinit();
                // Pass the text through a string port so quoting inside it does not matter.
                var buf: [256]u8 = undefined;
                var pos: usize = 0;
                const prefix = "(json-deserialize \"";
                @memcpy(buf[pos .. pos + prefix.len], prefix);
                pos += prefix.len;
                for (text) |c| {
                    if (c == '"' or c == '\\') {
                        buf[pos] = '\\';
                        pos += 1;
                    }
                    buf[pos] = c;
                    pos += 1;
                }
                @memcpy(buf[pos .. pos + 2], "\")");
                pos += 2;
                var fuel: u64 = 20_000;
                _ = interp.evalString(buf[0..pos], &fuel) catch return;
            }
        }.property,
        .{ .num_runs = 500 },
    );
}

test "property: JSON string round-trip" {
    const allocator = std.testing.allocator;
    try minish.check(
        allocator,
        gen.string(.{ .min_len = 0, .max_len = 30, .charset = .printable }),
        struct {
            fn property(text: []const u8) !void {
                var interp = elz.Interpreter.init(.{}) catch return;
                defer interp.deinit();
                // Build (json-deserialize (json-serialize "<text>")) with Scheme escaping.
                var buf: [256]u8 = undefined;
                var pos: usize = 0;
                const prefix = "(json-deserialize (json-serialize \"";
                @memcpy(buf[pos .. pos + prefix.len], prefix);
                pos += prefix.len;
                for (text) |c| {
                    if (c == '"' or c == '\\') {
                        buf[pos] = '\\';
                        pos += 1;
                    }
                    buf[pos] = c;
                    pos += 1;
                }
                @memcpy(buf[pos .. pos + 3], "\"))");
                pos += 3;
                var fuel: u64 = 20_000;
                const result = interp.evalString(buf[0..pos], &fuel) catch return error.TestUnexpectedResult;
                if (result != .string) return error.TestUnexpectedResult;
                if (!std.mem.eql(u8, result.string.bytes, text)) return error.TestUnexpectedResult;
            }
        }.property,
        .{ .num_runs = 300 },
    );
}
