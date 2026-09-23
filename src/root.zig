//! RIFF (Resource Interchange File Format) parser and serializer library for Zig.
//!
//! This library provides functionality to parse, manipulate, and serialize RIFF format files.
//! RIFF is a generic file container format used by many multimedia formats including WAV, AVI, and WebP.
//!
//! ## Overview
//!
//! RIFF files consist of chunks, where each chunk has:
//! - A 4-byte identifier (FourCC)
//! - A 4-byte size field (little-endian)
//! - Data payload
//!
//! This library supports three types of chunks:
//! - **Basic chunks**: Simple data containers with a FourCC and data payload
//! - **LIST chunks**: Containers that hold multiple sub-chunks
//! - **RIFF chunks**: The root container that defines the file type
//!
//! ## Usage Example
//!
//! ```zig
//! const std = @import("std");
//! const riff = @import("riff_zig");
//!
//! pub fn main(init: std.process.Init) !void {
//!     const allocator = init.gpa;
//!     const io = init.io;
//!
//!     // Create a WAVE file structure
//!     const format_data = "..."; // Your format chunk data
//!     const audio_data = "...";  // Your audio sample data
//!     const wave_chunk = riff.Chunk{ .riff = .{
//!         .four_cc = try riff.FourCC.new("WAVE"),
//!         .chunks = &[_]riff.Chunk{
//!             .{ .chunk = .{ .four_cc = try riff.FourCC.new("fmt "), .data = format_data } },
//!             .{ .chunk = .{ .four_cc = try riff.FourCC.new("data"), .data = audio_data } },
//!         },
//!     } };
//!
//!     // Serialize to file. write() takes a *std.Io.Writer, so wrap the file
//!     // in a buffered File.Writer and pass its `.interface`, then flush.
//!     const out_file = try std.Io.Dir.cwd().createFile(io, "output.wav", .{});
//!     defer out_file.close(io);
//!     var out_buffer: [4096]u8 = undefined;
//!     var file_writer = out_file.writer(io, &out_buffer);
//!     try riff.write(wave_chunk, &file_writer.interface);
//!     try file_writer.interface.flush();
//!
//!     // Parse from file. read() pulls bytes from the reader as it goes, so a
//!     // small-buffered file reader works: no need to load the whole file first.
//!     const in_file = try std.Io.Dir.cwd().openFile(io, "input.wav", .{});
//!     defer in_file.close(io);
//!     var in_buffer: [4096]u8 = undefined;
//!     var file_reader = in_file.reader(io, &in_buffer);
//!     const parsed = try riff.read(allocator, &file_reader.interface);
//!     defer parsed.deinit(allocator);
//! }
//! ```
//!
//! ## API Functions
//!
//! - `read`: Parse a RIFF chunk from a reader
//! - `write`: Serialize a RIFF chunk to a writer
//! - `Chunk.deinit`: Free allocated memory for a chunk and its children

const std = @import("std");

/// Pull-style streaming parser (`stream.Iterator`), and the tree builder
/// `read()` is implemented with (`stream.readTree`). See `stream.zig`.
pub const stream = @import("stream.zig");

test {
    _ = stream;
}

/// Represents a Four-Character Code (FourCC) identifier used in RIFF chunks.
/// A FourCC is a 4-byte sequence that identifies the type of a chunk (e.g., "WAVE", "fmt ", "data").
/// FourCC codes are case-sensitive and commonly used in multimedia file formats.
pub const FourCC = struct {
    /// The 4-byte array containing the FourCC identifier.
    inner: [4]u8,

    /// Error type for FourCC creation failures.
    pub const NewError = error{
        /// Returned when the input string is not exactly 4 bytes long.
        InvalidFormat,
    };

    /// Creates a new FourCC from a byte slice.
    ///
    /// Parameters:
    ///   - `four_cc`: A byte slice that must be exactly 4 bytes long.
    ///
    /// Returns: A new `FourCC` instance on success.
    ///
    /// Errors:
    ///   - `InvalidFormat`: If the input slice length is not exactly 4 bytes.
    pub fn new(four_cc: []const u8) NewError!FourCC {
        if (four_cc.len != 4)
            return error.InvalidFormat;

        return FourCC{
            .inner = four_cc[0..4].*,
        };
    }
};

/// Shared payload of `Chunk`'s `.list` and `.riff` variants: a type FourCC
/// followed by the container's sub-chunks. Naming this type (rather than
/// leaving `.list`/`.riff` as two separately-declared but field-identical
/// anonymous structs) gives them the same type, so `switch` prongs over
/// `Chunk` can merge `.list`/`.riff` into a single capture - their handling
/// is (and should be) identical apart from which literal FourCC ("LIST" vs
/// "RIFF") gets written/matched.
pub const Container = struct {
    four_cc: FourCC,
    chunks: []const Chunk,
};

/// Represents a RIFF (Resource Interchange File Format) chunk.
/// Models the three types of chunks that can appear in RIFF files:
///
/// ## Chunk Variants
///
/// - **chunk**: A basic RIFF chunk with a FourCC identifier and data payload.
///   Used for leaf nodes in the RIFF tree structure (e.g., "fmt ", "data" chunks in WAVE files).
///
/// - **list**: A LIST chunk containing a list of sub-chunks.
///   Used to group related chunks together without specifying a file type.
///
/// - **riff**: A RIFF chunk representing the root container of a RIFF file.
///   This is typically the outermost chunk and specifies the file type (e.g., "WAVE", "AVI").
///
/// ## Memory Management
///
/// Chunks created by `read()` allocate memory that must be freed using `deinit()`.
/// Chunks created with static data (using `&[_]Chunk{...}` syntax) may not need `deinit()`.
pub const Chunk = union(enum) {
    /// A basic RIFF chunk with a FourCC identifier and data payload.
    /// The `four_cc` is a 4-byte identifier (e.g., "fmt ", "data").
    /// The `data` field contains the chunk's payload bytes.
    ///
    /// The four_cc "RIFF" and "LIST" are reserved for containers: use `.riff`
    /// or `.list` for those. `write()` rejects a leaf with either id with
    /// `error.ReservedFourCC`.
    chunk: struct {
        four_cc: FourCC,
        data: []const u8,
    },
    /// A LIST chunk containing a type identifier and a list of sub-chunks.
    /// LIST chunks are used to group multiple chunks together under a named type
    /// (e.g., "INFO" for metadata, "sdta" for sample data in SoundFont files).
    list: Container,
    /// A RIFF chunk representing the root container of a RIFF file.
    /// The `four_cc` specifies the file type (e.g., "WAVE" for audio files).
    /// The `chunks` field contains all sub-chunks within this RIFF container.
    riff: Container,

    /// Deallocates memory for this chunk and all of its children recursively.
    /// This method should be called when you're done using a chunk that was
    /// created by `read()` or manually allocated with an allocator.
    ///
    /// For `.chunk` variants: frees the data buffer. For `.list`/`.riff`
    /// variants: recursively frees all child chunks, then the chunks array.
    ///
    /// `deinit()` recurses once per `.list`/`.riff` nesting level with no
    /// depth limit of its own (unlike `read()`/`write()`, which are both
    /// bounded by `max_nesting_depth`), since bailing out partway through
    /// would leak whatever it hadn't freed yet. A `Chunk` returned by
    /// `read()` is already within `max_nesting_depth`, so this only matters
    /// for a tree built some other way: keep any such tree within
    /// `max_nesting_depth` to avoid a stack overflow here.
    ///
    /// Parameters:
    ///   - `allocator`: The same allocator that was used to create this chunk.
    pub fn deinit(self: Chunk, allocator: std.mem.Allocator) void {
        switch (self) {
            .chunk => |b| allocator.free(b.data),
            .list, .riff => |c| {
                for (c.chunks) |child| child.deinit(allocator);
                allocator.free(c.chunks);
            },
        }
    }
};

/// Maximum nesting depth of RIFF/LIST containers that `read()`
/// will descend into, and that `write()` will serialize. Guards against a
/// stack-overflow crash from adversarial input with many trivially nested
/// LIST chunks (each level costs only 12 bytes: "LIST" + size + type
/// FourCC) on the read side, and from a `Chunk` tree built some other way
/// (not from `read()`, which is already bounded) on the write side -
/// neither would otherwise recurse without bound. See also `Chunk.deinit()`,
/// which has no enforced bound of its own.
///
/// Only containers are counted, and the top-level chunk is at depth 0, so
/// `read()` and `write()` both accept up to `max_nesting_depth + 1` containers
/// along any path, with any leaf chunks inside the innermost one. Leaf chunks
/// have no depth limit of their own on either side, so whatever `read()`
/// returns can always be passed back to `write()`.
pub const max_nesting_depth: usize = 64;

/// Errors describing malformed RIFF input, shared by `ReadError` and
/// `stream.Error`.
pub const FormatError = error{
    /// The input data does not conform to the expected RIFF format structure.
    /// This can happen if chunk headers are incomplete or malformed.
    InvalidFormat,
    /// The actual data size does not match the size specified in the chunk header.
    /// This typically indicates corrupted or truncated RIFF data.
    SizeMismatch,
    /// RIFF/LIST container nesting exceeded `max_nesting_depth`.
    NestingTooDeep,
};

/// Error type returned by `read()`.
pub const ReadError = FormatError || std.mem.Allocator.Error || FourCC.NewError || error{
    /// The underlying reader failed (an I/O error, not a problem with the RIFF data).
    ReadFailed,
};

/// Error type returned by `write()`.
pub const WriteError = std.Io.Writer.Error || error{
    /// A `.chunk`'s data length, or a `.list`/`.riff` chunk's serialized
    /// sub-chunk payload length, does not fit in a `u32` (RIFF size fields
    /// are 32-bit).
    PayloadTooLarge,
    /// `.list`/`.riff` nesting in `chunk` exceeded `max_nesting_depth`. Guards
    /// against a stack-overflow crash from a deeply nested `Chunk` tree that
    /// did not come from `read()` (which is already bounded by the same
    /// limit) - e.g. one built programmatically.
    NestingTooDeep,
    /// A `.list`/`.riff` container's computed serialized size was odd. Every
    /// child is padded to an even length and the type FourCC is 4 bytes, so
    /// this cannot happen unless that size computation is broken; it is
    /// reported instead of emitting a container whose size field is unpadded.
    OddContainerSize,
    /// A leaf `.chunk` has the four_cc "RIFF" or "LIST". Those ids mark
    /// containers, so `read()` would parse such a chunk's payload as a
    /// container (failing, or silently turning the leaf into a `.list`/`.riff`)
    /// instead of returning the leaf. Use `.list`/`.riff` to write a container.
    ReservedFourCC,
};

/// Serializes a RIFF chunk to its binary representation and writes it to a writer.
///
/// This function converts a `Chunk` structure into the binary RIFF format according to the specification.
/// The serialization format depends on the chunk variant:
///
/// ## Serialization Format
///
/// - **Basic chunk (.chunk)**:
///   - FourCC identifier (4 bytes)
///   - Data size (4 bytes, little-endian u32) - size of the data payload only
///   - Data payload (variable length)
///
/// - **LIST chunk (.list)**:
///   - "LIST" identifier (4 bytes)
///   - Data size (4 bytes, little-endian u32) - size of FourCC (4) + all serialized sub-chunks
///   - List type FourCC (4 bytes, e.g., "INFO")
///   - Serialized sub-chunks (variable length)
///
/// - **RIFF chunk (.riff)**:
///   - "RIFF" identifier (4 bytes)
///   - Data size (4 bytes, little-endian u32) - size of FourCC (4) + all serialized sub-chunks
///   - File type FourCC (4 bytes, e.g., "WAVE")
///   - Serialized sub-chunks (variable length)
///
/// ## Usage
///
/// The function serializes nested chunks in two passes: first it computes
/// each `.list`/`.riff` container's total serialized size with a pure,
/// allocation-free walk of the tree (`containerChildrenSize`), then it
/// streams the header and children directly to `writer`. No intermediate
/// buffer is built, so nested containers are not copied once per level. The
/// size walk is repeated for each nested container's own size field, so a
/// chunk is measured once per container that encloses it; the cost is
/// bounded by `max_nesting_depth`.
///
/// Parameters:
///   - `chunk`: The RIFF chunk to serialize (can be `.chunk`, `.list`, or `.riff` variant).
///   - `writer`: The `std.Io.Writer` to output the serialized binary data to (e.g. `&file_writer.interface`,
///     `&std.Io.Writer.Allocating.writer`).
///
/// Returns: `void` on success.
///
/// Errors: see `WriteError`.
///   - `std.Io.Writer.Error.WriteFailed`: If the writer fails (disk full, connection errors, etc.).
///   - `PayloadTooLarge`: If a `.chunk`'s data length, or any `.list`/`.riff` chunk's
///     serialized sub-chunk payload length, does not fit in a `u32` (RIFF size
///     fields are 32-bit).
///   - `NestingTooDeep`: If `.list`/`.riff` nesting in `chunk` exceeds `max_nesting_depth`.
///   - `OddContainerSize`: If a `.list`/`.riff` container's computed size is odd. Cannot
///     happen for a correct size computation; nothing is written for that container.
///   - `ReservedFourCC`: If a leaf `.chunk` has the four_cc "RIFF" or "LIST". Those ids are
///     reserved for containers (`.riff`/`.list`); nothing is written.
pub fn write(chunk: Chunk, writer: *std.Io.Writer) WriteError!void {
    return writeChunk(chunk, writer, 0);
}

/// `write()`'s actual implementation, with the nesting-depth counter that
/// `write()`'s public signature has no room for. Bounded by
/// `max_nesting_depth` the same way the streaming parser bounds `read()`: a
/// `Chunk` tree passed to `write()` isn't required to have come from
/// `read()`, so nothing else stops a deeply nested tree built some other way
/// from overflowing the stack here.
fn writeChunk(chunk: Chunk, writer: *std.Io.Writer, depth: usize) WriteError!void {
    switch (chunk) {
        .chunk => |b| {
            if (stream.isContainer(&b.four_cc.inner))
                return error.ReservedFourCC;
            const data_size = std.math.cast(u32, b.data.len) orelse return error.PayloadTooLarge;

            try writer.writeAll(&b.four_cc.inner);
            try writer.writeInt(u32, data_size, .little);
            try writer.writeAll(b.data);

            // Add padding byte if data size is odd
            if (b.data.len % 2 == 1) {
                try writer.writeByte(0);
            }
        },
        .list, .riff => |c, tag| {
            if (depth > max_nesting_depth)
                return error.NestingTooDeep;

            const id = if (tag == .list) "LIST" else "RIFF";
            try writeContainer(id, c, writer, depth);
        },
    }
}

/// Shared body of `writeChunk()`'s `.list`/`.riff` branches: writes `id`
/// ("LIST" or "RIFF"), the container's total size, its type FourCC, then
/// streams each child directly to `writer` - see `write()`'s doc comment
/// for why this needs no intermediate buffer.
fn writeContainer(id: *const [4]u8, c: Container, writer: *std.Io.Writer, depth: usize) WriteError!void {
    const size = try containerChildrenSize(c.chunks, depth + 1);

    // Every child is already padded to an even length and the type FourCC is
    // 4 bytes, so a container never needs a pad byte of its own. `size` is a
    // plain u32 and the type does not guarantee that, so check it before
    // writing anything rather than emit a container that would need padding.
    if (size % 2 != 0)
        return error.OddContainerSize;

    try writer.writeAll(id);
    try writer.writeInt(u32, size, .little);
    try writer.writeAll(&c.four_cc.inner);
    for (c.chunks) |child| try writeChunk(child, writer, depth + 1);
}

/// Computes `8 + payload_len` (chunk header) plus the trailing parity pad
/// byte, detecting overflow explicitly rather than relying on `usize` being
/// wider than `u32`: on a 32-bit target `usize` is `u32`, so there is no
/// wider type to widen into and the addition could still overflow-panic for
/// a `payload_len` near `maxInt(u32)`. Shared by every arm of
/// `serializedSize` since the formula is identical for each.
fn chunkTotalSize(payload_len: u32) error{PayloadTooLarge}!usize {
    const with_header = std.math.add(usize, 8, payload_len) catch return error.PayloadTooLarge;
    return std.math.add(usize, with_header, payload_len % 2) catch error.PayloadTooLarge;
}

/// Computes the total serialized size (header + data/children + parity pad)
/// that `write()` would produce for `chunk`, without allocating or writing
/// anything. Used to determine a `.list`/`.riff` container's `size` field
/// before its header is written, so `write()` can stream children directly
/// to the real writer instead of buffering them first.
///
/// `depth` is `chunk`'s own nesting level, bounded by `max_nesting_depth`
/// the same way the streaming parser bounds `read()` - this is mutually
/// recursive with `containerChildrenSize()`, so without a bound a deeply
/// nested `Chunk` tree could overflow the stack here just as it could in
/// `writeChunk()`.
fn serializedSize(chunk: Chunk, depth: usize) error{ PayloadTooLarge, NestingTooDeep, ReservedFourCC }!usize {
    return switch (chunk) {
        .chunk => |b| blk: {
            // Checked here as well as in writeChunk(), so a reserved id deep in
            // the tree is rejected before any of the tree is written.
            if (stream.isContainer(&b.four_cc.inner))
                return error.ReservedFourCC;
            const data_size = std.math.cast(u32, b.data.len) orelse return error.PayloadTooLarge;
            break :blk try chunkTotalSize(data_size);
        },
        .list, .riff => |c| blk: {
            if (depth > max_nesting_depth)
                return error.NestingTooDeep;
            break :blk try chunkTotalSize(try containerChildrenSize(c.chunks, depth + 1));
        },
    };
}

/// Sums `serializedSize` over `chunks` plus the 4-byte type FourCC that
/// precedes them inside a `.list`/`.riff` container, and checks the result
/// fits the u32 RIFF size field - this is exactly the value `write()` puts
/// in that container's own `size` field. `depth` is the nesting level of
/// `chunks` themselves (one deeper than their `.list`/`.riff` parent).
fn containerChildrenSize(chunks: []const Chunk, depth: usize) error{ PayloadTooLarge, NestingTooDeep, ReservedFourCC }!u32 {
    var total: usize = 4; // type FourCC
    for (chunks) |child| {
        const child_size = try serializedSize(child, depth);
        total = std.math.add(usize, total, child_size) catch return error.PayloadTooLarge;
    }
    return std.math.cast(u32, total) orelse error.PayloadTooLarge;
}

/// Parses a RIFF chunk tree from a reader.
///
/// This function pulls bytes from `reader` as it goes and constructs a `Chunk`
/// structure representing the parsed RIFF data. It is built on `stream.Iterator`
/// (see `stream.readTree`), so `reader` needs no particular buffer size: a file
/// reader with a small buffer works, and the whole input never has to be loaded
/// into memory first.
///
/// ## Supported Chunk Types
///
/// - **RIFF chunks**: Root container chunks with a file type identifier (e.g., "WAVE", "AVI").
///   The function expects at least 12 bytes: "RIFF" (4) + size (4) + type FourCC (4).
///
/// - **LIST chunks**: Container chunks that hold multiple sub-chunks.
///   The function expects at least 12 bytes: "LIST" (4) + size (4) + type FourCC (4).
///
/// - **Basic chunks**: Leaf chunks with a FourCC identifier and data payload.
///   The function expects at least 8 bytes: FourCC (4) + size (4), followed by data.
///
/// ## Memory Allocation
///
/// The function allocates memory for:
/// - Chunk data payloads (copied from the reader)
/// - Arrays of sub-chunks for LIST and RIFF containers
///
/// All allocated memory must be freed by calling `chunk.deinit(allocator)` when done.
/// `read()` does not know the input length, so it does not trust a chunk's
/// declared size: nothing is allocated for a chunk's payload before its bytes
/// have started to arrive, and a tiny input that merely *claims* a huge chunk
/// fails without a huge allocation. This is specific to `read()`. Calling
/// `stream.readTree()` with `Options.total_len` allocates each payload in one
/// piece, trusting that length, so a `total_len` larger than the real input can
/// make it allocate up to that many bytes before any of them arrive.
///
/// ## Data Format
///
/// The reader must provide the complete chunk data in little-endian format:
/// - FourCC identifiers are 4-byte ASCII sequences
/// - Size fields are 32-bit little-endian unsigned integers
/// - Data follows immediately after the size field
///
/// ## Input Length
///
/// `read()` cannot know how many bytes the input holds. A truncated input is
/// reported as `InvalidFormat` if it ends inside the top-level chunk's header
/// (8 bytes for a leaf chunk, 12 for a RIFF/LIST container, whose header
/// includes the type FourCC), and as `SizeMismatch` if it ends anywhere after
/// that, including inside a nested chunk header. The exception is a container
/// whose declared end leaves 2 to 7 bytes after its header or after one of its
/// children: that is too short for a chunk header, so `read()` reports
/// `InvalidFormat` without reading any further, whether or not those bytes are
/// actually present. If you know the input's length (a file's size, a fixed
/// buffer's length), call `stream.readTree()` with `Options.total_len`
/// instead: a declared size larger than the input is then rejected with
/// `SizeMismatch` before any payload is read (including in that exceptional
/// case), and each payload is allocated in one piece.
///
/// ## Padding
///
/// A chunk with an odd-sized payload is followed by one pad byte that its size
/// field does not count. `read()` skips that pad byte without looking at its
/// value, so a non-zero pad byte is accepted, and it also accepts the pad byte
/// being absent when the chunk is the last one in its container. The same
/// applies to the pad after a nested container declared with an odd size.
/// Pad bytes carry no data and are not preserved: `write()` always emits `0`.
///
/// One check is stricter: a single leftover byte at the very end of a
/// container's children (too short to be a chunk header) must be `0`, and two
/// or more leftover bytes, or a non-zero one, are `InvalidFormat`. This keeps
/// truncated or corrupted input from being read as valid.
///
/// ## Reader Position
///
/// On success the reader is left right after the top-level chunk's declared
/// size: `read()` consumes nothing after it, neither trailing bytes nor the
/// pad byte of an odd-sized top-level chunk (that pad byte is not part of the
/// declared size, and `write()` does emit it). To read several chunks back to
/// back from one stream, skip that one pad byte after a top-level chunk whose
/// payload length is odd before calling `read()` again.
///
/// Parameters:
///   - `allocator`: Memory allocator for creating the chunk structure and allocating data buffers.
///   - `reader`: The `std.Io.Reader` to read RIFF chunk binary data from.
///
/// Returns: A `Chunk` instance representing the parsed data. The caller owns the memory and must call `deinit()`.
///
/// Errors: see `ReadError`.
///   - `InvalidFormat`: If a chunk header is incomplete or malformed.
///   - `SizeMismatch`: If a chunk's declared size extends beyond the available data.
///   - `NestingTooDeep`: If `.list`/`.riff` nesting exceeds `max_nesting_depth`.
///   - `ReadFailed`: If the underlying reader fails.
///   - `OutOfMemory`: If allocating a chunk's data payload or a sub-chunk array fails.
pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReadError!Chunk {
    return stream.readTree(allocator, reader, .{});
}

test "Wave" {
    _ = Chunk{ .riff = .{
        .four_cc = try FourCC.new("WAVE"),
        .chunks = &[_]Chunk{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "" } },
        },
    } };
}

test "chunk serialization" {
    const allocator = std.testing.allocator;

    const chunk = Chunk{ .chunk = .{
        .four_cc = try FourCC.new("fmt "),
        .data = "EXAMPLE_DATA",
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(chunk, &w.writer);
    const chunk_data = w.written();

    const expected = "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA";
    try std.testing.expectEqualSlices(u8, expected, chunk_data);

    const chunk_file: []const u8 = @embedFile("assets/riff-files/chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, chunk_data);
}

test "write returns PayloadTooLarge instead of panicking for oversized chunk data" {
    // A slice longer than maxInt(u32) cannot exist where usize is 32 bits.
    if (@sizeOf(usize) <= 4) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Regression test: build a slice whose length exceeds u32 max without
    // actually allocating any memory for it. write() must reject this based
    // on `.len` alone, before ever writing (or dereferencing) `data`, so
    // constructing the slice from a dangling-but-unread pointer is safe here.
    const fake_len: usize = @as(usize, std.math.maxInt(u32)) + 1;
    const fake_data: []const u8 = @as([*]const u8, @ptrFromInt(1))[0..fake_len];
    const chunk = Chunk{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = fake_data } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try std.testing.expectError(error.PayloadTooLarge, write(chunk, &w.writer));
}

test "write returns PayloadTooLarge for children whose sizes fit individually but overflow in aggregate" {
    const allocator = std.testing.allocator;

    // Regression test: the previous test only exercises the leaf-level
    // std.math.cast(u32, data.len) check in serializedSize(). The separate
    // aggregate-sum check in containerChildrenSize() - two children each
    // individually within the u32 limit, but whose combined encoded size
    // exceeds it - was untested. As with the other regression test, build
    // slices whose length is huge without actually allocating: write() never
    // dereferences `.data` before the size checks run.
    const child_len: usize = std.math.maxInt(u32) - 100;
    const fake_data: []const u8 = @as([*]const u8, @ptrFromInt(1))[0..child_len];
    const child = Chunk{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = fake_data } };
    const list_chunk = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{ child, child },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try std.testing.expectError(error.PayloadTooLarge, write(list_chunk, &w.writer));
}

test "write returns NestingTooDeep instead of overflowing the stack for excessively nested chunks" {
    const allocator = std.testing.allocator;

    // Regression test: write()/serializedSize()/containerChildrenSize()
    // used to recurse once per nested .list/.riff level with no depth
    // limit, unlike read(). Nothing requires a Chunk tree
    // passed to write() to have come from read() (which is already
    // bounded), so a tree built some other way - e.g. programmatically, as
    // here - could overflow the stack. Build a chain nested one level
    // deeper than max_nesting_depth iteratively (so the *construction*
    // itself doesn't recurse) and confirm write() reports NestingTooDeep
    // instead of crashing.
    var children: []Chunk = try allocator.alloc(Chunk, 1);
    children[0] = .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "" } };

    var depth: usize = 0;
    while (depth <= max_nesting_depth) : (depth += 1) {
        const wrapped = try allocator.alloc(Chunk, 1);
        wrapped[0] = .{ .list = .{ .four_cc = try FourCC.new("TYPE"), .chunks = children } };
        children = wrapped;
    }

    const chunk = Chunk{ .list = .{ .four_cc = try FourCC.new("TEST"), .chunks = children } };
    defer chunk.deinit(allocator);

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try std.testing.expectError(error.NestingTooDeep, write(chunk, &w.writer));
}

/// Builds `containers` nested containers as raw bytes: an outermost "RIFF",
/// then "LIST"s, with an empty "data" leaf inside the innermost one.
fn buildNestedContainers(allocator: std.mem.Allocator, containers: usize) ![]u8 {
    var prev = try allocator.dupe(u8, "data" ++ "\x00\x00\x00\x00");
    errdefer allocator.free(prev);

    var i: usize = 0;
    while (i < containers) : (i += 1) {
        const wrapped = try allocator.alloc(u8, 12 + prev.len);
        @memcpy(wrapped[0..4], if (i == containers - 1) "RIFF" else "LIST");
        std.mem.writeInt(u32, wrapped[4..8], @intCast(4 + prev.len), .little);
        @memcpy(wrapped[8..12], "TEST");
        @memcpy(wrapped[12..], prev);
        allocator.free(prev);
        prev = wrapped;
    }
    return prev;
}

test "read() and write() accept the same nesting depth: a tree read() returns can always be written back" {
    const allocator = std.testing.allocator;

    // Regression test: read() only checked depth when opening a container,
    // while write() checked every node, leaves included. A leaf inside a
    // container at the deepest depth read() accepts was therefore rejected by
    // write() with NestingTooDeep, so write(read(x)) failed for input that
    // read() had accepted. Both must accept up to max_nesting_depth + 1
    // containers (the top-level one is at depth 0), and reject one more.
    inline for (.{ max_nesting_depth, max_nesting_depth + 1 }) |containers| {
        const bytes = try buildNestedContainers(allocator, containers);
        defer allocator.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        const parsed = try read(allocator, &reader);
        defer parsed.deinit(allocator);

        var w = std.Io.Writer.Allocating.init(allocator);
        defer w.deinit();
        try write(parsed, &w.writer);
        try std.testing.expectEqualSlices(u8, bytes, w.written());
    }

    const too_deep = try buildNestedContainers(allocator, max_nesting_depth + 2);
    defer allocator.free(too_deep);
    var reader = std.Io.Reader.fixed(too_deep);
    try std.testing.expectError(error.NestingTooDeep, read(allocator, &reader));
}

test "write rejects a leaf chunk named RIFF or LIST instead of emitting something read() cannot round-trip" {
    const allocator = std.testing.allocator;

    // Regression test: write() never looked at a leaf's four_cc, but read()
    // parses any "RIFF"/"LIST" chunk as a container. A 2-byte payload then
    // failed with InvalidFormat, and a payload of 4 or more bytes silently
    // came back as a different structure (a .list/.riff with the payload
    // reinterpreted as its type FourCC and children).
    inline for (.{ "RIFF", "LIST" }) |id| {
        inline for (.{ "ab", "TEST", "TESTdata\x02\x00\x00\x00hi" }) |payload| {
            const leaf = Chunk{ .chunk = .{ .four_cc = try FourCC.new(id), .data = payload } };

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try std.testing.expectError(error.ReservedFourCC, write(leaf, &w.writer));
            try std.testing.expectEqual(0, w.written().len);
        }
    }
}

test "write rejects a nested reserved leaf before writing anything" {
    const allocator = std.testing.allocator;

    // The valid sibling before the bad leaf must not be emitted either: the
    // size pre-pass rejects the whole tree before the header is written.
    const riff_chunk = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "AB" } },
            .{ .list = .{
                .four_cc = try FourCC.new("SUB1"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("LIST"), .data = "TEST" } },
                },
            } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try std.testing.expectError(error.ReservedFourCC, write(riff_chunk, &w.writer));
    try std.testing.expectEqual(0, w.written().len);
}

test "write only reserves the exact ids RIFF and LIST, which read() treats the same way" {
    const allocator = std.testing.allocator;

    // read() compares case-sensitively, so a leaf named "list" or "Riff" is an
    // ordinary leaf on both sides and must still round-trip.
    inline for (.{ "list", "Riff", "LIS ", "RIFX" }) |id| {
        const leaf = Chunk{ .chunk = .{ .four_cc = try FourCC.new(id), .data = "TESTdata" } };

        var w = std.Io.Writer.Allocating.init(allocator);
        defer w.deinit();
        try write(leaf, &w.writer);

        var reader = std.Io.Reader.fixed(w.written());
        const parsed = try read(allocator, &reader);
        defer parsed.deinit(allocator);
        try std.testing.expectEqualDeep(leaf, parsed);
    }
}

test "write needs no allocation for nested .list/.riff containers" {
    // write()'s .list/.riff branches used to build each nesting level's
    // serialized children in a temporary std.Io.Writer.Allocating buffer
    // before copying it into the parent, so every level needed an allocation.
    // write() now computes container sizes with a pure, allocation-free helper
    // and streams children directly to the real writer, and it takes no
    // allocator at all. Writing into a non-allocating fixed-buffer writer
    // shows the whole path works without any allocation.
    const nested = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .list = .{
                .four_cc = try FourCC.new("SUB1"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "hi" } },
                },
            } },
        },
    } };

    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(nested, &w);

    const expected = "RIFF" ++ "\x1a\x00\x00\x00" ++ "TEST" ++ "LIST" ++ "\x0e\x00\x00\x00" ++ "SUB1" ++ "data" ++ "\x02\x00\x00\x00" ++ "hi";
    try std.testing.expectEqualSlices(u8, expected, w.buffered());
}

test "list_chunk serialization" {
    const allocator = std.testing.allocator;

    const list_chunk = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "EXAMPLE_DATA" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "EXAMPLE_DATA" } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(list_chunk, &w.writer);
    const list_chunk_data: []u8 = w.written();

    const expected = "LIST" ++ "\x2c\x00\x00\x00" ++ "TEST" ++ "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA" ++ "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA";
    try std.testing.expectEqualSlices(u8, expected, list_chunk_data);

    const chunk_file: []const u8 = @embedFile("assets/riff-files/list_chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, list_chunk_data);
}

test "list_chunk with an odd-sized chunk followed by a sibling chunk round-trips" {
    const allocator = std.testing.allocator;

    // Regression test: "odd1" has an odd-length payload (1 byte), so write()
    // appends a pad byte after it. read() must skip that pad byte before
    // parsing the next sibling chunk header ("even"), instead of desyncing.
    const list_chunk = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("odd1"), .data = "A" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("even"), .data = "BB" } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(list_chunk, &w.writer);
    const list_chunk_data: []u8 = w.written();

    var reader = std.Io.Reader.fixed(list_chunk_data);
    const parsed: Chunk = try read(allocator, &reader);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualDeep(list_chunk, parsed);
}

test "a nested .riff chunk round-trips instead of losing its structure" {
    const allocator = std.testing.allocator;

    // Regression test: write() already serializes a nested `.riff` chunk
    // (nothing restricts `.riff` to the top level), but read() used
    // to only special-case "LIST", so a nested "RIFF" id fell through to the
    // generic leaf branch and came back as an opaque `.chunk` with undecoded
    // bytes instead of its original `.riff` structure.
    const list_chunk = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .riff = .{
                .four_cc = try FourCC.new("SUB1"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "hi" } },
                },
            } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(list_chunk, &w.writer);
    const list_chunk_data: []u8 = w.written();

    var reader = std.Io.Reader.fixed(list_chunk_data);
    const parsed: Chunk = try read(allocator, &reader);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualDeep(list_chunk, parsed);
}

test "a .riff chunk nested inside another .riff chunk round-trips" {
    const allocator = std.testing.allocator;

    // Regression test: the nested .riff round-trip test above only covers
    // .riff nested inside .list. #38/#46's fix is not specific to .list as
    // the outer container, so cover the more literal "nested RIFF" case
    // too: .riff directly inside .riff.
    const riff_chunk = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .riff = .{
                .four_cc = try FourCC.new("SUB1"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "hi" } },
                },
            } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(riff_chunk, &w.writer);
    const riff_chunk_data: []u8 = w.written();

    var reader = std.Io.Reader.fixed(riff_chunk_data);
    const parsed: Chunk = try read(allocator, &reader);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualDeep(riff_chunk, parsed);
}

test "riff_chunk serialization" {
    const allocator = std.testing.allocator;

    const riff_chunk = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "" } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(riff_chunk, &w.writer);
    const riff_chunk_data: []u8 = w.written();

    const expected = "RIFF" ++ "\x14\x00\x00\x00" ++ "TEST" ++ "fmt " ++ "\x00\x00\x00\x00" ++ "" ++ "data" ++ "\x00\x00\x00\x00" ++ "";
    try std.testing.expectEqualSlices(u8, expected, riff_chunk_data);

    const chunk_file: []const u8 = @embedFile("assets/riff-files/riff_chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, riff_chunk_data);
}

test "riff_chunk trailing bytes after the declared size are not absorbed as sub-chunks" {
    const allocator = std.testing.allocator;

    // Regression test: a well-formed, complete top-level RIFF chunk followed by
    // extra trailing bytes (e.g. concatenated files, trailer metadata) must not
    // have those trailing bytes parsed as additional sub-chunks; read() must
    // bound its parsing to the RIFF chunk's own declared `size`.
    const riff_chunk = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "AB" } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(riff_chunk, &w.writer);
    const riff_chunk_data = w.written();

    const trailing = "JUNK" ++ "\x02\x00\x00\x00";
    const buffer = try allocator.alloc(u8, riff_chunk_data.len + trailing.len);
    defer allocator.free(buffer);
    @memcpy(buffer[0..riff_chunk_data.len], riff_chunk_data);
    @memcpy(buffer[riff_chunk_data.len..], trailing);

    var reader = std.Io.Reader.fixed(buffer);
    const parsed: Chunk = try read(allocator, &reader);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualDeep(riff_chunk, parsed);
}

test "read returns InvalidFormat for a buffer shorter than a chunk header" {
    const allocator = std.testing.allocator;

    const buffer = "abc"; // 3 bytes, less than the 8-byte header (FourCC + size)
    var reader = std.Io.Reader.fixed(buffer);
    try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
}

test "read returns InvalidFormat for a RIFF/LIST header without room for the type FourCC" {
    const allocator = std.testing.allocator;

    inline for (.{ "RIFF", "LIST" }) |id| {
        // 8 bytes: id + size, but no room left for the 4-byte type FourCC.
        const buffer = id ++ "\x04\x00\x00\x00";
        var reader = std.Io.Reader.fixed(buffer);
        try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
    }
}

test "read returns SizeMismatch when the declared size exceeds the remaining buffer" {
    const allocator = std.testing.allocator;

    // "data" chunk declares 10 bytes of payload, but only 2 bytes follow.
    const buffer = "data" ++ "\x0a\x00\x00\x00" ++ "AB";
    var reader = std.Io.Reader.fixed(buffer);
    try std.testing.expectError(error.SizeMismatch, read(allocator, &reader));
}

test "a truncated input is InvalidFormat inside the top-level header and SizeMismatch after it" {
    const allocator = std.testing.allocator;

    // Pins the behaviour documented in read()'s "Input Length" section, with
    // and without Options.total_len: a cut inside the top-level header (8
    // bytes for a leaf, 12 for a container) is InvalidFormat, and every later
    // cut - including one inside a nested chunk header - is SizeMismatch.
    const samples = [_]struct { bytes: []const u8, header_len: usize }{
        .{ .bytes = @embedFile("assets/riff-files/chunk.riff"), .header_len = 8 },
        .{ .bytes = @embedFile("assets/riff-files/riff_chunk.riff"), .header_len = 12 },
        .{ .bytes = @embedFile("assets/riff-files/riff_chunk_has_list.riff"), .header_len = 12 },
    };
    for (samples) |sample| {
        for (0..sample.bytes.len) |len| {
            const expected: anyerror = if (len < sample.header_len) error.InvalidFormat else error.SizeMismatch;

            var reader = std.Io.Reader.fixed(sample.bytes[0..len]);
            try std.testing.expectError(expected, read(allocator, &reader));

            var sized = std.Io.Reader.fixed(sample.bytes[0..len]);
            try std.testing.expectError(expected, stream.readTree(allocator, &sized, .{ .total_len = len }));
        }
    }
}

test "a container whose declared end leaves 2 to 7 bytes is InvalidFormat without total_len, SizeMismatch with it" {
    const allocator = std.testing.allocator;

    // Pins the exception documented in read()'s "Input Length" section: a
    // remainder of 2 to 7 bytes is too short for a chunk header, so it is
    // reported as InvalidFormat before anything is read, present or not.
    // With Options.total_len the declared size is checked against the real
    // input first, so a truncated input reports SizeMismatch instead.
    const child = "even" ++ "\x02\x00\x00\x00" ++ "BB";

    // Declared size 7 = type FourCC (4) + 3 bytes, none of which are present.
    const after_header = "RIFF" ++ "\x07\x00\x00\x00" ++ "TEST";
    // Declared size 17 = type FourCC (4) + a 10-byte child + 3 bytes, none present.
    const after_child = "RIFF" ++ "\x11\x00\x00\x00" ++ "TEST" ++ child;

    inline for (.{ after_header, after_child }) |input| {
        var reader = std.Io.Reader.fixed(input);
        try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));

        var sized = std.Io.Reader.fixed(input);
        try std.testing.expectError(error.SizeMismatch, stream.readTree(allocator, &sized, .{ .total_len = input.len }));
    }

    // With the 3 bytes present the input is complete but malformed: the same
    // InvalidFormat either way.
    inline for (.{ after_header ++ "abc", after_child ++ "abc" }) |input| {
        var reader = std.Io.Reader.fixed(input);
        try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));

        var sized = std.Io.Reader.fixed(input);
        try std.testing.expectError(error.InvalidFormat, stream.readTree(allocator, &sized, .{ .total_len = input.len }));
    }
}

test "read returns SizeMismatch instead of panicking for a near-max declared size" {
    const allocator = std.testing.allocator;

    // Regression test: `header_len + size` has no usize operand of its own, so
    // it used to stay u32-typed and overflow-panic once `size` got within 7 of
    // `maxInt(u32)`, instead of read() reporting SizeMismatch like it does for
    // any other too-large declared size.
    const buffer = "data" ++ "\xff\xff\xff\xff" ++ "AB";
    var reader = std.Io.Reader.fixed(buffer);
    try std.testing.expectError(error.SizeMismatch, read(allocator, &reader));
}

test "read returns SizeMismatch instead of panicking for a near-max RIFF/LIST declared size" {
    const allocator = std.testing.allocator;

    inline for (.{ "RIFF", "LIST" }) |id| {
        const buffer = id ++ "\xff\xff\xff\xff" ++ "TEST";
        var reader = std.Io.Reader.fixed(buffer);
        try std.testing.expectError(error.SizeMismatch, read(allocator, &reader));
    }
}

test "read returns InvalidFormat for a nested RIFF/LIST without room for its type FourCC" {
    const allocator = std.testing.allocator;

    inline for (.{ "LIST", "RIFF" }) |nested_id| {
        // Nested container declares a 2-byte payload, leaving no room for
        // its own 4-byte type FourCC. Since #46, a nested "RIFF" hits the
        // identical check as "LIST".
        const nested = nested_id ++ "\x02\x00\x00\x00" ++ "XY";
        const buffer = "RIFF" ++ "\x0e\x00\x00\x00" ++ "TEST" ++ nested;

        var reader = std.Io.Reader.fixed(buffer);
        try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
    }
}

test "read returns NestingTooDeep instead of overflowing the stack for excessively nested RIFF/LIST chunks" {
    const allocator = std.testing.allocator;

    // Regression test: read() used to recurse once per nested
    // LIST/RIFF chunk with no depth limit, so adversarial input with many
    // trivially nested containers (12 bytes of overhead each) could
    // overflow the call stack before any error was returned. Build a chain
    // nested one level deeper than max_nesting_depth and confirm read()
    // reports NestingTooDeep instead of crashing - for a chain nested (and
    // entered at the top level) via "LIST" and, separately, via "RIFF",
    // since #46 made read() treat nested "RIFF" identically to
    // "LIST".
    inline for (.{ "LIST", "RIFF" }) |id| {
        // Innermost leaf: a plain chunk with no payload.
        var prev = try allocator.dupe(u8, "DATA" ++ "\x00\x00\x00\x00");
        defer allocator.free(prev);

        var depth: usize = 0;
        while (depth <= max_nesting_depth) : (depth += 1) {
            const size: u32 = @intCast(4 + prev.len); // type FourCC (4) + children (prev)
            const wrapped = try allocator.alloc(u8, 12 + prev.len);
            @memcpy(wrapped[0..4], id);
            std.mem.writeInt(u32, wrapped[4..8], size, .little);
            @memcpy(wrapped[8..12], "TYPE");
            @memcpy(wrapped[12..], prev);
            allocator.free(prev);
            prev = wrapped;
        }

        const outer_size: u32 = @intCast(4 + prev.len);
        const buffer = try allocator.alloc(u8, 12 + prev.len);
        defer allocator.free(buffer);
        @memcpy(buffer[0..4], id);
        std.mem.writeInt(u32, buffer[4..8], outer_size, .little);
        @memcpy(buffer[8..12], "TEST");
        @memcpy(buffer[12..], prev);

        var reader = std.Io.Reader.fixed(buffer);
        try std.testing.expectError(error.NestingTooDeep, read(allocator, &reader));
    }
}

test "read does not leak a chunk's data if appending it to the list fails" {
    // Regression test: if allocator.dupe() for a leaf chunk's data succeeded
    // but the subsequent list.append() then failed (e.g. array growth OOM),
    // the duplicated data was never freed - it wasn't yet part of list.items,
    // so the parser's own errdefer (which frees already-appended chunks)
    // never reached it. Sweep a few failure points instead of hardcoding the
    // exact internal allocation count, and rely on std.testing.allocator's
    // own leak detector to fail this test if anything goes unfreed.
    const buffer = "LIST" ++ "\x0e\x00\x00\x00" ++ "TEST" ++ "data" ++ "\x02\x00\x00\x00" ++ "AB";

    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var reader = std.Io.Reader.fixed(buffer);
        if (read(allocator, &reader)) |chunk| {
            chunk.deinit(allocator);
        } else |_| {}
    }
}

test "read ignores the value of the pad byte after an odd-sized chunk, and write emits zero" {
    const allocator = std.testing.allocator;

    // Pins the documented padding policy (see read()'s "Padding" section): the
    // pad byte after an odd-sized leaf is skipped without checking its value,
    // and may be absent when the leaf is the last chunk of its container. Only
    // a lone leftover byte at the end of a container must be zero (covered by
    // the test below).
    const odd = "odd1" ++ "\x01\x00\x00\x00" ++ "A";
    const even = "even" ++ "\x02\x00\x00\x00" ++ "BB";
    const expect_odd = Chunk{ .chunk = .{ .four_cc = try FourCC.new("odd1"), .data = "A" } };
    const expect_even = Chunk{ .chunk = .{ .four_cc = try FourCC.new("even"), .data = "BB" } };

    inline for (.{ "RIFF", "LIST" }) |id| {
        {
            // Non-zero pad byte followed by a sibling: accepted, and the
            // sibling is not desynced by it. Re-written with a zero pad.
            const buffer = id ++ "\x18\x00\x00\x00" ++ "TEST" ++ odd ++ "\xff" ++ even;
            var reader = std.Io.Reader.fixed(buffer);
            const parsed = try read(allocator, &reader);
            defer parsed.deinit(allocator);
            switch (parsed) {
                .chunk => return error.TestUnexpectedResult,
                inline .list, .riff => |c| try std.testing.expectEqualDeep(&[_]Chunk{ expect_odd, expect_even }, c.chunks),
            }

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try write(parsed, &w.writer);
            try std.testing.expectEqualSlices(u8, id ++ "\x18\x00\x00\x00" ++ "TEST" ++ odd ++ "\x00" ++ even, w.written());
        }
        {
            // Non-zero pad byte after the last chunk of the container.
            const buffer = id ++ "\x0e\x00\x00\x00" ++ "TEST" ++ odd ++ "\xff";
            var reader = std.Io.Reader.fixed(buffer);
            const parsed = try read(allocator, &reader);
            defer parsed.deinit(allocator);
            switch (parsed) {
                .chunk => return error.TestUnexpectedResult,
                inline .list, .riff => |c| try std.testing.expectEqualDeep(&[_]Chunk{expect_odd}, c.chunks),
            }
        }
        {
            // Pad byte absent after the last chunk of the container.
            const buffer = id ++ "\x0d\x00\x00\x00" ++ "TEST" ++ odd;
            var reader = std.Io.Reader.fixed(buffer);
            const parsed = try read(allocator, &reader);
            defer parsed.deinit(allocator);
            switch (parsed) {
                .chunk => return error.TestUnexpectedResult,
                inline .list, .riff => |c| try std.testing.expectEqualDeep(&[_]Chunk{expect_odd}, c.chunks),
            }
        }
    }
}

test "read skips the pad byte after a nested container declared with an odd size" {
    const allocator = std.testing.allocator;

    // Pins the "Padding" section of read()'s doc for a nested container. The
    // nested LIST's declared size is odd (type FourCC 4 + an odd-sized leaf 9
    // = 13), so a pad byte follows it. It is skipped without checking its
    // value, may be absent when the container is the last child, and the
    // sibling after it is not desynced.
    const nested = "LIST" ++ "\x0d\x00\x00\x00" ++ "SUB1" ++ "odd1" ++ "\x01\x00\x00\x00" ++ "A";
    const even = "even" ++ "\x02\x00\x00\x00" ++ "BB";
    const expect_nested = Chunk{ .list = .{
        .four_cc = try FourCC.new("SUB1"),
        .chunks = &.{.{ .chunk = .{ .four_cc = try FourCC.new("odd1"), .data = "A" } }},
    } };
    const expect_even = Chunk{ .chunk = .{ .four_cc = try FourCC.new("even"), .data = "BB" } };

    inline for (.{ "RIFF", "LIST" }) |id| {
        inline for (.{ "\x00", "\xff" }) |pad| {
            // Pad byte (zero or not) between the nested container and a sibling.
            const buffer = id ++ "\x24\x00\x00\x00" ++ "TEST" ++ nested ++ pad ++ even;
            var reader = std.Io.Reader.fixed(buffer);
            const parsed = try read(allocator, &reader);
            defer parsed.deinit(allocator);
            switch (parsed) {
                .chunk => return error.TestUnexpectedResult,
                inline .list, .riff => |c| try std.testing.expectEqualDeep(&[_]Chunk{ expect_nested, expect_even }, c.chunks),
            }
        }
        {
            // Pad byte absent after the last child.
            const buffer = id ++ "\x19\x00\x00\x00" ++ "TEST" ++ nested;
            var reader = std.Io.Reader.fixed(buffer);
            const parsed = try read(allocator, &reader);
            defer parsed.deinit(allocator);
            switch (parsed) {
                .chunk => return error.TestUnexpectedResult,
                inline .list, .riff => |c| try std.testing.expectEqualDeep(&[_]Chunk{expect_nested}, c.chunks),
            }
        }
    }
}

test "read leaves the reader right after the declared size, before the pad byte and trailing bytes" {
    const allocator = std.testing.allocator;

    // Pins read()'s "Reader Position" section. An odd-sized top-level leaf is
    // followed by its pad byte, which its size field does not count, and then
    // by more bytes: read() must consume exactly header + declared size, so
    // the pad byte is still the next byte, and the caller skips it to read the
    // next chunk from the same stream.
    const first = "abcd" ++ "\x03\x00\x00\x00" ++ "xyz"; // 11 bytes, odd payload
    const second = "efgh" ++ "\x02\x00\x00\x00" ++ "BB";
    const input = first ++ "\x00" ++ second;

    // A fixed reader, so the position can be read off directly.
    {
        var reader = std.Io.Reader.fixed(input);
        const chunk = try read(allocator, &reader);
        defer chunk.deinit(allocator);
        try std.testing.expectEqual(first.len, reader.seek);
        try std.testing.expectEqualSlices(u8, "\x00" ++ second, reader.buffered());
    }

    // A reader with a tiny buffer: the logical position is the same, and
    // skipping the one pad byte lets the next read() succeed.
    {
        var src = std.Io.Reader.fixed(input);
        var tiny: [4]u8 = undefined;
        var limited = src.limited(.unlimited, &tiny);
        const reader = &limited.interface;

        const one = try read(allocator, reader);
        defer one.deinit(allocator);
        try std.testing.expectEqualStrings("xyz", one.chunk.data);

        try std.testing.expectEqual(@as(u8, 0), try reader.takeByte());

        const two = try read(allocator, reader);
        defer two.deinit(allocator);
        try std.testing.expectEqualStrings("BB", two.chunk.data);
    }

    // A top-level container: nothing after its declared size is consumed.
    {
        const riff_bytes = "RIFF" ++ "\x0e\x00\x00\x00" ++ "TEST" ++ "even" ++ "\x02\x00\x00\x00" ++ "BB";
        var reader = std.Io.Reader.fixed(riff_bytes ++ "TRAILING");
        const chunk = try read(allocator, &reader);
        defer chunk.deinit(allocator);
        try std.testing.expectEqual(riff_bytes.len, reader.seek);
        try std.testing.expectEqualSlices(u8, "TRAILING", reader.buffered());
    }
}

test "read accepts exactly one trailing zero pad byte inside a container but rejects more" {
    const allocator = std.testing.allocator;

    // Regression test: read() used to tolerate up to 7 trailing zero
    // bytes after the last chunk in a container as "padding", with no basis
    // in the RIFF spec (only a single pad byte, to keep the overall size
    // even, is ever standard). That could mask truncated/corrupted data as
    // valid. A single trailing zero byte must still be accepted; anything
    // beyond that must be rejected as InvalidFormat. Checked for both a
    // "RIFF"- and a "LIST"-wrapped container, since both share the same
    // check.
    const child = "data" ++ "\x02\x00\x00\x00" ++ "AB"; // even-sized, no pad needed

    inline for (.{ "RIFF", "LIST" }) |id| {
        {
            // Exactly one trailing zero byte: accepted.
            const children = child ++ "\x00";
            const buffer = id ++ "\x0f\x00\x00\x00" ++ "TEST" ++ children;
            var reader = std.Io.Reader.fixed(buffer);
            const parsed = try read(allocator, &reader);
            defer parsed.deinit(allocator);
        }
        {
            // Two trailing zero bytes: rejected.
            const children = child ++ "\x00\x00";
            const buffer = id ++ "\x10\x00\x00\x00" ++ "TEST" ++ children;
            var reader = std.Io.Reader.fixed(buffer);
            try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
        }
        {
            // One trailing non-zero byte: rejected.
            const children = child ++ "\x01";
            const buffer = id ++ "\x0f\x00\x00\x00" ++ "TEST" ++ children;
            var reader = std.Io.Reader.fixed(buffer);
            try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
        }
    }
}

test "FluidR3_GM2-2.sf2 serialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const sdta = struct {
            const smpl = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.sdta.smpl.data.bin");
            };
        };
        const pdta = struct {
            const phdr = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.phdr.data.bin");
            };
            const pbag = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.pbag.data.bin");
            };
            const pgen = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.pgen.data.bin");
            };
            const inst = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.inst.data.bin");
            };
            const ibag = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.ibag.data.bin");
            };
            const imod = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.imod.data.bin");
            };
            const igen = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.igen.data.bin");
            };
            const shdr = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.shdr.data.bin");
            };
        };
    };

    const soundfont = Chunk{ .riff = .{
        .four_cc = try FourCC.new("sfbk"),
        .chunks = &.{
            .{ .list = .{
                .four_cc = try FourCC.new("INFO"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("ifil"), .data = &.{ 2, 0, 2, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("INAM"), .data = "Fluid R3 GM" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("isng"), .data = "E-mu 10K1" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("IPRD"), .data = "SBAWE32" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ISFT"), .data = "SFEDT v1.28:SFEDT v1.36:" ++ .{ 0, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICOP"), .data = "Frank Wen 2000-2002" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICRD"), .data = "20th June 2013" ++ .{ 0, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("IENG"), .data = "Frank Wen" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICMT"), .data = "DO NOT REDISTRIBUTE ANY OF THESE SAMPLES. Violin fixed by Church Organist " ++ .{ 0, 0 } } },
                },
            } },
            .{ .list = .{
                .four_cc = try FourCC.new("sdta"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("smpl"), .data = assertion_data.sdta.smpl.data } },
                },
            } },
            .{ .list = .{
                .four_cc = try FourCC.new("pdta"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("phdr"), .data = assertion_data.pdta.phdr.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pbag"), .data = assertion_data.pdta.pbag.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pmod"), .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pgen"), .data = assertion_data.pdta.pgen.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("inst"), .data = assertion_data.pdta.inst.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ibag"), .data = assertion_data.pdta.ibag.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("imod"), .data = assertion_data.pdta.imod.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("igen"), .data = assertion_data.pdta.igen.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("shdr"), .data = assertion_data.pdta.shdr.data } },
                },
            } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(soundfont, &w.writer);
    const webp_data: []u8 = w.written();

    const webp_file: []const u8 = @embedFile("assets/riff-files/FluidR3_GM2-2.sf2");
    try std.testing.expectEqualSlices(u8, webp_file, webp_data);
}

test "Webp serialization" {
    const allocator = std.testing.allocator;
    const assertion_data = @import("./assertion_data.zig");

    const webp = Chunk{ .riff = .{
        .four_cc = try FourCC.new("WEBP"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("VP8X"), .data = assertion_data.VP8X.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("VP8 "), .data = assertion_data.VP8.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("EXIF"), .data = assertion_data.EXIF.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("XMP "), .data = assertion_data.XMP.data } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(webp, &w.writer);
    const webp_data: []u8 = w.written();

    const webp_file: []const u8 = @embedFile("assets/riff-files/test_DJ.webp");
    try std.testing.expectEqualSlices(u8, webp_file, webp_data);
}

test "chunk deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const fmt = struct {
            const data = @embedFile("./assets/chunk-data/chunk.fmt.data");
        };
    };

    const chunk_filedata: []const u8 = @embedFile("assets/riff-files/chunk.riff");
    var reader = std.Io.Reader.fixed(chunk_filedata);
    const chunk: Chunk = try read(allocator, &reader);
    defer chunk.deinit(allocator);

    const expected = Chunk{ .chunk = .{
        .four_cc = try FourCC.new("fmt "),
        .data = assertion_data.fmt.data,
    } };

    try std.testing.expectEqualDeep(expected, chunk);
}

test "list_chunk deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const fmt1 = struct {
            const data = @embedFile("./assets/chunk-data/list.fmt1.data");
        };
        const fmt2 = struct {
            const data = @embedFile("./assets/chunk-data/list.fmt2.data");
        };
    };

    const list_chunk_filedata: []const u8 = @embedFile("assets/riff-files/list_chunk.riff");
    var reader = std.Io.Reader.fixed(list_chunk_filedata);
    const list_chunk: Chunk = try read(allocator, &reader);
    defer list_chunk.deinit(allocator);

    const expected = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt1.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt2.data } },
        },
    } };

    try std.testing.expectEqualDeep(expected, list_chunk);
}

test "riff_chunk deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const fmt = struct {
            const data = @embedFile("./assets/chunk-data/riff_chunk.fmt.data");
        };
        const data = struct {
            const data = @embedFile("./assets/chunk-data/riff_chunk.data.data");
        };
    };

    const riff_chunk_filedata: []const u8 = @embedFile("assets/riff-files/riff_chunk.riff");
    var reader = std.Io.Reader.fixed(riff_chunk_filedata);
    const riff_chunk: Chunk = try read(allocator, &reader);
    defer riff_chunk.deinit(allocator);

    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = assertion_data.data.data } },
        },
    } };

    try std.testing.expectEqualDeep(expected, riff_chunk);
}

test "riff_chunk_has_list deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const fmt1 = struct {
            const data = @embedFile("./assets/chunk-data/riff_chunk_has_list.fmt1.data");
        };
        const fmt2 = struct {
            const data = @embedFile("./assets/chunk-data/riff_chunk_has_list.fmt2.data");
        };
    };

    const chunk_filedata: []const u8 = @embedFile("assets/riff-files/riff_chunk_has_list.riff");
    var reader = std.Io.Reader.fixed(chunk_filedata);
    const chunk: Chunk = try read(allocator, &reader);
    defer chunk.deinit(allocator);

    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .list = .{
                .four_cc = try FourCC.new("TEST"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt1.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt2.data } },
                },
            } },
        },
    } };

    try std.testing.expectEqualDeep(expected, chunk);
}

test "FluidR3_GM2-2.sf2 deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const sdta = struct {
            const smpl = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.sdta.smpl.data.bin");
            };
        };
        const pdta = struct {
            const phdr = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.phdr.data.bin");
            };
            const pbag = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.pbag.data.bin");
            };
            const pgen = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.pgen.data.bin");
            };
            const inst = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.inst.data.bin");
            };
            const ibag = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.ibag.data.bin");
            };
            const imod = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.imod.data.bin");
            };
            const igen = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.igen.data.bin");
            };
            const shdr = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.shdr.data.bin");
            };
        };
    };

    const chunk_filedata: []const u8 = @embedFile("assets/riff-files/FluidR3_GM2-2.sf2");
    var reader = std.Io.Reader.fixed(chunk_filedata);
    const chunk: Chunk = try read(allocator, &reader);
    defer chunk.deinit(allocator);

    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("sfbk"),
        .chunks = &.{
            .{ .list = .{
                .four_cc = try FourCC.new("INFO"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("ifil"), .data = &.{ 2, 0, 2, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("INAM"), .data = "Fluid R3 GM" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("isng"), .data = "E-mu 10K1" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("IPRD"), .data = "SBAWE32" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ISFT"), .data = "SFEDT v1.28:SFEDT v1.36:" ++ .{ 0, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICOP"), .data = "Frank Wen 2000-2002" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICRD"), .data = "20th June 2013" ++ .{ 0, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("IENG"), .data = "Frank Wen" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICMT"), .data = "DO NOT REDISTRIBUTE ANY OF THESE SAMPLES. Violin fixed by Church Organist " ++ .{ 0, 0 } } },
                },
            } },
            .{ .list = .{
                .four_cc = try FourCC.new("sdta"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("smpl"), .data = assertion_data.sdta.smpl.data } },
                },
            } },
            .{ .list = .{
                .four_cc = try FourCC.new("pdta"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("phdr"), .data = assertion_data.pdta.phdr.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pbag"), .data = assertion_data.pdta.pbag.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pmod"), .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pgen"), .data = assertion_data.pdta.pgen.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("inst"), .data = assertion_data.pdta.inst.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ibag"), .data = assertion_data.pdta.ibag.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("imod"), .data = assertion_data.pdta.imod.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("igen"), .data = assertion_data.pdta.igen.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("shdr"), .data = assertion_data.pdta.shdr.data } },
                },
            } },
        },
    } };

    try std.testing.expectEqualDeep(expected, chunk);
}

test "Webp deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = @import("./assertion_data.zig");

    const filedata: []const u8 = @embedFile("assets/riff-files/test_DJ.webp");
    var reader = std.Io.Reader.fixed(filedata);
    const riff_chunk: Chunk = try read(allocator, &reader);
    defer riff_chunk.deinit(allocator);

    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("WEBP"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("VP8X"), .data = assertion_data.VP8X.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("VP8 "), .data = assertion_data.VP8.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("EXIF"), .data = assertion_data.EXIF.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("XMP "), .data = assertion_data.XMP.data } },
        },
    } };

    try std.testing.expectEqualDeep(expected, riff_chunk);
}
