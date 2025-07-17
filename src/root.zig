const std = @import("std");

const Chunk = struct {
    const Self = @This();

    id: []const u8,
    four_cc: []const u8,
    data: Data,

    fn size(self: Self) usize {
        const four_cc_size = self.four_cc.len;
        const data_size: usize = switch (self.data) {
            .binary => 0,
            .chunks => blk: {
                var result: usize = 0;

                for (self.data.chunks) |chunk| {
                    result += chunk.id.len;
                    result += chunk.size();
                }

                break :blk result;
            },
        };

        return four_cc_size + data_size;
    }

    const Data = union(DataTag) {
        binary: []const u8,
        chunks: []const Chunk,
    };

    const DataTag = enum {
        binary,
        chunks,
    };
};

test "minimal_riff" {
    const riff: Chunk = Chunk{
        .id = "RIFF",
        .four_cc = "WAVE",
        .data = Chunk.Data{ .binary = "" },
    };

    try std.testing.expectEqual(riff.size(), 4);
}

test "miminal_list_chunk" {
    const list: Chunk = Chunk{
        .id = "LIST",
        .four_cc = "INFO",
        .data = Chunk.Data{ .chunks = &.{} },
    };
    const riff: Chunk = Chunk{
        .id = "RIFF",
        .four_cc = "WAVE",
        .data = Chunk.Data{ .chunks = &.{
            list,
        } },
    };

    try std.testing.expectEqual(riff.size(), 12);
}

test "riff" {
    const data: Chunk = Chunk{
        .id = "data",
        .four_cc = "",
        .data = Chunk.Data{ .binary = "" },
    };
    const info: Chunk = Chunk{
        .id = "info",
        .four_cc = "hoge",
        .data = Chunk.Data{ .binary = &.{
            0x00,
        } },
    };

    const riff: Chunk = Chunk{
        .id = "RIFF",
        .four_cc = "WAVE",
        .data = Chunk.Data{
            .chunks = &.{
                data,
                info,
            },
        },
    };

    try std.testing.expectEqual(riff.size(), 16);
}
