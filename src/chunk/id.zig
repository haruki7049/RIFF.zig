/// A chunk id, also known as FourCC
pub const ChunkID = struct {
    value: [4]u8,

    const InitOptions = struct {
        value: [4]u8,
    };

    pub fn init(options: InitOptions) ChunkID {
        return ChunkID{
            .value = options.value,
        };
    }
};
