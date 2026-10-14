const std = @import("std");
const elz = @import("elz");
const minish = @import("minish");
const gen = minish.gen;
const testing = std.testing;

const Datum = struct {
    kind: enum(u8) { list = 2, vector = 7 },
    strings: []const []const u8,
};

test "property: lists and vectors of strings survive writing and reading" {
    const Property = struct {
        fn check(datum: Datum) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const values = try allocator.alloc(elz.Value, datum.strings.len);
            for (values, datum.strings) |*value, text| value.* = try elz.core.copyString(allocator, text);
            var vec: elz.core.Vector = .{ .items = values };
            const value: elz.Value = switch (datum.kind) {
                .list => try elz.sliceToList(allocator, values),
                .vector => .{ .vector = &vec },
            };
            var output = std.Io.Writer.Allocating.init(allocator);
            defer output.deinit();
            try elz.write(value, &output.writer);
            const parsed = try elz.parser.read(output.written(), allocator);
            const items = switch (datum.kind) {
                .list => try elz.listToSlice(allocator, parsed),
                .vector => blk: {
                    try testing.expect(parsed == .vector);
                    break :blk parsed.vector.items;
                },
            };
            try testing.expectEqual(datum.strings.len, items.len);
            for (items, datum.strings) |item, text| {
                try testing.expect(item == .string);
                try testing.expectEqualStrings(text, item.string.bytes);
            }
        }
        fn empty(datum: Datum) bool {
            return datum.strings.len == 0;
        }
        fn list(datum: Datum) bool {
            return datum.kind == .list;
        }
        fn vector(datum: Datum) bool {
            return datum.kind == .vector;
        }
        fn escaped(datum: Datum) bool {
            for (datum.strings) |text| {
                if (std.mem.indexOfAny(u8, text, "\x00\n\r\t\"\\") != null) return true;
            }
            return false;
        }
    };
    const generator = gen.structure(Datum, .{
        .kind = gen.enumValue(@FieldType(Datum, "kind")),
        .strings = gen.list([]const u8, gen.string(.{
            .min_len = 0,
            .max_len = 24,
            .charset = .custom,
            .custom_chars = "ab01 \x00\n\r\t\"\\",
        }), 0, 8),
    });
    var coverage = [_]minish.Coverage(Datum){
        .{ .label = "empty collections", .predicate = Property.empty },
        .{ .label = "lists", .predicate = Property.list },
        .{ .label = "vectors", .predicate = Property.vector },
        .{ .label = "escaped strings", .predicate = Property.escaped },
    };
    var statistics: minish.Statistics = .{};
    try minish.checkWithCoverage(testing.allocator, generator, Property.check, &coverage, .{
        .num_runs = 300,
        .seed = 2001,
        .statistics = &statistics,
    });
    try testing.expectEqual(@as(u32, 300), statistics.passed);
    for (coverage) |category| try testing.expect(category.hits > 0);
}

test "property: finite floats survive writing and reading exactly" {
    const Property = struct {
        fn check(number: f64) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var output = std.Io.Writer.Allocating.init(arena.allocator());
            defer output.deinit();
            try elz.write(.{ .number = number }, &output.writer);
            const parsed = try elz.parser.read(output.written(), arena.allocator());
            try testing.expect(parsed == .number);
            try testing.expectEqual(@as(u64, @bitCast(number)), @as(u64, @bitCast(parsed.number)));
        }
        fn small(number: f64) bool {
            return @abs(number) < 1e-10;
        }
        fn large(number: f64) bool {
            return @abs(number) >= 1e21;
        }
        fn negative(number: f64) bool {
            return number < 0;
        }
    };
    var coverage = [_]minish.Coverage(f64){
        .{ .label = "small magnitudes", .predicate = Property.small },
        .{ .label = "large magnitudes", .predicate = Property.large },
        .{ .label = "negative values", .predicate = Property.negative },
    };
    try minish.checkWithCoverage(testing.allocator, gen.float(f64), Property.check, &coverage, .{
        .num_runs = 500,
        .seed = 2002,
    });
    for (coverage) |category| try testing.expect(category.hits > 0);
}

const Arithmetic = struct {
    operation: enum(u8) { add = 2, subtract = 7, multiply = 42 },
    a: i64,
    b: i64,
};

test "property: exact arithmetic agrees with i128 results" {
    const Property = struct {
        fn result(input: Arithmetic) i128 {
            const a: i128 = input.a;
            const b: i128 = input.b;
            return switch (input.operation) {
                .add => a + b,
                .subtract => a - b,
                .multiply => a * b,
            };
        }
        fn check(input: Arithmetic) !void {
            var buffer: [256]u8 = undefined;
            const operation = switch (input.operation) {
                .add => "+",
                .subtract => "-",
                .multiply => "*",
            };
            const source = try std.fmt.bufPrint(&buffer, "(= ({s} {d} {d}) {d})", .{ operation, input.a, input.b, result(input) });
            var interp = try elz.Interpreter.init(.{});
            defer interp.deinit();
            var fuel: u64 = 1000;
            const value = try interp.evalString(source, &fuel);
            try testing.expect(value == .boolean and value.boolean);
        }
        fn promoted(input: Arithmetic) bool {
            return std.math.cast(i64, result(input)) == null;
        }
        fn mixed_signs(input: Arithmetic) bool {
            return (input.a < 0) != (input.b < 0);
        }
    };
    var coverage = [_]minish.Coverage(Arithmetic){
        .{ .label = "big integer results", .predicate = Property.promoted },
        .{ .label = "mixed signs", .predicate = Property.mixed_signs },
    };
    try minish.checkWithCoverage(testing.allocator, gen.structure(Arithmetic, .{
        .operation = gen.enumValue(@FieldType(Arithmetic, "operation")),
        .a = gen.int(i64),
        .b = gen.int(i64),
    }), Property.check, &coverage, .{ .num_runs = 300, .seed = 2003 });
    for (coverage) |category| try testing.expect(category.hits > 0);
}

test "property: bytevectors survive writing and reading" {
    const Property = struct {
        fn check(bytes: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var bytevector: elz.core.Bytevector = .{ .items = try arena.allocator().dupe(u8, bytes) };
            var output = std.Io.Writer.Allocating.init(arena.allocator());
            defer output.deinit();
            try elz.write(.{ .bytevector = &bytevector }, &output.writer);
            const parsed = try elz.parser.read(output.written(), arena.allocator());
            try testing.expect(parsed == .bytevector);
            try testing.expectEqualSlices(u8, bytes, parsed.bytevector.items);
        }
        fn empty(bytes: []const u8) bool {
            return bytes.len == 0;
        }
        fn high_byte(bytes: []const u8) bool {
            for (bytes) |byte| {
                if (byte >= 128) return true;
            }
            return false;
        }
    };
    var coverage = [_]minish.Coverage([]const u8){
        .{ .label = "empty bytevectors", .predicate = Property.empty },
        .{ .label = "bytes above ASCII", .predicate = Property.high_byte },
    };
    try minish.checkWithCoverage(testing.allocator, gen.list(u8, gen.int(u8), 0, 32), Property.check, &coverage, .{
        .num_runs = 300,
        .seed = 2004,
    });
    for (coverage) |category| try testing.expect(category.hits > 0);
}
