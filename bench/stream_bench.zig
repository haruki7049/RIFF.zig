//! PROTOTYPE benchmark: current `read()` vs. the streaming prototype
//! (`stream.readTree()` / `stream.Iterator`) on one RIFF file.
//!
//! Usage (one mode per process, so the peak RSS is that mode's own):
//!
//!   zig build bench -Doptimize=ReleaseFast -- <mode> <path> [iterations] [buffer_bytes] [flags]
//!
//! Modes:
//!   read         - current API: readFileAlloc() the whole file, then read() it
//!   tree         - readTree() straight from a File.Reader with a `buffer_bytes`
//!                  buffer, given the file size as `Options.total_len`
//!   tree_unsized - same, without `total_len` (as for a pipe or socket)
//!   skip         - Iterator over a File.Reader, visiting every header,
//!                  reading no payload
//!
//! Flags (address the process-wide, iteration-count-inflated peak RSS that
//! `getrusage()` reports on macOS, where `free()` keeps freed pages resident):
//!   --rss=none        - default: unchanged, print one peak RSS after all
//!                        iterations (misleading for iterations > 1 on macOS)
//!   --rss=single       - default `iterations` to 1 instead of 5
//!   --rss=first        - also print the peak RSS right after iteration 1
//!   --rss=subprocess   - re-spawn this binary once per iteration (iterations=1,
//!                        no --rss flag passed down) and report the max peak RSS
//!                        across the children, each measured independently
//!   --alloc-stats      - wrap `gpa` to also print each iteration's peak live
//!                        (allocated-but-not-freed) byte count
//!
//! For comparison without any bench code changes, run with `--rss=single` (or
//! an explicit iterations=1) and let an external tool repeat and measure, e.g.:
//!
//!   for i in $(seq 5); do zig build bench -Doptimize=ReleaseFast -- tree_unsized <path> 1; done
//!   /usr/bin/time -l zig-out/bin/stream-bench tree_unsized <path> 1
//!   hyperfine 'zig-out/bin/stream-bench tree_unsized <path> 1'
//!
//! Prints the time of each iteration, the fastest one, the number of leaf
//! chunks and payload bytes seen (to show every mode walked the same file),
//! and the process's peak RSS.

const std = @import("std");
const builtin = @import("builtin");
const riff = @import("riff");

const Mode = enum { read, tree, tree_unsized, skip };
const RssMode = enum { none, single, first, subprocess };

const Stats = struct {
    leaves: usize = 0,
    payload_bytes: u64 = 0,

    fn addTree(s: *Stats, chunk: riff.Chunk) void {
        switch (chunk) {
            .chunk => |c| {
                s.leaves += 1;
                s.payload_bytes += c.data.len;
            },
            inline .list, .riff => |c| for (c.chunks) |child| s.addTree(child),
        }
    }
};

/// Wraps another allocator to track the peak number of live (allocated but
/// not yet freed) bytes. `reset()` starts a new peak measurement from the
/// current live-byte count, so repeated calls give a per-iteration peak.
const TrackingAllocator = struct {
    child: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn reset(self: *TrackingAllocator) void {
        self.peak_bytes = self.live_bytes;
    }

    fn recordGrowth(self: *TrackingAllocator, old_len: usize, new_len: usize) void {
        self.live_bytes = self.live_bytes - old_len + new_len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr) orelse return null;
        self.recordGrowth(0, len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr)) return false;
        self.recordGrowth(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        self.recordGrowth(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var rss_mode: RssMode = .none;
    var alloc_stats = false;
    var positional: [4][]const u8 = undefined;
    var positional_len: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--alloc-stats")) {
            alloc_stats = true;
        } else if (std.mem.startsWith(u8, arg, "--rss=")) {
            const value = arg["--rss=".len..];
            rss_mode = std.meta.stringToEnum(RssMode, value) orelse {
                std.debug.print("unknown --rss value: {s}\n", .{value});
                std.process.exit(2);
            };
        } else if (positional_len < positional.len) {
            positional[positional_len] = arg;
            positional_len += 1;
        } else {
            std.debug.print("too many arguments: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    const usage_fmt = "usage: {s} <read|tree|tree_unsized|skip> <path> [iterations] [buffer_bytes] [--rss=none|single|first|subprocess] [--alloc-stats]\n";
    if (positional_len < 2) {
        // Bare `zig build bench`, with no args at all, is a request to see
        // the usage, not a usage error: exit 0 so the build step succeeds.
        if (args.len == 1) {
            std.debug.print(usage_fmt, .{args[0]});
            return;
        }
        std.debug.print(usage_fmt, .{args[0]});
        std.process.exit(2);
    }
    const mode = std.meta.stringToEnum(Mode, positional[0]) orelse {
        std.debug.print("unknown mode: {s}\n", .{positional[0]});
        std.process.exit(2);
    };
    const path = positional[1];
    const default_iterations: usize = if (rss_mode == .single) 1 else 5;
    const iterations = if (positional_len > 2) try std.fmt.parseInt(usize, positional[2], 10) else default_iterations;
    const buffer_len = if (positional_len > 3) try std.fmt.parseInt(usize, positional[3], 10) else 64 * 1024;

    var out_buf: [1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_writer.interface;

    if (rss_mode == .subprocess) {
        try runSubprocesses(io, out, args[0], mode, path, iterations, buffer_len, alloc_stats);
        try out.flush();
        return;
    }

    var tracking: TrackingAllocator = .{ .child = gpa };
    const gpa_used: std.mem.Allocator = if (alloc_stats) tracking.allocator() else gpa;

    const buffer = try gpa_used.alloc(u8, buffer_len);
    defer gpa_used.free(buffer);

    try out.print("mode={t} path={s} iterations={d}", .{ mode, path, iterations });
    if (mode != .read) try out.print(" buffer={d}", .{buffer_len});
    try out.writeByte('\n');

    var best_ns: i96 = std.math.maxInt(i96);
    var stats: Stats = .{};
    for (0..iterations) |i| {
        stats = .{};
        if (alloc_stats) tracking.reset();
        const start = std.Io.Timestamp.now(io, .awake);
        switch (mode) {
            .read => {
                const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa_used, .unlimited);
                defer gpa_used.free(bytes);
                var reader: std.Io.Reader = .fixed(bytes);
                const chunk = try riff.read(gpa_used, &reader);
                defer chunk.deinit(gpa_used);
                stats.addTree(chunk);
            },
            .tree, .tree_unsized => {
                const file = try std.Io.Dir.cwd().openFile(io, path, .{});
                defer file.close(io);
                var file_reader = file.reader(io, buffer);
                const options: riff.stream.Options = .{
                    .total_len = if (mode == .tree) try file_reader.getSize() else null,
                };
                const chunk = try riff.stream.readTree(gpa_used, &file_reader.interface, options);
                defer chunk.deinit(gpa_used);
                stats.addTree(chunk);
            },
            .skip => {
                const file = try std.Io.Dir.cwd().openFile(io, path, .{});
                defer file.close(io);
                var file_reader = file.reader(io, buffer);
                var it = riff.stream.Iterator.init(&file_reader.interface, .{
                    .total_len = try file_reader.getSize(),
                });
                while (try it.next()) |ev| switch (ev) {
                    .chunk => |c| {
                        stats.leaves += 1;
                        stats.payload_bytes += c.size;
                    },
                    else => {},
                };
            },
        }
        const ns = start.untilNow(io, .awake).toNanoseconds();
        best_ns = @min(best_ns, ns);
        try out.print("  #{d}: {d:.3} ms\n", .{ i + 1, nsToMs(ns) });
        if (alloc_stats) {
            try out.print("      peak_live={d:.1} MiB\n", .{@as(f64, @floatFromInt(tracking.peak_bytes)) / (1024 * 1024)});
        }
        if (rss_mode == .first and i == 0) {
            try out.print("      peak_rss(after #1)={d:.1} MiB\n", .{@as(f64, @floatFromInt(peakRssBytes())) / (1024 * 1024)});
        }
    }

    try out.print("best={d:.3} ms leaves={d} payload_bytes={d} peak_rss={d:.1} MiB\n", .{
        nsToMs(best_ns),
        stats.leaves,
        stats.payload_bytes,
        @as(f64, @floatFromInt(peakRssBytes())) / (1024 * 1024),
    });
    try out.flush();
}

/// Re-spawns this binary once per iteration (each child running exactly one
/// iteration, with no --rss flag so it measures its own peak RSS in
/// isolation) and reports the max peak RSS observed across the children.
fn runSubprocesses(
    io: std.Io,
    out: *std.Io.Writer,
    self_path: []const u8,
    mode: Mode,
    path: []const u8,
    iterations: usize,
    buffer_len: usize,
    alloc_stats: bool,
) !void {
    try out.print("mode={t} path={s} iterations={d} buffer={d} rss=subprocess\n", .{ mode, path, iterations, buffer_len });

    var max_peak_rss: u64 = 0;
    for (0..iterations) |i| {
        var buffer_len_buf: [20]u8 = undefined;
        const buffer_len_str = try std.fmt.bufPrint(&buffer_len_buf, "{d}", .{buffer_len});

        var argv_buf: [6][]const u8 = undefined;
        var argv_len: usize = 0;
        argv_buf[argv_len] = self_path;
        argv_len += 1;
        argv_buf[argv_len] = @tagName(mode);
        argv_len += 1;
        argv_buf[argv_len] = path;
        argv_len += 1;
        argv_buf[argv_len] = "1";
        argv_len += 1;
        argv_buf[argv_len] = buffer_len_str;
        argv_len += 1;
        if (alloc_stats) {
            argv_buf[argv_len] = "--alloc-stats";
            argv_len += 1;
        }

        var child = try std.process.spawn(io, .{
            .argv = argv_buf[0..argv_len],
            .request_resource_usage_statistics = true,
        });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) {
                try out.print("child #{d} exited with code {d}\n", .{ i + 1, code });
            },
            else => try out.print("child #{d} did not exit normally\n", .{i + 1}),
        }
        if (child.resource_usage_statistics.getMaxRss()) |rss| {
            max_peak_rss = @max(max_peak_rss, rss);
        }
    }

    try out.print("subprocess: {d} children, max child peak_rss={d:.1} MiB\n", .{
        iterations,
        @as(f64, @floatFromInt(max_peak_rss)) / (1024 * 1024),
    });
}

fn nsToMs(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Peak resident set size of this process. `ru_maxrss` is in bytes on
/// Darwin and in KiB on Linux and the BSDs.
fn peakRssBytes() u64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: u64 = @intCast(usage.maxrss);
    return if (builtin.os.tag.isDarwin()) maxrss else maxrss * 1024;
}
