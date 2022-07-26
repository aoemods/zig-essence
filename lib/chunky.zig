const std = @import("std");

/// Header of a Relic Chunky file
/// This is empty and only used to verify that the file is supported
pub const ChunkyHeader = struct {
    const signature = "Relic Chunky\r\n\u{001A}\x00";

    pub fn decode(reader: anytype) !ChunkyHeader {
        var header: ChunkyHeader = undefined;

        var magic: [signature.len]u8 = undefined;
        _ = try reader.readAll(&magic);

        if (!std.mem.eql(u8, &magic, signature))
            return error.InvalidHeader;

        var version = try reader.readIntLittle(u32);
        var platform = try reader.readIntLittle(u32);

        if (version != 4 or platform != 1)
            return error.UnsupportedVersion;

        return header;
    }
};

pub const FourCC = enum(u32) {
    _,

    pub fn fromArray(array: [4]u8) FourCC {
        return @intToEnum(FourCC, std.mem.readIntSliceBig(u32, array));
    }

    pub fn toArray(four: FourCC) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeIntSliceBig(u8, &buf, @enumToInt(four));
        return buf;
    }
};

/// Header of a Chunky chunk
pub const ChunkHeader = struct {
    kind: [4]u8,
    id: [4]u8,
    version: u32,
    size: u32,
    name: []u8,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !ChunkHeader {
        var header: ChunkHeader = undefined;

        _ = try reader.readAll(&header.kind);
        _ = try reader.readAll(&header.id);
        header.version = try reader.readIntLittle(u32);
        header.size = try reader.readIntLittle(u32);

        header.name = try allocator.alloc(u8, try reader.readIntLittle(u32));
        _ = try reader.readAll(header.name);

        return header;
    }

    pub fn deinit(self: *ChunkHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }

    pub fn format(value: ChunkHeader, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        _ = fmt;
        _ = options;

        try writer.print("{s} chunk '{s}' (name: '{s}', version: {d}, size: {d})", .{ value.kind, value.id, value.name, value.version, value.size });
    }
};

const testmod = @embedFile("../samples/testmod.bin");

test {
    const allocator = std.testing.allocator;

    var reader = std.io.fixedBufferStream(testmod).reader();
    _ = try ChunkyHeader.decode(reader);

    while (true) {
        var header = ChunkHeader.decode(allocator, reader) catch break;
        defer header.deinit(allocator);

        if (!std.mem.eql(u8, &header.kind, "DATA") and !std.mem.eql(u8, &header.kind, "FOLD")) break;
        reader.context.seekBy(header.size) catch break;
    }
}
