const constants = @import("chunk/constants.zig");
const contents = @import("chunk/contents.zig");
const id = @import("chunk/id.zig");

test "Init chunk" {
    _ = contents.Contents{
        .childlen = .{
            .id = id.chunkid.init(.{
                .value = [4]u8{ 'R', 'I', 'F', 'F' },
            }),
            .child_id = id.chunkid.init(.{
                .value = [4]u8{ 'L', 'I', 'S', 'T' },
            }),
            .contents = contents.Contents{
                .data = contents.Data{
                    .id = id.chunkid.init(.{
                        .value = [4]u8{ 'R', 'I', 'F', 'F' },
                    }),
                    .data = [_]u8{
                        'F',
                        'O',
                        'O',
                        '!',
                        '!',
                    },
                },
            },
        },
    };
}
