const std = @import("std");

pub const Chunk = struct {
    const Self = @This();

    id: [4]*const u8,
    four_cc: [4]*const u8,
    data: []const u8,

    /// Calculate this chunk's data size
    /// This function uses Byte
    pub fn size(self: Self) usize {
        const four_cc_size: usize = self.four_cc.len;
        const data_size: usize = self.data.len;

        return four_cc_size + data_size;
    }
};

pub const RIFFChunk = struct {
    const Self = @This();

    const id: []const u8 = "RIFF";

    four_cc: [4]*const u8,
    data: []const Data,

    /// Calculate this chunk's data size
    /// This function uses Byte
    pub fn size(self: Self) usize {
        const four_cc_size = self.four_cc.len;
        var data_size: usize = 0;

        for (self.data) |data| {
            switch (data) {
                .chunk => {
                    data_size += data.chunk.id.len; // Chunk ID length
                    data_size += 4; // Length of the Chunk size itself
                    data_size += data.chunk.size(); // Chunk's size
                },
                .list => {
                    data_size += data.list.id.len; // List's id length
                    data_size += 4; // Length of the List size itself
                    data_size += data.list.size(); // List's size
                },
            }
        }

        return data_size + four_cc_size;
    }

    const Data = union(DataTag) {
        chunk: Chunk,
        list: ListChunk,
    };

    const DataTag = enum {
        chunk,
        list,
    };
};

pub const ListChunk = struct {
    const Self = @This();

    id: [4]*const u8 = .{ &'L', &'I', &'S', &'T' },
    four_cc: [4]*const u8,
    data: []const Chunk,

    /// Calculate this chunk's data size
    /// This function uses Byte
    pub fn size(self: Self) usize {
        const four_cc_size = self.four_cc.len;
        const data_size: usize = blk: {
            var result: usize = 0;

            for (self.data) |chunk| {
                result += chunk.size();
            }

            break :blk result;
        };

        return four_cc_size + data_size;
    }
};

test "minimal_list" {
    const list: ListChunk = ListChunk{
        .four_cc = .{ &'I', &'N', &'F', &'O' },
        .data = &.{},
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ &'W', &'A', &'V', &'E' },
        .data = &.{
            RIFFChunk.Data{ .list = list },
        },
    };

    try std.testing.expectEqual(riff.size(), 16);
}

test "minimal_riff" {
    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ &'W', &'A', &'V', &'E' },
        .data = &.{},
    };

    try std.testing.expectEqual(riff.size(), 4);
}

test "riff" {
    const data: Chunk = Chunk{
        .id = .{ &'d', &'a', &'t', &'a' },
        .four_cc = .{ &' ', &' ', &' ', &' ' },
        .data = &.{},
    };
    const info: Chunk = Chunk{
        .id = .{ &'i', &'n', &'f', &'o' },
        .four_cc = .{ &' ', &' ', &' ', &' ' },
        .data = &.{},
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ &'W', &'A', &'V', &'E' },
        .data = &.{
            RIFFChunk.Data{ .chunk = data },
            RIFFChunk.Data{ .chunk = info },
        },
    };

    try std.testing.expectEqual(riff.size(), 28);
}

test "more_complex_riff" {
    const list: ListChunk = ListChunk{
        .four_cc = .{ &'I', &'N', &'F', &'O' },
        .data = &.{},
    };

    const data: Chunk = Chunk{
        .id = .{ &'d', &'a', &'t', &'a' },
        .four_cc = .{ &' ', &' ', &' ', &' ' },
        .data = "EXAMPLE_DATA", // 12 bytes
    };

    const info: Chunk = Chunk{
        .id = .{ &'i', &'n', &'f', &'o' },
        .four_cc = .{ &' ', &' ', &' ', &' ' },
        .data = "THIS IS EXAMPLE DATA", // 20 bytes
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ &'W', &'A', &'V', &'E' },
        .data = &.{
            RIFFChunk.Data{ .list = list },
            RIFFChunk.Data{ .chunk = data },
            RIFFChunk.Data{ .chunk = info },
        },
    };

    try std.testing.expectEqual(riff.size(), 72);
}
