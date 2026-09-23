//! A pull-style streaming RIFF parser (`Iterator`) and the tree builder
//! (`readTree`) layered on top of it, which `riff.read()` is implemented with.
//!
//! `Iterator` turns a byte stream into a sequence of `Event`s, one chunk
//! header at a time. It needs no allocation and works with any
//! `std.Io.Reader`, regardless of its buffer size: a leaf chunk's payload is
//! only read when the caller asks for it (`data`, `readDataAlloc`,
//! `dataReader`), and is otherwise skipped with `discard`.

const std = @import("std");
const riff = @import("root.zig");

const FourCC = riff.FourCC;
const Chunk = riff.Chunk;
const max_nesting_depth = riff.max_nesting_depth;

pub const Error = riff.ToChunkListError || FourCC.NewError || error{
    /// The underlying reader failed (I/O error).
    ReadFailed,
};

/// Errors of `Iterator.data()`, which borrows from the reader's buffer.
pub const DataError = Error || error{
    /// `data()` was called on a chunk larger than the reader's buffer.
    BufferTooSmall,
};

/// Growth increment `Iterator.readDataAlloc()` uses when a payload is not
/// already fully buffered.
pub const alloc_step = 64 * 1024;

pub const Kind = enum { riff, list };

pub const Event = union(enum) {
    /// A RIFF/LIST header was read. Its children follow as further events.
    begin_container: struct { kind: Kind, four_cc: FourCC, size: u32 },
    /// A leaf chunk header was read. Its payload has NOT been read yet: use
    /// `data()`, `readDataAlloc()` or `dataReader()`, or ignore it and the
    /// next `next()` call skips it.
    chunk: struct { four_cc: FourCC, size: u32 },
    /// The most recently opened container ended.
    end_container: Kind,
};

pub const Options = struct {
    /// Number of bytes the input holds from the reader's current position,
    /// if known (e.g. a file's size, or a fixed buffer's length).
    ///
    /// When set, the top-level chunk's declared size is checked against it
    /// before anything is read or allocated, so every nested size is
    /// bounded by real input and `readDataAlloc()` can allocate each payload
    /// in one piece. If the input turns out shorter than `total_len`, reads
    /// still fail with `SizeMismatch`; only the allocation sizes trust it.
    ///
    /// When null (pipes, sockets), declared sizes cannot be checked up front,
    /// so `readDataAlloc()` grows its allocation as bytes arrive instead.
    total_len: ?u64 = null,
};

pub const Iterator = struct {
    reader: *std.Io.Reader,
    /// See `Options.total_len`.
    total_len: ?u64 = null,
    /// Bytes consumed from `reader` since `init`.
    pos: u64 = 0,
    /// Unread payload bytes of the current `.chunk`.
    pending: u64 = 0,
    /// Pad byte to skip after the current chunk's payload.
    pending_pad: u1 = 0,
    /// Active sub-reader handed out by `dataReader()`, if any.
    limited: ?std.Io.Reader.Limited = null,
    /// Per open container: absolute end position, trailing pad, kind.
    ends: [max_nesting_depth + 1]u64 = undefined,
    pads: [max_nesting_depth + 1]u1 = undefined,
    kinds: [max_nesting_depth + 1]Kind = undefined,
    depth: usize = 0,
    state: enum { start, running, done } = .start,

    pub fn init(reader: *std.Io.Reader, options: Options) Iterator {
        return .{ .reader = reader, .total_len = options.total_len };
    }

    /// Returns the next event, or null once the top-level chunk is complete.
    pub fn next(it: *Iterator) Error!?Event {
        try it.finishCurrent();

        switch (it.state) {
            .done => return null,
            .start => {
                it.state = .running;
                return try it.readTop();
            },
            .running => {},
        }

        if (it.depth == 0) {
            it.state = .done;
            return null;
        }

        const end = it.ends[it.depth - 1];
        var left = end - it.pos;

        // A single trailing zero byte is padding,
        // anything else too short for a header is malformed.
        if (left > 0 and left < 8) {
            if (left != 1) return error.InvalidFormat;
            var b: [1]u8 = undefined;
            try it.readExact(&b);
            if (b[0] != 0) return error.InvalidFormat;
            left = 0;
        }

        if (left == 0) {
            it.depth -= 1;
            if (it.pads[it.depth] == 1) try it.skip(1);
            if (it.depth == 0) it.state = .done;
            return .{ .end_container = it.kinds[it.depth] };
        }

        var hdr: [8]u8 = undefined;
        try it.readExact(&hdr);
        const id = hdr[0..4];
        const size = std.mem.readInt(u32, hdr[4..8], .little);

        const child_end = it.pos + size;
        if (child_end > end) return error.SizeMismatch;
        // Pad byte only if the container actually has room for it (matches
        // the reference parser, which tolerates a missing final pad).
        const pad: u1 = if (size % 2 == 1 and child_end < end) 1 else 0;

        if (isContainer(id)) {
            if (size < 4) return error.InvalidFormat;
            if (it.depth > max_nesting_depth) return error.NestingTooDeep;
            var t: [4]u8 = undefined;
            try it.readExact(&t);
            it.push(kindOf(id), child_end, pad);
            return .{ .begin_container = .{ .kind = kindOf(id), .four_cc = try FourCC.new(&t), .size = size } };
        }

        it.pending = size;
        it.pending_pad = pad;
        return .{ .chunk = .{ .four_cc = try FourCC.new(id), .size = size } };
    }

    /// Borrows the whole payload of the current chunk from the reader's
    /// buffer. Valid until the next call on this iterator.
    pub fn data(it: *Iterator) DataError![]const u8 {
        std.debug.assert(it.limited == null);
        const n: usize = @intCast(it.pending);
        if (n > it.reader.buffer.len) return error.BufferTooSmall;
        const s = it.reader.take(n) catch |e| return mapPayload(e);
        it.pos += n;
        it.pending = 0;
        return s;
    }

    /// Reads the whole payload of the current chunk into a new allocation.
    ///
    /// Without `Options.total_len` the declared size is not trusted: a few
    /// bytes of input can claim a ~4 GiB chunk. The allocation is then only
    /// sized up front when the whole payload is already buffered; otherwise
    /// it grows in `alloc_step` increments as bytes actually arrive, so
    /// truncated input fails with `SizeMismatch` after allocating no more
    /// than it really contained. With `total_len`, the size was already
    /// checked against it, so the payload is allocated in one piece.
    pub fn readDataAlloc(it: *Iterator, allocator: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]u8 {
        std.debug.assert(it.limited == null);
        const n: usize = @intCast(it.pending);

        if (it.total_len != null or it.reader.bufferedLen() >= n) {
            const buf = try allocator.alloc(u8, n);
            errdefer allocator.free(buf);
            try it.readExact(buf);
            it.pending = 0;
            return buf;
        }

        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        while (list.items.len < n) {
            const step = @min(n - list.items.len, alloc_step);
            try list.ensureUnusedCapacity(allocator, step);
            try it.readExact(list.unusedCapacitySlice()[0..step]);
            list.items.len += step;
        }
        it.pending = 0;
        return list.toOwnedSlice(allocator);
    }

    /// Returns a reader limited to the current chunk's payload, for
    /// processing it piece by piece. Valid until the next `next()` call.
    pub fn dataReader(it: *Iterator, buffer: []u8) *std.Io.Reader {
        std.debug.assert(it.limited == null);
        it.limited = it.reader.limited(.limited(@intCast(it.pending)), buffer);
        return &it.limited.?.interface;
    }

    /// Short header or container header ->
    /// InvalidFormat, declared size beyond the input -> SizeMismatch. The
    /// size check needs `total_len`; without it, a short input is only
    /// detected when reading runs out.
    fn readTop(it: *Iterator) Error!Event {
        if (it.total_len) |total| if (total < 8) return error.InvalidFormat;

        var hdr: [8]u8 = undefined;
        it.reader.readSliceAll(&hdr) catch |e| return mapHeader(e);
        it.pos += 8;
        const id = hdr[0..4];
        const size = std.mem.readInt(u32, hdr[4..8], .little);
        const data_end = 8 + @as(u64, size);

        if (isContainer(id)) {
            if (it.total_len) |total| if (total < 12) return error.InvalidFormat;
            if (size < 4) return error.InvalidFormat;
            if (it.total_len) |total| if (total < data_end) return error.SizeMismatch;
            var t: [4]u8 = undefined;
            it.reader.readSliceAll(&t) catch |e| return mapHeader(e);
            it.pos += 4;
            it.push(kindOf(id), data_end, 0);
            return .{ .begin_container = .{ .kind = kindOf(id), .four_cc = try FourCC.new(&t), .size = size } };
        }

        if (it.total_len) |total| if (total < data_end) return error.SizeMismatch;
        it.pending = size;
        it.pending_pad = 0;
        return .{ .chunk = .{ .four_cc = try FourCC.new(id), .size = size } };
    }

    /// Skips whatever the caller left unread of the current chunk.
    fn finishCurrent(it: *Iterator) Error!void {
        if (it.limited) |l| {
            // Bytes the sub-reader pulled from `reader` (even if still sitting
            // unread in its own buffer) are gone from `reader`.
            const left: u64 = @intFromEnum(l.remaining);
            it.pos += it.pending - left;
            it.pending = left;
            it.limited = null;
        }
        const n = it.pending + it.pending_pad;
        it.pending = 0;
        it.pending_pad = 0;
        if (n > 0) try it.skip(n);
    }

    fn push(it: *Iterator, kind: Kind, end: u64, pad: u1) void {
        it.ends[it.depth] = end;
        it.pads[it.depth] = pad;
        it.kinds[it.depth] = kind;
        it.depth += 1;
    }

    fn readExact(it: *Iterator, buf: []u8) Error!void {
        it.reader.readSliceAll(buf) catch |e| return mapPayload(e);
        it.pos += buf.len;
    }

    fn skip(it: *Iterator, n: u64) Error!void {
        it.reader.discardAll64(n) catch |e| return mapPayload(e);
        it.pos += n;
    }
};

/// Builds a `Chunk` tree by pulling from `reader` incrementally, so any buffer
/// size works (no whole-file buffering needed). This is what `riff.read()`
/// calls with default options. Pass `Options.total_len` whenever the input
/// length is known: the declared size is then checked against it up front, so
/// a truncated input is reported the same way regardless of where it is cut,
/// and each payload is allocated in one piece.
pub fn readTree(allocator: std.mem.Allocator, reader: *std.Io.Reader, options: Options) riff.ReadError!Chunk {
    const Frame = struct { kind: Kind, four_cc: FourCC, list: std.array_list.Aligned(Chunk, null) };

    var it = Iterator.init(reader, options);
    var frames: [max_nesting_depth + 1]Frame = undefined;
    var n: usize = 0;
    errdefer for (frames[0..n]) |*f| {
        for (f.list.items) |c| c.deinit(allocator);
        f.list.deinit(allocator);
    };

    while (try it.next()) |ev| switch (ev) {
        .begin_container => |b| {
            frames[n] = .{ .kind = b.kind, .four_cc = b.four_cc, .list = .empty };
            n += 1;
        },
        .chunk => |c| {
            const d = try it.readDataAlloc(allocator);
            const ch: Chunk = .{ .chunk = .{ .four_cc = c.four_cc, .data = d } };
            if (n == 0) return ch;
            frames[n - 1].list.append(allocator, ch) catch |e| {
                allocator.free(d);
                return e;
            };
        },
        .end_container => {
            const children = try frames[n - 1].list.toOwnedSlice(allocator);
            n -= 1;
            const f = frames[n];
            const ch: Chunk = switch (f.kind) {
                .riff => .{ .riff = .{ .four_cc = f.four_cc, .chunks = children } },
                .list => .{ .list = .{ .four_cc = f.four_cc, .chunks = children } },
            };
            if (n == 0) return ch;
            frames[n - 1].list.append(allocator, ch) catch |e| {
                ch.deinit(allocator);
                return e;
            };
        },
    };
    unreachable; // the first event always opens or is the top-level chunk
}

fn isContainer(id: *const [4]u8) bool {
    return std.mem.eql(u8, id, "RIFF") or std.mem.eql(u8, id, "LIST");
}

fn kindOf(id: *const [4]u8) Kind {
    return if (std.mem.eql(u8, id, "RIFF")) .riff else .list;
}

fn mapPayload(e: std.Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.SizeMismatch,
        error.ReadFailed => error.ReadFailed,
    };
}

fn mapHeader(e: std.Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.InvalidFormat,
        error.ReadFailed => error.ReadFailed,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const samples = [_][]const u8{
    @embedFile("assets/riff-files/chunk.riff"),
    @embedFile("assets/riff-files/list_chunk.riff"),
    @embedFile("assets/riff-files/riff_chunk.riff"),
    @embedFile("assets/riff-files/riff_chunk_has_list.riff"),
    @embedFile("assets/riff-files/test_DJ.webp"),
    @embedFile("assets/riff-files/FluidR3_GM2-2.sf2"),
};

// Reference implementation for the differential tests below: the buffer-only
// parser `riff.read()` used before it was rebuilt on `Iterator`. It needs the
// whole input already buffered. Test-only; kept so `readTree()` stays checked
// against an independently written parser.
fn referenceRead(allocator: std.mem.Allocator, reader: *std.Io.Reader) riff.ReadError!Chunk {
    // A chunk header is a FourCC (4 bytes) followed by a little-endian u32 size (4 bytes).
    const four_cc_len = 4;
    const header_len = four_cc_len + @sizeOf(u32);
    // RIFF/LIST containers have an extra type FourCC right after the header.
    const container_header_len = header_len + four_cc_len;

    const buffer = reader.buffered();

    if (buffer.len < header_len)
        return error.InvalidFormat;

    const id = buffer[0..four_cc_len];
    const size = std.mem.readInt(u32, buffer[four_cc_len..header_len], .little);

    const is_riff = std.mem.eql(u8, id, "RIFF");
    const is_list = std.mem.eql(u8, id, "LIST");
    if (is_riff or is_list) {
        if (buffer.len < container_header_len or size < four_cc_len)
            return error.InvalidFormat;

        // Widen to usize before adding: `header_len` is a comptime_int with no
        // usize operand in this expression, so `header_len + size` would stay
        // u32-typed and overflow-panic for `size` near `maxInt(u32)`.
        const data_end: usize = header_len + @as(usize, size);
        if (buffer.len < data_end)
            return error.SizeMismatch;

        const four_cc = buffer[header_len..container_header_len];
        const chunks = try referenceToChunkList(allocator, buffer[container_header_len..data_end], 0);
        const container: riff.Container = .{ .four_cc = try FourCC.new(four_cc), .chunks = chunks };
        return if (is_riff) Chunk{ .riff = container } else Chunk{ .list = container };
    } else {
        const data_end: usize = header_len + @as(usize, size);

        if (buffer.len < data_end)
            return error.SizeMismatch;

        const data = try allocator.dupe(u8, buffer[header_len..data_end]);
        return Chunk{ .chunk = .{ .four_cc = try FourCC.new(id), .data = data } };
    }
}

fn referenceToChunkList(allocator: std.mem.Allocator, bytes: []const u8, depth: usize) (riff.ToChunkListError || std.mem.Allocator.Error || FourCC.NewError)![]const Chunk {
    if (depth > max_nesting_depth)
        return error.NestingTooDeep;

    var list: std.array_list.Aligned(Chunk, null) = .empty;
    errdefer {
        for (list.items) |c| c.deinit(allocator);
        list.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < bytes.len) {
        // Need at least 8 bytes for chunk header (FourCC + size)
        if (pos + 8 > bytes.len) {
            // The RIFF spec only pads a chunk with a single zero byte, to
            // keep the container's overall size even, after an odd-length
            // chunk (write() emits exactly one such byte). Anything else
            // here - more than one leftover byte, or a non-zero byte - is
            // not standard padding and likely indicates truncated/corrupted
            // data, so it must not be silently accepted.
            if (bytes.len - pos == 1 and bytes[pos] == 0) {
                break;
            }
            return error.InvalidFormat;
        }

        const id = bytes[pos .. pos + 4][0..4];
        const size = std.mem.readInt(u32, bytes[pos + 4 .. pos + 8][0..4], .little);

        // Detect overflow explicitly rather than just widening to usize:
        // on a 32-bit target `usize` is `u32`, so there is no wider type to
        // widen into, and `pos + 8 + size` can still overflow-panic for a
        // `size` near `maxInt(u32)`. std.math.add reports the overflow as
        // an error instead of panicking, on every target.
        const header_end = std.math.add(usize, pos, 8) catch return error.SizeMismatch;
        const next_pos = std.math.add(usize, header_end, size) catch return error.SizeMismatch;

        if (next_pos > bytes.len) return error.SizeMismatch;

        // A nested "RIFF" is handled identically to "LIST": both are just a
        // container header (id + size + type FourCC) followed by sub-chunks.
        // write() already serializes a nested `.riff` this way, so read() must
        // recognize it too, or the nested chunk round-trips back as an opaque
        // `.chunk` leaf instead of its original `.riff` structure.
        if (std.mem.eql(u8, id, "LIST") or std.mem.eql(u8, id, "RIFF")) {
            if (next_pos < pos + 12) return error.InvalidFormat;
            const container_type = bytes[pos + 8 .. pos + 12][0..4];
            const sub_chunks = try referenceToChunkList(allocator, bytes[pos + 12 .. next_pos], depth + 1);
            errdefer {
                for (sub_chunks) |c| c.deinit(allocator);
                allocator.free(sub_chunks);
            }
            const four_cc = try FourCC.new(container_type);
            try list.append(allocator, if (std.mem.eql(u8, id, "LIST"))
                Chunk{ .list = .{ .four_cc = four_cc, .chunks = sub_chunks } }
            else
                Chunk{ .riff = .{ .four_cc = four_cc, .chunks = sub_chunks } });
        } else {
            const chunk_data = try allocator.dupe(u8, bytes[pos + 8 .. next_pos]);
            errdefer allocator.free(chunk_data);
            try list.append(allocator, Chunk{ .chunk = .{
                .four_cc = try FourCC.new(id),
                .data = chunk_data,
            } });
        }

        // RIFF chunks are padded to an even byte boundary: `write()` emits a
        // pad byte after odd-length data, but that pad byte is not counted in
        // `size`, so it must be skipped here before parsing the next sibling.
        pos = next_pos + (size % 2);
    }

    return list.toOwnedSlice(allocator);
}

fn expectSameTree(a: Chunk, b: Chunk) !void {
    try testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    switch (a) {
        .chunk => |x| {
            try testing.expectEqualSlices(u8, &x.four_cc.inner, &b.chunk.four_cc.inner);
            try testing.expectEqualSlices(u8, x.data, b.chunk.data);
        },
        inline .list, .riff => |x, tag| {
            const y = @field(b, @tagName(tag));
            try testing.expectEqualSlices(u8, &x.four_cc.inner, &y.four_cc.inner);
            try testing.expectEqual(x.chunks.len, y.chunks.len);
            for (x.chunks, y.chunks) |cx, cy| try expectSameTree(cx, cy);
        },
    }
}

test "stream: event sequence of riff_chunk_has_list.riff" {
    var r: std.Io.Reader = .fixed(@embedFile("assets/riff-files/riff_chunk_has_list.riff"));
    var it = Iterator.init(&r, .{});

    const e1 = (try it.next()).?;
    try testing.expectEqual(Kind.riff, e1.begin_container.kind);
    try testing.expectEqualStrings("TEST", &e1.begin_container.four_cc.inner);
    const e2 = (try it.next()).?;
    try testing.expectEqual(Kind.list, e2.begin_container.kind);
    for (0..2) |_| {
        const c = (try it.next()).?;
        try testing.expectEqualStrings("fmt ", &c.chunk.four_cc.inner);
        try testing.expectEqualStrings("EXAMPLE_DATA", try it.data());
    }
    try testing.expectEqual(Kind.list, (try it.next()).?.end_container);
    try testing.expectEqual(Kind.riff, (try it.next()).?.end_container);
    try testing.expectEqual(null, try it.next());
    try testing.expectEqual(null, try it.next());
}

fn expectReadTreeMatches(expected: Chunk, bytes: []const u8, buffer: ?[]u8, options: Options) !void {
    const a = testing.allocator;
    var src: std.Io.Reader = .fixed(bytes);
    // With a buffer, wrap in a reader whose own buffer is that small, as a
    // small-buffer file reader would be. The reference parser cannot handle this.
    var no_buffer: [0]u8 = .{};
    var small = src.limited(.unlimited, buffer orelse &no_buffer);
    const reader = if (buffer != null) &small.interface else &src;
    const got = try readTree(a, reader, options);
    defer got.deinit(a);
    try expectSameTree(expected, got);
}

test "stream: readTree == reference parser on every sample, whole buffer and 4 KiB streaming buffer" {
    const a = testing.allocator;
    var buf: [4096]u8 = undefined;
    for (samples) |bytes| {
        var r_old: std.Io.Reader = .fixed(bytes);
        const old = try referenceRead(a, &r_old);
        defer old.deinit(a);

        const sized: Options = .{ .total_len = bytes.len };
        try expectReadTreeMatches(old, bytes, null, .{});
        try expectReadTreeMatches(old, bytes, null, sized);
        try expectReadTreeMatches(old, bytes, &buf, .{});
        try expectReadTreeMatches(old, bytes, &buf, sized);
    }
}

test "stream: skip everything but one chunk, streamed in 256-byte pieces" {
    var src: std.Io.Reader = .fixed(@embedFile("assets/riff-files/FluidR3_GM2-2.sf2"));
    var buf: [4096]u8 = undefined;
    var small = src.limited(.unlimited, &buf);
    var it = Iterator.init(&small.interface, .{});

    const expected = @embedFile("assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.shdr.data.bin");
    var hasher = std.hash.Wyhash.init(0);
    var got_len: usize = 0;
    var chunks: usize = 0;
    while (try it.next()) |ev| switch (ev) {
        .chunk => |c| {
            chunks += 1;
            if (std.mem.eql(u8, &c.four_cc.inner, "shdr")) {
                var piece: [256]u8 = undefined;
                const dr = it.dataReader(&piece);
                while (true) {
                    const got = dr.peekGreedy(1) catch |e| switch (e) {
                        error.EndOfStream => break,
                        else => return e,
                    };
                    hasher.update(got);
                    got_len += got.len;
                    dr.toss(got.len);
                }
            }
        },
        else => {},
    };
    try testing.expect(chunks > 1);
    try testing.expectEqual(expected.len, got_len);
    try testing.expectEqual(std.hash.Wyhash.hash(0, expected), hasher.final());
}

// Differential check on corrupted inputs: the reference parser and readTree()
// must agree on success vs failure (and on the tree when both succeed). With
// `Options.total_len` the error kind must match too; without it, it may
// differ, since the reference parser checks the top-level size before the
// children and a stream of unknown length cannot.
test "stream: differential against the reference parser on mutated/truncated samples" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var buf: [128]u8 = undefined;

    for (samples[0..4]) |seed| {
        for (0..5000) |_| {
            var len = seed.len;
            @memcpy(buf[0..len], seed);
            switch (rand.uintLessThan(u8, 3)) {
                0 => len = rand.uintLessThan(usize, seed.len + 1),
                1 => for (0..rand.intRangeAtMost(usize, 1, 3)) |_| {
                    buf[rand.uintLessThan(usize, len)] = rand.int(u8);
                },
                else => {
                    const p = rand.uintLessThan(usize, len - 3);
                    std.mem.writeInt(u32, buf[p..][0..4], rand.uintLessThan(u32, 80), .little);
                },
            }
            const input = buf[0..len];

            var r1: std.Io.Reader = .fixed(input);
            const old = referenceRead(a, &r1);
            defer if (old) |c| c.deinit(a) else |_| {};

            for ([_]?u64{ null, input.len }) |total_len| {
                // Stream through a 1-byte buffer to stress refills.
                var r2: std.Io.Reader = .fixed(input);
                var tiny: [1]u8 = undefined;
                var lim = r2.limited(.unlimited, &tiny);
                const new = readTree(a, &lim.interface, .{ .total_len = total_len });
                defer if (new) |c| c.deinit(a) else |_| {};

                if (old) |o| {
                    const nn = new catch |e| {
                        std.debug.print("reference ok, readTree(total_len={?d}) {t}: {x}\n", .{ total_len, e, input });
                        return error.TestUnexpectedResult;
                    };
                    try expectSameTree(o, nn);
                } else |eo| {
                    if (new) |_| {
                        std.debug.print("reference {t}, readTree(total_len={?d}) ok: {x}\n", .{ eo, total_len, input });
                        return error.TestUnexpectedResult;
                    } else |en| if (total_len != null and eo != en) {
                        std.debug.print("reference {t}, readTree(total_len={?d}) {t}: {x}\n", .{ eo, total_len, en, input });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }
    }
}

test "stream: a tiny input claiming a huge chunk fails without a huge allocation" {
    // 256 KiB is far below the ~4 GiB the headers claim: trusting the size
    // field would fail with OutOfMemory instead of SizeMismatch.
    const backing = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(backing);

    const inputs = [_][]const u8{
        // Top-level leaf chunk claiming 0xFFFFFFFF bytes.
        "data\xff\xff\xff\xffabc",
        // Leaf chunk nested in a RIFF container that claims to hold it.
        "RIFF\xff\xff\xff\xffTESTdata\xf0\xff\xff\xffabc",
    };
    for (inputs) |input| {
        var fba = std.heap.FixedBufferAllocator.init(backing);

        var whole: std.Io.Reader = .fixed(input);
        try testing.expectError(error.SizeMismatch, readTree(fba.allocator(), &whole, .{}));

        fba.reset();
        var src: std.Io.Reader = .fixed(input);
        var tiny: [4]u8 = undefined;
        var small = src.limited(.unlimited, &tiny);
        try testing.expectError(error.SizeMismatch, readTree(fba.allocator(), &small.interface, .{}));

        // With the input length known, the size is rejected before any
        // allocation at all.
        var no_memory: [0]u8 = .{};
        var none = std.heap.FixedBufferAllocator.init(&no_memory);
        var sized: std.Io.Reader = .fixed(input);
        try testing.expectError(error.SizeMismatch, readTree(none.allocator(), &sized, .{ .total_len = input.len }));
    }
}

test "stream: readTree never leaks on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(a: std.mem.Allocator, b: []const u8) !void {
            var r: std.Io.Reader = .fixed(b);
            const c = try readTree(a, &r, .{ .total_len = b.len });
            c.deinit(a);
        }
    }.f, .{@as([]const u8, @embedFile("assets/riff-files/riff_chunk_has_list.riff"))});
}
