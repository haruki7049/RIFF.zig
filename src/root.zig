pub const Chunk = struct {
    four_cc: *const [4]u8,
    size: u32,
    payload: ?[]u8,

    const InitOptions = struct {
        four_cc: [4]u8,
        size: u32,
        payload: ?[]u8,
    };

    pub fn init(options: InitOptions) Chunk {
        return Chunk{
            .four_cc = options.four_cc,
            .size = options.size,
            .payload = options.payload,
        };
    }

    pub fn size(self: Chunk) !u64 {
        if (self.payload == null) {
            return 4;
        } else {
            return 0;
        }
    }
};

test "chunk-core-checks" {
    _ = Chunk.init(.{
        .four_cc = "RIFF",
        .size = 0,
        .payload = null,
    });
}
