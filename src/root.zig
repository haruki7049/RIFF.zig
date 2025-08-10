const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Chunk = @import("./chunk.zig");
pub const RIFFChunk = @import("./riff_chunk.zig");
pub const ListChunk = @import("./list_chunk.zig");

pub const ToBinary = struct {
    pub fn size(value: usize) [4]u8 {
        return [4]u8{
            @intCast(value & 0xFF),
            @intCast((value >> 8) & 0xFF),
            @intCast((value >> 16) & 0xFF),
            @intCast((value >> 24) & 0xFF),
        };
    }

    pub fn data(comptime T: type, self: T, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        const data_type: type = @FieldType(T, "data");

        if (data_type == []const RIFFChunk.Data) {
            for (self.data) |value| {
                const binary = switch (value) {
                    .chunk => try value.chunk.to_binary(allocator),
                    .list => try value.list.to_binary(allocator),
                };

                try result.appendSlice(binary);
                allocator.free(binary);
            }
        } else if (data_type == []const Chunk) {
            for (self.data) |chunk| {
                const binary = try chunk.to_binary(allocator);
                try result.appendSlice(binary);
                allocator.free(binary);
            }
        } else {
            unreachable;
        }

        return result.toOwnedSlice();
    }
};

pub const FromBinary = struct {
    pub fn size(value: [4]u8) usize {
        const first: u8 = value[0];
        const second: u8 = value[1] << 2;
        const third: u8 = value[2] << 4;
        const fourth: u8 = value[3] << 6;

        return first + second + third + fourth;
    }

    /// This function is used by RIFFChunk & ListChunk
    pub fn data(comptime T: type, input: []const u8, allocator: Allocator) !@FieldType(T, "data") {
        std.debug.print("input: {any}\n", .{input});

        const data_type_info = @typeInfo(@FieldType(T, "data"));

        var result = ArrayList(data_type_info.pointer.child).init(allocator);
        defer result.deinit();

        if (input.len < 12)
            return result.toOwnedSlice();

        // const id_bin: [4]u8 = input[0..4].*;
        // const four_cc_bin: [4]u8 = input[8..12].*;
        const data_bin: []const u8 = input[12..];

        //if (!std.mem.eql(u8, &id_bin, &[_]u8{ 'R', 'I', 'F', 'F' }) and !std.mem.eql(u8, &id_bin, &[_]u8{ 'L', 'I', 'S', 'T' })) {
        //    const chunk: T = T{
        //        .id = id_bin,
        //        .four_cc = four_cc_bin,
        //        .data = data_bin,
        //    };
        //    try result.append(chunk);
        //}

        if (data_type_info.pointer.child == RIFFChunk.Data) {
            //for (self.data) |value| {
            //    const binary = switch (value) {
            //        .chunk => try value.chunk.to_binary(allocator),
            //        .list => try value.list.to_binary(allocator),
            //    };

            //    try result.appendSlice(binary);
            //    allocator.free(binary);
            //}

            @panic("TODO with RIFFChunk.Data");
        } else if (data_type_info.pointer.child == Chunk) {
            const chunks: []const Chunk = FromBinary.to_chunks(data_bin);
            try result.appendSlice(chunks);
        } else {
            unreachable;
        }

        return result.toOwnedSlice();
    }

    fn to_chunks(input: []const u8) []const Chunk {
        std.debug.print("FromBinary.to_chunks(): {any}\n", .{input});

        if (input.len < 12)
            return &[_]Chunk{};

        @panic("TODO");
    }
};

test "minimal_list" {
    const list: ListChunk = ListChunk{
        .four_cc = .{ 'I', 'N', 'F', 'O' },
        .data = &.{},
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ 'W', 'A', 'V', 'E' },
        .data = &.{
            RIFFChunk.Data{ .list = list },
        },
    };

    try std.testing.expectEqual(riff.size(), 16);
}

test "minimal_riff" {
    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ 'W', 'A', 'V', 'E' },
        .data = &.{},
    };

    try std.testing.expectEqual(riff.size(), 4);
}

test "riff" {
    const data: Chunk = Chunk{
        .id = .{ 'd', 'a', 't', 'a' },
        .four_cc = .{ ' ', ' ', ' ', ' ' },
        .data = &.{},
    };
    const info: Chunk = Chunk{
        .id = .{ 'i', 'n', 'f', 'o' },
        .four_cc = .{ ' ', ' ', ' ', ' ' },
        .data = &.{},
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ 'W', 'A', 'V', 'E' },
        .data = &.{
            RIFFChunk.Data{ .chunk = data },
            RIFFChunk.Data{ .chunk = info },
        },
    };

    try std.testing.expectEqual(riff.size(), 28);
}

test "more_complex_riff" {
    const list: ListChunk = ListChunk{
        .four_cc = .{ 'I', 'N', 'F', 'O' },
        .data = &.{},
    };

    const data: Chunk = Chunk{
        .id = .{ 'd', 'a', 't', 'a' },
        .four_cc = .{ ' ', ' ', ' ', ' ' },
        .data = "EXAMPLE_DATA", // 12 bytes
    };

    const info: Chunk = Chunk{
        .id = .{ 'i', 'n', 'f', 'o' },
        .four_cc = .{ ' ', ' ', ' ', ' ' },
        .data = "THIS IS EXAMPLE DATA", // 20 bytes
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ 'W', 'A', 'V', 'E' },
        .data = &.{
            RIFFChunk.Data{ .list = list },
            RIFFChunk.Data{ .chunk = data },
            RIFFChunk.Data{ .chunk = info },
        },
    };

    try std.testing.expectEqual(riff.size(), 72);
}
