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
pub const DataError = Error || AccessError || error{
    /// `data()` was called on a chunk larger than the reader's buffer.
    BufferTooSmall,
};

/// Errors of `Iterator.data()`/`Iterator.dataReader()` relating to reentrancy.
pub const BorrowError = error{
    /// `data()` or `dataReader()` was called while a `dataReader()` sub-reader
    /// obtained from this same `Iterator` is still open (its payload has not
    /// been fully consumed and `next()` has not been called since). Checked
    /// in every build mode, unlike a `std.debug.assert`, since silently
    /// reading from both the sub-reader and `Iterator` at once would corrupt
    /// `Iterator`'s position accounting instead of merely misbehaving in a
    /// debug build.
    AlreadyBorrowed,
};

/// Errors of `Iterator.data()`/`readDataAlloc()`/`dataReader()` for calls made
/// at the wrong moment: a payload can be taken once per `.chunk` event.
pub const AccessError = BorrowError || error{
    /// The last event was not a `.chunk` (e.g. `begin_container`), or the
    /// chunk's payload was already taken.
    NoPayload,
};

/// Growth increment `Iterator.readDataAlloc()` uses when a payload is not
/// already fully buffered.
pub const alloc_step = 64 * 1024;

pub const Kind = enum { riff, list };

pub const Event = union(enum) {
    /// A RIFF/LIST header was read. Its children follow as further events.
    begin_container: struct { kind: Kind, four_cc: FourCC, size: u32 },
    /// A leaf chunk header was read. Its payload has NOT been read yet: use
    /// `data()`, `readDataAlloc()` or `dataReader()` (once: a second attempt
    /// returns `error.NoPayload`), or ignore it and the next `next()` call
    /// skips it.
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

/// Pull-style RIFF parser: call `next()` repeatedly to get the `Event`s.
///
/// Keep the `Iterator` in one place once `dataReader()` has been called: the
/// reader it returns points into the `Iterator` itself, so moving or copying
/// the struct while that reader is in use invalidates it.
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
    /// Set by the first error `next()` returns, or by a failed read while
    /// fetching a payload. The stream position is unreliable after such an
    /// error, so every later `next()` returns the same error.
    failed: ?Error = null,
    /// True from a `.chunk` event until its payload is taken (`data()`,
    /// `readDataAlloc()`, `dataReader()`) or the next `next()` call.
    payload_ready: bool = false,

    pub fn init(reader: *std.Io.Reader, options: Options) Iterator {
        return .{ .reader = reader, .total_len = options.total_len };
    }

    /// Returns the next event, or null once the top-level chunk is complete.
    ///
    /// After an error, every further call returns that same error instead of
    /// continuing from an unreliable position (or reporting a clean end of
    /// stream). Payload access errors (`BufferTooSmall`, `AlreadyBorrowed`,
    /// `NoPayload`) consume nothing and are not sticky.
    pub fn next(it: *Iterator) Error!?Event {
        if (it.failed) |e| return e;
        return it.nextEvent() catch |e| return it.fail(e);
    }

    fn fail(it: *Iterator, e: Error) Error {
        it.failed = e;
        return e;
    }

    fn nextEvent(it: *Iterator) Error!?Event {
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
        it.payload_ready = true;
        return .{ .chunk = .{ .four_cc = try FourCC.new(id), .size = size } };
    }

    /// Borrows the whole payload of the current chunk from the reader's
    /// buffer. Valid until the next call on this iterator.
    ///
    /// Returns `error.NoPayload` unless the last event was a `.chunk` whose
    /// payload has not been taken yet: the payload can be fetched only once.
    pub fn data(it: *Iterator) DataError![]const u8 {
        if (it.limited != null) return error.AlreadyBorrowed;
        if (!it.payload_ready) return error.NoPayload;
        const n: usize = @intCast(it.pending);
        if (n > it.reader.buffer.len) return error.BufferTooSmall;
        const s = it.reader.take(n) catch |e| return it.fail(mapPayload(e));
        it.pos += n;
        it.pending = 0;
        it.payload_ready = false;
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
    ///
    /// Returns `error.AlreadyBorrowed` if a `dataReader()` sub-reader is
    /// still open, like `data()` and `dataReader()` do, and
    /// `error.NoPayload` unless the last event was a `.chunk` whose payload
    /// has not been taken yet.
    pub fn readDataAlloc(it: *Iterator, allocator: std.mem.Allocator) (Error || AccessError || std.mem.Allocator.Error)![]u8 {
        if (it.limited != null) return error.AlreadyBorrowed;
        if (!it.payload_ready) return error.NoPayload;
        const n: usize = @intCast(it.pending);

        if (it.total_len != null or it.reader.bufferedLen() >= n) {
            const buf = try allocator.alloc(u8, n);
            errdefer allocator.free(buf);
            try it.readExact(buf);
            it.pending = 0;
            it.payload_ready = false;
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
        it.payload_ready = false;
        return list.toOwnedSlice(allocator);
    }

    /// Returns a reader limited to the current chunk's payload, for
    /// processing it piece by piece. Valid until the next `next()` call.
    ///
    /// The returned reader lives inside this `Iterator` (its state is stored
    /// in `it.limited`), so do not move or copy the `Iterator` while it is in
    /// use: a copy would leave the reader referring to the original.
    ///
    /// Returns `error.NoPayload` unless the last event was a `.chunk` whose
    /// payload has not been taken yet.
    pub fn dataReader(it: *Iterator, buffer: []u8) AccessError!*std.Io.Reader {
        if (it.limited != null) return error.AlreadyBorrowed;
        if (!it.payload_ready) return error.NoPayload;
        it.payload_ready = false;
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
        it.payload_ready = true;
        return .{ .chunk = .{ .four_cc = try FourCC.new(id), .size = size } };
    }

    /// Skips whatever the caller left unread of the current chunk.
    fn finishCurrent(it: *Iterator) Error!void {
        it.payload_ready = false;
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
        it.reader.readSliceAll(buf) catch |e| return it.fail(mapPayload(e));
        it.pos += buf.len;
    }

    fn skip(it: *Iterator, n: u64) Error!void {
        it.reader.discardAll64(n) catch |e| return it.fail(mapPayload(e));
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
            // readTree() never calls dataReader(), so no sub-reader is open.
            const d = it.readDataAlloc(allocator) catch |e| switch (e) {
                error.AlreadyBorrowed, error.NoPayload => unreachable,
                else => |other| return other,
            };
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

/// Whether a chunk with this id is a container ("RIFF" or "LIST") rather than a
/// leaf. The parser and `riff.write()` (which rejects a leaf with such an id)
/// both use this, so they cannot disagree about which ids are reserved.
pub fn isContainer(id: *const [4]u8) bool {
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
                const dr = try it.dataReader(&piece);
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
// Applies one random corruption to `buf[0..len]` (truncation, a few byte
// flips, or a rewritten size field) and returns the new length.
fn mutate(rand: std.Random, buf: []u8, len_in: usize) usize {
    var len = len_in;
    switch (rand.uintLessThan(u8, 3)) {
        0 => len = rand.uintLessThan(usize, len + 1),
        1 => for (0..rand.intRangeAtMost(usize, 1, 3)) |_| {
            buf[rand.uintLessThan(usize, len)] = rand.int(u8);
        },
        else => {
            const p = rand.uintLessThan(usize, len - 3);
            std.mem.writeInt(u32, buf[p..][0..4], rand.uintLessThan(u32, 80), .little);
        },
    }
    return len;
}

// Checks that the reference parser and readTree() agree on `input`, both
// with and without `Options.total_len`, and both fed through a 1-byte buffer.
fn expectAgreesWithReference(a: std.mem.Allocator, input: []const u8) !void {
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

test "stream: differential against the reference parser on mutated/truncated samples" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var buf: [128]u8 = undefined;

    for (samples[0..4]) |seed| {
        for (0..5000) |_| {
            @memcpy(buf[0..seed.len], seed);
            const len = mutate(rand, &buf, seed.len);
            try expectAgreesWithReference(a, buf[0..len]);
        }
    }
}

// `containers` nested containers as raw bytes: an outermost "RIFF", then
// "LIST"s, with a small leaf in the innermost one.
fn nestedContainers(a: std.mem.Allocator, containers: usize) ![]u8 {
    var prev = try a.dupe(u8, "data" ++ "\x02\x00\x00\x00" ++ "AB");
    errdefer a.free(prev);
    for (0..containers) |i| {
        const wrapped = try a.alloc(u8, 12 + prev.len);
        @memcpy(wrapped[0..4], if (i == containers - 1) "RIFF" else "LIST");
        std.mem.writeInt(u32, wrapped[4..8], @intCast(4 + prev.len), .little);
        @memcpy(wrapped[8..12], "TEST");
        @memcpy(wrapped[12..], prev);
        a.free(prev);
        prev = wrapped;
    }
    return prev;
}

test "stream: differential against the reference parser on deeply nested input around max_nesting_depth" {
    // The samples above are too small to nest more than a few levels, so they
    // never reach the depth limit. Cover chains just below, at and just above
    // it, unmodified and mutated.
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdee9);
    const rand = prng.random();

    for (max_nesting_depth - 2..max_nesting_depth + 4) |containers| {
        const seed = try nestedContainers(a, containers);
        defer a.free(seed);
        try expectAgreesWithReference(a, seed);

        const buf = try a.alloc(u8, seed.len);
        defer a.free(buf);
        for (0..300) |_| {
            @memcpy(buf, seed);
            const len = mutate(rand, buf, seed.len);
            try expectAgreesWithReference(a, buf[0..len]);
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

test "stream: data() returns BufferTooSmall when the chunk is larger than the reader's buffer" {
    const buffer = "data" ++ "\x08\x00\x00\x00" ++ "ABCDEFGH";

    var src: std.Io.Reader = .fixed(buffer);
    var tiny: [4]u8 = undefined; // smaller than the 8-byte payload
    var small = src.limited(.unlimited, &tiny);
    var it = Iterator.init(&small.interface, .{});

    const ev = (try it.next()).?;
    try testing.expectEqualStrings("data", &ev.chunk.four_cc.inner);
    try testing.expectError(error.BufferTooSmall, it.data());
}

test "stream: next() skips a dataReader()'s unconsumed remainder instead of desyncing" {
    // Regression test: finishCurrent() must account for bytes a dataReader()
    // sub-reader pulled into its own buffer but the caller never read, not
    // just the bytes never pulled from the underlying reader at all -
    // otherwise the next sibling's header is parsed from the wrong offset.
    const child1 = "aaaa" ++ "\x04\x00\x00\x00" ++ "WXYZ";
    const child2 = "bbbb" ++ "\x04\x00\x00\x00" ++ "1234";
    const buffer = "RIFF" ++ "\x1c\x00\x00\x00" ++ "TEST" ++ child1 ++ child2;

    var r: std.Io.Reader = .fixed(buffer);
    var it = Iterator.init(&r, .{});

    const e1 = (try it.next()).?;
    try testing.expectEqual(Kind.riff, e1.begin_container.kind);

    const e2 = (try it.next()).?;
    try testing.expectEqualStrings("aaaa", &e2.chunk.four_cc.inner);

    // Read only the first byte of "aaaa"'s 4-byte payload through a
    // dataReader(), leaving the other 3 bytes (plus whatever the sub-reader
    // over-buffered) undrained.
    var piece: [2]u8 = undefined;
    const dr = try it.dataReader(&piece);
    const got = try dr.peekGreedy(1);
    dr.toss(got.len);

    const e3 = (try it.next()).?;
    try testing.expectEqualStrings("bbbb", &e3.chunk.four_cc.inner);
    try testing.expectEqualStrings("1234", try it.data());

    try testing.expectEqual(Kind.riff, (try it.next()).?.end_container);
    try testing.expectEqual(null, try it.next());
}

test "stream: readDataAlloc() returns AlreadyBorrowed while a dataReader() sub-reader is still open" {
    const buffer = "data" ++ "\x02\x00\x00\x00" ++ "AB";

    var r: std.Io.Reader = .fixed(buffer);
    var it = Iterator.init(&r, .{});
    _ = (try it.next()).?;

    var piece: [8]u8 = undefined;
    _ = try it.dataReader(&piece);

    // Checked in every build mode, not just Debug: reading through both the
    // sub-reader and readDataAlloc() would corrupt position accounting.
    try testing.expectError(error.AlreadyBorrowed, it.readDataAlloc(testing.allocator));
}

test "stream: data()/dataReader() return AlreadyBorrowed while a dataReader() sub-reader is still open" {
    const buffer = "data" ++ "\x02\x00\x00\x00" ++ "AB";

    var r: std.Io.Reader = .fixed(buffer);
    var it = Iterator.init(&r, .{});
    _ = (try it.next()).?;

    var piece: [8]u8 = undefined;
    _ = try it.dataReader(&piece);

    // Neither data() nor a second dataReader() may borrow again until the
    // first sub-reader has been retired via next().
    try testing.expectError(error.AlreadyBorrowed, it.data());
    try testing.expectError(error.AlreadyBorrowed, it.dataReader(&piece));
}

test "stream: next() keeps returning the same error after a failed first call instead of null" {
    // Regression test: `state` used to become .running before readTop() ran,
    // so after readTop() failed a second next() saw depth == 0 and returned
    // null, which looks like a clean end of stream.
    var r: std.Io.Reader = .fixed("RIFF" ++ "\x02\x00\x00\x00");
    var it = Iterator.init(&r, .{});

    try testing.expectError(error.InvalidFormat, it.next());
    try testing.expectError(error.InvalidFormat, it.next());
    try testing.expectError(error.InvalidFormat, it.next());
}

test "stream: next() keeps returning the same error after a mid-stream failure" {
    // The child claims 0x20 bytes but its container ends right after the
    // header. A second next() used to see the container as ended and report
    // a normal end_container event.
    const buffer = "RIFF" ++ "\x0c\x00\x00\x00" ++ "TEST" ++ "data" ++ "\x20\x00\x00\x00";
    var r: std.Io.Reader = .fixed(buffer);
    var it = Iterator.init(&r, .{});

    try testing.expectEqual(Kind.riff, (try it.next()).?.begin_container.kind);
    try testing.expectError(error.SizeMismatch, it.next());
    try testing.expectError(error.SizeMismatch, it.next());
}

test "stream: BufferTooSmall from data() is recoverable and does not stop the iterator" {
    const buffer = "data" ++ "\x08\x00\x00\x00" ++ "ABCDEFGH";
    var src: std.Io.Reader = .fixed(buffer);
    var tiny: [4]u8 = undefined;
    var small = src.limited(.unlimited, &tiny);
    var it = Iterator.init(&small.interface, .{});

    _ = (try it.next()).?;
    try testing.expectError(error.BufferTooSmall, it.data());
    // Nothing was consumed, so the payload is skipped and iteration ends normally.
    try testing.expectEqual(null, try it.next());
}

test "stream: a chunk's payload can be taken only once" {
    // Regression test: after data()/readDataAlloc() consumed a payload,
    // `pending` was 0, so a second call silently returned an empty slice.
    const buffer = "data" ++ "\x02\x00\x00\x00" ++ "AB";

    {
        var r: std.Io.Reader = .fixed(buffer);
        var it = Iterator.init(&r, .{});
        _ = (try it.next()).?;
        try testing.expectEqualStrings("AB", try it.data());
        try testing.expectError(error.NoPayload, it.data());
        try testing.expectError(error.NoPayload, it.readDataAlloc(testing.allocator));
        var piece: [4]u8 = undefined;
        try testing.expectError(error.NoPayload, it.dataReader(&piece));
    }
    {
        var r: std.Io.Reader = .fixed(buffer);
        var it = Iterator.init(&r, .{});
        _ = (try it.next()).?;
        const got = try it.readDataAlloc(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("AB", got);
        try testing.expectError(error.NoPayload, it.readDataAlloc(testing.allocator));
        try testing.expectError(error.NoPayload, it.data());
    }
}

test "stream: an empty chunk yields an empty payload once, then NoPayload" {
    var r: std.Io.Reader = .fixed("data" ++ "\x00\x00\x00\x00");
    var it = Iterator.init(&r, .{});
    _ = (try it.next()).?;
    try testing.expectEqual(0, (try it.data()).len);
    try testing.expectError(error.NoPayload, it.data());
}

test "stream: payload access on a container event returns NoPayload" {
    const buffer = "RIFF" ++ "\x04\x00\x00\x00" ++ "TEST";
    var r: std.Io.Reader = .fixed(buffer);
    var it = Iterator.init(&r, .{});

    try testing.expectEqual(Kind.riff, (try it.next()).?.begin_container.kind);
    var piece: [4]u8 = undefined;
    try testing.expectError(error.NoPayload, it.data());
    try testing.expectError(error.NoPayload, it.readDataAlloc(testing.allocator));
    try testing.expectError(error.NoPayload, it.dataReader(&piece));
    // The misuse errors consume nothing.
    try testing.expectEqual(Kind.riff, (try it.next()).?.end_container);
}

test "stream: the payload is still available after BufferTooSmall from data()" {
    const buffer = "data" ++ "\x08\x00\x00\x00" ++ "ABCDEFGH";
    var src: std.Io.Reader = .fixed(buffer);
    var tiny: [4]u8 = undefined;
    var small = src.limited(.unlimited, &tiny);
    var it = Iterator.init(&small.interface, .{});

    _ = (try it.next()).?;
    try testing.expectError(error.BufferTooSmall, it.data());
    const got = try it.readDataAlloc(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ABCDEFGH", got);
}
