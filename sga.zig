//! Low-level SGA archive (de/en)coder.

const std = @import("std");

pub const Product = enum(u16) {
    /// Base product
    essence,
    /// Company of Heroes
    coho,
    _,
};

pub const SGAHeader = struct {
    /// Version | Title
    /// ------- | -----
    /// 4 | Company of Heroes 1
    /// 5 | Dawn of War II - Broken
    /// 6 | Unknown
    /// 7 | Company of Heroes 2
    /// 8 | Unknown
    /// 9 | Dawn of War III
    /// 10 | Company of Heroes 3, Age of Empires IV
    version: u16,
    product: Product,
    /// Nice name for the archive; unicode
    nice_name: [64]u16,

    // Hashes - only present in version < 6 because why not that's totally a great idea; thanks Relic!!
    file_md5: ?[16]u8,
    header_md5: ?[16]u8,

    // Offsets and lengths

    /// Base offset, every other offset here except for `data_offset` can be accessed at `offset + other_offset`
    offset: u64,
    /// Offset for raw file data
    data_offset: u64,

    /// Where ToC data is stored (relative to `offset`)
    toc_data_offset: u32,
    /// Number of ToC entries
    toc_data_count: u32,

    /// Where folder data is stored (relative to `offset`)
    folder_data_offset: u32,
    /// Number of folder entries
    folder_data_count: u32,

    /// Where file data is stored (relative to `offset`)
    file_data_offset: u32,
    /// Number of file entries
    file_data_count: u32,

    /// Where strings (file & folder names, etc.) are stored (relative to `offset`)
    string_offset: u32,

    /// Size of a data block; use unknown - maybe this was used in the olden days where block padding was needed??
    block_size: u32,

    pub fn readIndex(self: SGAHeader, reader: anytype) !u32 {
        return if (self.version <= 4)
            try reader.readIntLittle(u16)
        else
            try reader.readIntLittle(u32);
    }

    pub fn readDynamicString(self: SGAHeader, reader: anytype, writer: anytype) !void {
        _ = self;

        while (true) {
            var byte = try reader.readByte();
            if (byte == 0)
                return;
            try writer.writeByte(byte);
        }
    }

    pub fn decode(reader: anytype) !SGAHeader {
        var header: SGAHeader = undefined;

        var magic: [8]u8 = undefined;
        _ = try reader.readAll(&magic);

        if (!std.mem.eql(u8, &magic, "_ARCHIVE"))
            return error.InvalidHeader;

        header.version = try reader.readIntLittle(u16);
        header.product = @intToEnum(Product, try reader.readIntLittle(u16));

        if (header.version < 4 or header.version > 10 or header.product != Product.essence)
            return error.UnsupportedVersion;

        if (header.version < 6) _ = try reader.readAll(&(header.file_md5.?));

        _ = try reader.readAll(@ptrCast(*[128]u8, &header.nice_name));

        if (header.version < 6) _ = try reader.readAll(&(header.header_md5.?));

        var nullable_1: ?u64 = if (header.version >= 9) // nullable1
            try reader.readIntLittle(u64)
        else if (header.version >= 8)
            @as(u64, try reader.readIntLittle(u32))
        else
            null;

        var header_blob_offset = try reader.readIntLittle(u32); // num1, used pretty much nowhere
        _ = header_blob_offset;
        var data_blob_offset: ?u64 = null; // nullable2, used pretty much nowhere
        header.data_offset = 0; // Used to read file data

        if (header.version >= 9) {
            header.data_offset = try reader.readIntLittle(u64);
            data_blob_offset = try reader.readIntLittle(u64);
        } else {
            header.data_offset = try reader.readIntLittle(u32);
            if (header.version >= 8)
                data_blob_offset = try reader.readIntLittle(u32);
        }

        var num2 = try reader.readIntLittle(u32); // num2, no use
        _ = num2;

        if (header.version >= 8)
            try reader.context.seekBy(256);

        header.offset = if (nullable_1) |val| val else try reader.context.getPos();
        try reader.context.seekTo(header.offset);

        header.toc_data_offset = try reader.readIntLittle(u32); // num3
        header.toc_data_count = try header.readIndex(reader); // num4
        header.folder_data_offset = try reader.readIntLittle(u32); // num5
        header.folder_data_count = try header.readIndex(reader); // num6
        header.file_data_offset = try reader.readIntLittle(u32); // num7
        header.file_data_count = try header.readIndex(reader); // num8
        header.string_offset = try reader.readIntLittle(u32); // num9

        var num10 = try header.readIndex(reader); // num10, no use
        _ = num10;

        if (header.version >= 7) {
            var num11 = try reader.readIntLittle(u32); // num11
            _ = num11;
            if (header.version >= 8) {
                var num12 = try reader.readIntLittle(u32); // num12
                _ = num12;
            }
            header.block_size = try reader.readIntLittle(u32);
        }

        return header;
    }
};

/// Seems to document sections, named based on the type of the contents (data - scripts, assets, reflect - databases, attrib - unit, map attributes),
/// I have never seen more than one per archive and it seems Essence.Core pretty much doesn't care about more than one of these per archive
/// Could also be related to game's protocols when loading files (data: - maybe there's an attrib: protocol);
/// see AoE4 logs by running the game with the `-dev` option
pub const TOCEntry = struct {
    alias: [64]u8,
    name: [64]u8,

    /// Where this section's folder data starts
    folder_start_index: u32,
    /// Where this section's folder data ends
    folder_end_index: u32,

    /// Where this section's file data starts
    file_start_index: u32,
    /// Where this section's file data starts
    file_end_index: u32,

    /// This section's root (top) folder
    folder_root_index: u32,

    pub fn decode(reader: anytype, header: SGAHeader) !TOCEntry {
        var entry: TOCEntry = undefined;

        _ = try reader.readAll(&entry.alias);
        _ = try reader.readAll(&entry.name);

        entry.folder_start_index = try header.readIndex(reader);
        entry.folder_end_index = try header.readIndex(reader);
        entry.file_start_index = try header.readIndex(reader);
        entry.file_end_index = try header.readIndex(reader);
        entry.folder_root_index = try header.readIndex(reader);

        return entry;
    }
};

pub const FolderEntry = struct {
    /// Offset of the folder's name (offset + string_offset + name_offset)
    name_offset: u32,

    // TODO: Document these; likely used to classify folders/files as parent and child based on their locations
    folder_start_index: u32,
    folder_end_index: u32,

    file_start_index: u32,
    file_end_index: u32,

    pub fn decode(reader: anytype, header: SGAHeader) !FolderEntry {
        var entry: FolderEntry = undefined;

        entry.name_offset = try reader.readIntLittle(u32);
        entry.folder_start_index = try header.readIndex(reader);
        entry.folder_end_index = try header.readIndex(reader);
        entry.file_start_index = try header.readIndex(reader);
        entry.file_end_index = try header.readIndex(reader);

        return entry;
    }
};

pub const FileVerificationType = enum(u8) {
    none,
    crc,
    crc_blocks,
    md5_blocks,
    sha1_blocks,
};

pub const FileStorageType = enum(u8) {
    /// Uncompressed
    store,
    /// Deflate stream
    stream_compress,
    /// Also deflate stream 🤷
    buffer_compress,
};

pub const FileEntry = struct {
    /// Offset of the file's name (offset + string_offset + name_offset)
    name_offset: u32,
    /// Offset of the file's data (data_offset + data_offset)
    data_offset: u64,

    /// Length in the archive as compressed
    compressed_length: u32,
    /// Length after decompression
    uncompressed_length: u32,

    /// What hashing algorithm is used to check the file's integrity
    verification_type: FileVerificationType,
    /// How the file is stored (compressed)
    storage_type: FileStorageType,

    /// CRC of the (potentially) compressed file data at data_offset; present version >= 6
    crc: ?u32 = null,
    /// Hash of the uncompressed file; present version >= 7, though in version == 7 the hash
    /// is located at the end whereas in version > 7 it's located after name_offset
    hash_offset: ?u32 = null,

    pub fn decode(reader: anytype, header: SGAHeader) !FileEntry {
        var entry: FileEntry = undefined;

        entry.name_offset = try reader.readIntLittle(u32);
        if (header.version > 7)
            entry.hash_offset = try reader.readIntLittle(u32);
        entry.data_offset = if (header.version < 9) try reader.readIntLittle(u32) else try reader.readIntLittle(u64);

        entry.compressed_length = try reader.readIntLittle(u32);
        entry.uncompressed_length = try reader.readIntLittle(u32);

        if (header.version < 10)
            _ = try reader.readIntLittle(u32); // num13 - seems to be padding?

        entry.verification_type = @intToEnum(FileVerificationType, try reader.readByte());
        entry.storage_type = @intToEnum(FileStorageType, try reader.readByte());

        if (header.version >= 6)
            entry.crc = try reader.readIntLittle(u32);
        if (header.version == 7)
            entry.hash_offset = try reader.readIntLittle(u32);

        if (entry.hash_offset != null and entry.hash_offset.? == 0)
            entry.hash_offset = null;

        return entry;
    }
};

pub fn main() !void {
    var allocator = std.heap.page_allocator;

    var file = try std.fs.cwd().openFile("ArtLow.sga", .{});
    defer file.close();

    const reader = file.reader();

    var header = try SGAHeader.decode(reader);
    std.log.info("{s}", .{header});
    std.log.info("Archive name is \"{s}\"", .{std.unicode.fmtUtf16le(header.nice_name[0..])});

    try file.seekTo(header.offset + header.toc_data_offset);

    var section_index: usize = 0;
    while (section_index < header.toc_data_count) : (section_index += 1) {
        var entry = try TOCEntry.decode(reader, header);
        std.log.info("{s}", .{entry.name});
    }

    var name_buf = std.ArrayList(u8).init(allocator);

    try file.seekTo(header.offset + header.folder_data_offset);

    var folder_index: usize = 0;
    while (folder_index < header.folder_data_count) : (folder_index += 1) {
        var entry = try FolderEntry.decode(reader, header);

        var old_pos = try reader.context.getPos();
        try reader.context.seekTo(header.offset + header.string_offset + entry.name_offset);
        try header.readDynamicString(reader, name_buf.writer());
        try reader.context.seekTo(old_pos);

        std.log.info("{s}: {s}", .{ name_buf.items, entry });
        name_buf.items.len = 0;
    }

    var file_index: usize = 0;
    while (file_index < header.file_data_count) : (file_index += 1) {
        var entry = try FileEntry.decode(reader, header);

        var old_pos = try reader.context.getPos();
        try reader.context.seekTo(header.offset + header.string_offset + entry.name_offset);
        try header.readDynamicString(reader, name_buf.writer());
        try reader.context.seekTo(old_pos);

        std.log.info("{s}: {s}", .{ name_buf.items, entry });
        name_buf.items.len = 0;
    }
}
