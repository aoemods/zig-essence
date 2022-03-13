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
    /// Where toc_data_offset .. hash_length are stored
    offset: u64,
    /// Offset for raw file data
    data_offset: u64,

    /// Archive signature
    signature: [256]u8 = [_]u8{ 00, 00, 00, 00, 00, 00, 00, 00 } ** 32,

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
    /// Length of the string section
    string_length: u32,

    /// Where file hashes are stored (relative to `offset`?)
    hash_offset: ?u32 = null,
    /// Length of file hashes
    hash_length: ?u32 = null,

    /// Size of a data block; use unknown - maybe this was used in the olden days where block padding was needed??
    /// Typically 262144 (~256kb)
    block_size: ?u32 = 262144,

    pub fn readIndex(self: SGAHeader, reader: anytype) !u32 {
        return if (self.version <= 4)
            try reader.readIntLittle(u16)
        else
            try reader.readIntLittle(u32);
    }

    pub fn writeIndex(self: SGAHeader, writer: anytype, index: u32) !void {
        if (self.version <= 4)
            try writer.writeIntLittle(u16, @intCast(u16, index))
        else
            try writer.writeIntLittle(u32, index);
    }

    /// Calculate header.offset, useful for "lazy" unbroken `encode`s.
    pub fn calcOffset(self: SGAHeader) usize {
        return 8 + 2 + 2 + (if (self.version < 6) @as(usize, 32) else @as(usize, 0)) + 128 + (if (self.version >= 9)
            @as(usize, 8)
        else if (self.version >= 8)
            @as(usize, 4)
        else
            0) + 4 + (if (self.version >= 9)
            16
        else
            4 +
                (if (self.version >= 8) @as(usize, 4) else @as(usize, 0))) + 4 + (if (self.version >= 8) @as(usize, 256) else @as(usize, 0));
    }

    /// Calculate the length of the data at header.offset, useful for "lazy" unbroken `encode`s
    pub fn calcOffsetLength(self: SGAHeader) usize {
        return 16 + (if (self.version <= 4)
            @as(usize, 2)
        else
            @as(usize, 4)) * 4 + if (self.version >= 7) 8 +
            if (self.version >= 8) 4;
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

        var nullable_1: ?u64 = if (header.version >= 9) // nullable1, header offset
            try reader.readIntLittle(u64)
        else if (header.version >= 8)
            @as(u64, try reader.readIntLittle(u32))
        else
            null;

        var header_blob_offset = try reader.readIntLittle(u32); // num1, used pretty much nowhere, typically points to EoF
        _ = header_blob_offset;
        var data_blob_offset: ?u64 = null; // nullable2, used pretty much nowhere, typically points to header.offset
        header.data_offset = 0; // Used to read file data

        if (header.version >= 9) {
            header.data_offset = try reader.readIntLittle(u64);
            data_blob_offset = try reader.readIntLittle(u64);
        } else {
            header.data_offset = try reader.readIntLittle(u32);
            if (header.version >= 8)
                data_blob_offset = try reader.readIntLittle(u32);
        }

        var num2 = try reader.readIntLittle(u32); // num2, no use, typically = 1
        _ = num2;

        if (header.version >= 8)
            _ = try reader.readAll(&header.signature);

        header.offset = if (nullable_1) |val| val else try reader.context.getPos();
        try reader.context.seekTo(header.offset);

        header.toc_data_offset = try reader.readIntLittle(u32); // num3
        header.toc_data_count = try header.readIndex(reader); // num4
        header.folder_data_offset = try reader.readIntLittle(u32); // num5
        header.folder_data_count = try header.readIndex(reader); // num6
        header.file_data_offset = try reader.readIntLittle(u32); // num7
        header.file_data_count = try header.readIndex(reader); // num8
        header.string_offset = try reader.readIntLittle(u32); // num9
        header.string_length = try header.readIndex(reader); // num10

        if (header.version >= 7) {
            header.hash_offset = try reader.readIntLittle(u32); // num11
            if (header.version >= 8) {
                header.hash_length = try reader.readIntLittle(u32); // num12
            }
            header.block_size = try reader.readIntLittle(u32);
        }

        return header;
    }

    pub fn encode(self: SGAHeader, writer: anytype) !void {
        try writer.writeAll("_ARCHIVE");

        try writer.writeIntLittle(u16, self.version);
        try writer.writeIntLittle(u16, @enumToInt(self.product));

        if (self.version < 4 or self.version > 10 or self.product != Product.essence)
            return error.UnsupportedVersion;

        if (self.version < 6) try writer.writeAll(&(self.file_md5.?));

        _ = try writer.writeAll(@ptrCast(*const [128]u8, &self.nice_name));

        if (self.version < 6) _ = try writer.writeAll(&(self.header_md5.?));

        // nullable1, header offset
        if (self.version >= 9)
            try writer.writeIntLittle(u64, self.offset)
        else if (self.version >= 8)
            try writer.writeIntLittle(u32, @intCast(u32, self.offset));

        try writer.writeIntLittle(u32, 0); // num1, used pretty much nowhere, typically points to EoF
        var data_blob_offset: u64 = self.offset; // nullable2, used pretty much nowhere, typically points to header.offset

        if (self.version >= 9) {
            try writer.writeIntLittle(u64, self.data_offset);
            try writer.writeIntLittle(u64, data_blob_offset);
        } else {
            try writer.writeIntLittle(u32, @intCast(u32, self.data_offset));
            if (self.version >= 8)
                try writer.writeIntLittle(u32, @intCast(u32, data_blob_offset));
        }

        try writer.writeIntLittle(u32, 1); // num2, no use, typically = 1

        if (self.version >= 8)
            try writer.writeAll(&self.signature);

        try writer.context.seekTo(self.offset);

        try writer.writeIntLittle(u32, self.toc_data_offset); // num3
        try self.writeIndex(writer, self.toc_data_count); // num4
        try writer.writeIntLittle(u32, self.folder_data_offset); // num5
        try self.writeIndex(writer, self.folder_data_count); // num6
        try writer.writeIntLittle(u32, self.file_data_offset); // num7
        try self.writeIndex(writer, self.file_data_count); // num8
        try writer.writeIntLittle(u32, self.string_offset); // num9
        try self.writeIndex(writer, self.string_length); // num10

        if (self.version >= 7) {
            try writer.writeIntLittle(u32, self.hash_offset.?); // num11
            if (self.version >= 8) {
                try writer.writeIntLittle(u32, self.hash_length.?); // num12
            }
            try writer.writeIntLittle(u32, self.block_size.?);
        }
    }
};

/// Seems to document sections, named based on the type of the contents (data - scripts, assets, reflect - databases, attrib - unit, map attributes),
/// I have never seen more than one per archive and it seems Essence.Core pretty much doesn't care about more than one of these per archive
/// Could also be related to game's protocols when loading files (data: - maybe there's an attrib: protocol);
/// see AoE4 logs by running the game with the `-dev` option
pub const TOCEntry = struct {
    alias: [64]u8,
    name: [64]u8,

    // Folders within these indexes are children of this TOC section
    folder_start_index: u32,
    folder_end_index: u32,

    // Files within these indexes are children of this TOC section
    file_start_index: u32,
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

    pub fn encode(self: TOCEntry, writer: anytype, header: SGAHeader) !void {
        try writer.writeAll(self.alias);
        try writer.writeAll(self.name);

        try header.writeIndex(writer, self.folder_start_index);
        try header.writeIndex(writer, self.folder_end_index);
        try header.writeIndex(writer, self.file_start_index);
        try header.writeIndex(writer, self.file_end_index);
        try header.writeIndex(writer, self.folder_root_index);
    }
};

pub const FolderEntry = struct {
    /// Offset of the folder's name (offset + string_offset + name_offset)
    name_offset: u32,

    // Folders within these indexes are children of this folder
    folder_start_index: u32,
    folder_end_index: u32,

    // Files within these indexes are children of this folder
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

    pub fn encode(self: FolderEntry, writer: anytype, header: SGAHeader) !void {
        try writer.writeIntLittle(u32, self.name_offset);
        try header.writeIndex(writer, self.folder_start_index);
        try header.writeIndex(writer, self.folder_end_index);
        try header.writeIndex(writer, self.file_start_index);
        try header.writeIndex(writer, self.file_end_index);
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
    /// (offset + header.hash_offset + file.hash_offset)
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

        return entry;
    }

    pub fn encode(self: FileEntry, writer: anytype, header: SGAHeader) !void {
        try writer.writeIntLittle(u32, self.name_offset);
        if (header.version > 7)
            try writer.writeIntLittle(u32, self.hash_offset orelse 0);
        if (header.version < 9)
            try writer.writeIntLittle(u32, self.data_offset)
        else
            try writer.writeIntLittle(u64, self.data_offset);

        try writer.writeIntLittle(u32, self.compressed_length);
        try writer.writeIntLittle(u32, self.uncompressed_length);

        if (header.version < 10)
            _ = try writer.writeIntLittle(u32, 0); // num13 - seems to be padding?

        try writer.writeByte(@enumToInt(self.verification_type));
        try writer.writeByte(@enumToInt(self.storage_type));

        if (header.version >= 6)
            try writer.writeIntLittle(u32, self.crc.?);
        if (header.version == 7)
            try writer.writeIntLittle(u32, self.hash_offset orelse 0);
    }
};

const tora1 = @embedFile("samples/tora1.sga");

test "Low-level Decode" {
    var reader = std.io.fixedBufferStream(tora1).reader();

    var header = try SGAHeader.decode(reader);

    try std.testing.expectEqual(@as(u16, 10), header.version);

    var name_buf: [128]u8 = undefined;
    _ = try std.unicode.utf16leToUtf8(&name_buf, &header.nice_name);
    try std.testing.expectEqualSlices(u8, "data", name_buf[0..4]);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 0, 0, 0, 0, 0, 0, 0 } ** 32, &header.signature);

    try std.testing.expectEqual(@as(u32, 1), header.toc_data_count);
    try reader.context.seekTo(header.offset + header.toc_data_offset);

    var toc = try TOCEntry.decode(reader, header);
    try std.testing.expectEqualSlices(u8, "data", toc.name[0..4]);

    try std.testing.expectEqual(@as(u32, 2), header.folder_data_count); // data, scar
    try std.testing.expectEqual(@as(u32, 1), header.file_data_count); // somescript.scar
}

// Higher level constructs

pub const Node = union(enum) {
    toc: TOC,
    folder: Folder,
    file: File,

    pub fn getName(self: Node) []const u8 {
        return switch (self) {
            .toc => |f| f.name,
            .folder => |f| f.name,
            .file => |f| f.name,
        };
    }

    pub fn getChildren(self: Node) ?std.ArrayListUnmanaged(Node) {
        return switch (self) {
            .toc => |f| f.children,
            .folder => |f| f.children,
            .file => null,
        };
    }

    pub fn propagateParent(self: *Node, children: []Node) void {
        for (children) |*child| {
            if (child.* != .folder) {
                if (child.* == .file) {
                    std.log.info("PARENT: {s}, CHILD: {s}", .{ self.getName(), child.getName() });
                    child.file.parent = self;
                }
            } else {
                std.log.info("PARENT: {s}, CHILD: {s}", .{ self.getName(), child.getName() });
                child.folder.parent = self;
            }

            std.log.info("PARENT {s}", .{child.getParent()});
        }
    }

    pub fn printTree(self: Node, level: usize) anyerror!void {
        var l: usize = 0;
        while (l < level * 4) : (l += 1)
            try std.io.getStdOut().writer().print(" ", .{});

        var name = self.getName();
        try std.io.getStdOut().writer().print("{s}\n", .{name});

        if (self.getChildren()) |children|
            for (children.items) |child|
                try child.printTree(level + 1);
    }
};

pub const TOC = struct {
    name: []const u8,
    alt_name: []const u8,
    children: std.ArrayListUnmanaged(Node),

    header: *const SGAHeader,
    entry: *const TOCEntry,

    pub fn init(name: []const u8, alt_name: []const u8, children: std.ArrayListUnmanaged(Node), header: *const SGAHeader, entry: *const TOCEntry) TOC {
        var toc: TOC = undefined;

        toc.name = name;
        toc.alt_name = alt_name;
        toc.children = children;

        toc.header = header;
        toc.entry = entry;

        return toc;
    }
};

pub const Folder = struct {
    name: []const u8,
    children: std.ArrayListUnmanaged(Node),

    header: *const SGAHeader,
    entry: *const FolderEntry,

    pub fn init(name: []const u8, children: std.ArrayListUnmanaged(Node), header: *const SGAHeader, entry: *const FolderEntry) Folder {
        var folder: Folder = undefined;

        folder.name = name;
        folder.children = children;

        folder.header = header;
        folder.entry = entry;

        return folder;
    }
};

pub const File = struct {
    name: []const u8,

    header: *const SGAHeader,
    entry: *const FileEntry,

    pub fn init(name: []const u8, header: *const SGAHeader, entry: *const FileEntry) File {
        var file: File = undefined;

        file.name = name;

        file.header = header;
        file.entry = entry;

        return file;
    }
};

pub const Archive = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    header: SGAHeader,
    root_nodes: std.ArrayListUnmanaged(Node),

    pub fn fromFile(allocator: std.mem.Allocator, file: std.fs.File) !Archive {
        var archive: Archive = undefined;

        archive.allocator = allocator;
        archive.file = file;

        const reader = file.reader();

        var header = try SGAHeader.decode(reader);
        archive.header = header;

        // TOC
        try archive.file.seekTo(header.offset + header.toc_data_offset);

        var toc_entries = try std.ArrayList(TOCEntry).initCapacity(allocator, header.toc_data_count);
        var toc_index: usize = 0;

        while (toc_index < header.toc_data_count) : (toc_index += 1)
            try toc_entries.append(try TOCEntry.decode(reader, header));

        // Folders
        try archive.file.seekTo(header.offset + header.folder_data_offset);

        var folder_entries = try std.ArrayList(FolderEntry).initCapacity(allocator, header.folder_data_count);
        var folder_index: usize = 0;

        while (folder_index < header.folder_data_count) : (folder_index += 1)
            try folder_entries.append(try FolderEntry.decode(reader, header));

        // Files
        try archive.file.seekTo(header.offset + header.file_data_offset);

        var file_entries = try std.ArrayList(FileEntry).initCapacity(allocator, header.file_data_count);
        var file_index: usize = 0;

        while (file_index < header.file_data_count) : (file_index += 1)
            try file_entries.append(try FileEntry.decode(reader, header));

        // Make the tree
        var name_buf = std.ArrayListUnmanaged(u8){};
        // var data_buf = std.ArrayList(u8).init(allocator);

        archive.root_nodes = try std.ArrayListUnmanaged(Node).initCapacity(allocator, toc_entries.items.len);

        for (toc_entries.items) |toc| {
            var children = try createChildren(allocator, reader, &header, folder_entries, file_entries, toc.folder_root_index, toc.folder_root_index + 1, 0, 0, &name_buf);
            var toc_node = try archive.root_nodes.addOne(allocator);
            toc_node.* = Node{ .toc = TOC.init(try allocator.dupe(u8, dezero(&toc.name)), try allocator.dupe(u8, dezero(&toc.alias)), children, &header, &toc) };
        }

        return archive;
    }
};

// TODO: Fix memory management; doesn't matter much because memory is freed on exit anyways
// but it'd still be cool if this program wasn't as totally garbage as the original

// TODO: Make sga strings []const u8s, "fixed length" really means "maximum length"
pub fn dezero(str: []const u8) []const u8 {
    return std.mem.span(@ptrCast([*:0]const u8, str));
}

pub fn readDynamicString(reader: anytype, writer: anytype) !void {
    while (true) {
        var byte = try reader.readByte();
        if (byte == 0)
            return;
        try writer.writeByte(byte);
    }
}

pub fn writeDynamicString(writer: anytype, str: []const u8) !void {
    try writer.writeAll(str);
    try writer.writeByte(0);
}

fn readDynamicStringFromOffset(allocator: std.mem.Allocator, reader: anytype, name_buf: *std.ArrayListUnmanaged(u8), offset: usize) ![]u8 {
    var old_pos = try reader.context.getPos();
    try reader.context.seekTo(offset);
    name_buf.items.len = 0;

    try readDynamicString(reader, name_buf.*.writer(allocator));
    try reader.context.seekTo(old_pos);

    return allocator.dupe(u8, name_buf.items);
}

pub fn createChildren(
    allocator: std.mem.Allocator,
    //
    reader: anytype,
    header: *const SGAHeader,
    //
    folder_entries: std.ArrayList(FolderEntry),
    file_entries: std.ArrayList(FileEntry),
    //
    folder_start_index: u32,
    folder_end_index: u32,
    //
    file_start_index: u32,
    file_end_index: u32,
    //
    name_buf: *std.ArrayListUnmanaged(u8),
) anyerror!std.ArrayListUnmanaged(Node) {
    var node_list = try std.ArrayListUnmanaged(Node).initCapacity(allocator, folder_end_index - folder_start_index + file_end_index - file_start_index);
    var folder_index: usize = folder_start_index;
    while (folder_index < folder_end_index) : (folder_index += 1) {
        var name = try readDynamicStringFromOffset(allocator, reader, name_buf, header.offset + header.string_offset + folder_entries.items[folder_index].name_offset);

        var maybe_index = std.mem.lastIndexOfAny(u8, name, &[_]u8{ '/', '\\' });
        if (maybe_index) |index|
            name = name[index + 1 ..];
        var children = try createChildren(allocator, reader, header, folder_entries, file_entries, folder_entries.items[folder_index].folder_start_index, folder_entries.items[folder_index].folder_end_index, folder_entries.items[folder_index].file_start_index, folder_entries.items[folder_index].file_end_index, name_buf);
        if (name.len > 0) {
            // var folder = Folder.init(name, children, header, &folder_entries.items[folder_index]);
            // var folder_node = Node{ .folder = folder };
            // folder_node.propagateParent(children.items);
            // try node_list.append(allocator, folder_node);

            var folder = Folder.init(name, children, header, &folder_entries.items[folder_index]);
            var folder_node = try node_list.addOne(allocator);
            folder_node.* = Node{ .folder = folder };
        } else {
            try node_list.appendSlice(allocator, children.toOwnedSlice(allocator));
        }
    }

    var file_index: usize = file_start_index;
    while (file_index < file_end_index) : (file_index += 1) {
        // var file_offset = header.data_offset + file_entries.items[file_index].data_offset;
        var name = try readDynamicStringFromOffset(allocator, reader, name_buf, header.offset + header.string_offset + file_entries.items[file_index].name_offset);
        // if (name == null && this.Version < (ushort) 6)
        // {
        //   long offset = fileOffset - 260L;
        //   name = this.m_fileStream.Seek(offset, SeekOrigin.Begin) != offset ? string.Format("File_{0}.dat", (object) index) : this.ReadFixedString(reader, 256, 1);
        // } TODO: handle this nasty case
        try node_list.append(allocator, Node{ .file = File.init(name, header, &file_entries.items[file_index]) });
    }
    return node_list;
}
