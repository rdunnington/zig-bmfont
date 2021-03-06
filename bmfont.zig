const std = @import("std");
const expect = std.testing.expect;

pub const TextInfo = struct {
    font_size: i16,
    flags: u8,
    charset: u8,
    stretch_h: u16,
    aa: u8,
    padding_up: u8,
    padding_right: u8,
    padding_down: u8,
    padding_left: u8,
    spacing_horiz: u8,
    spacing_vert: u8,
    outline: u8,
    font_name: []u8,
};

pub const TextCommon = struct {
    line_height: u16,
    base: u16,
    scale_w: u16,
    scale_h: u16,
    pages: u16,
    flags: u8,
    alpha: u8,
    red: u8,
    green: u8,
    blue: u8,
};

pub const TextChar = packed struct {
    id: u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    offset_x: i16,
    offset_y: i16,
    xadvance: i16,
    page: u8,
    channel: u8,
};

pub const KerningPair = packed struct {
    first: u32,
    second: u32,
    amount: i16,
};

pub const FontInfo = struct {
    allocator: *std.mem.Allocator,
    info: TextInfo,
    common: TextCommon,
    pages: [][]u8,
    chars: []TextChar,
    kerning_pairs: []KerningPair,

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.info.font_name);
        for (self.pages) |s| {
            self.allocator.free(s);
        }
        self.allocator.free(self.pages);
        self.allocator.free(self.chars);
        self.allocator.free(self.kerning_pairs);
    }
};

pub const LoadError = error{
    NotFound,
    BadHeader,
    IncompatibleVersion,
    UnexpectedBlock,
};

const BlockTag = enum(u8) {
    None,
    Info,
    Common,
    Pages,
    Chars,
    KerningPairs,
};

pub fn loadBinaryFromPath(filepath: []const u8, allocator: *std.mem.Allocator) !FontInfo {
    var file = try std.fs.cwd().openFile(filepath, .{
        .read = true,
    });
    defer file.close();

    var data = try file.readToEndAlloc(allocator, 4 * 1024 * 1024); // max size 4 MB
    defer allocator.free(data);

    var stream = std.io.fixedBufferStream(data);
    return loadBinary(stream.reader(), allocator);
}

pub fn loadBinary(stream: anytype, allocator: *std.mem.Allocator) !FontInfo {
    {
        var header = [_]u8{0} ** 3;
        _ = try stream.read(header[0..]);
        if (std.mem.eql(u8, header[0..], "BMF"[0..2])) {
            return LoadError.BadHeader;
        }

        const version = try stream.readByte();
        if (version != 3) {
            std.debug.print("bmfont load expected version 3, got version {}\n", .{version});
            return LoadError.IncompatibleVersion;
        }
    }

    var tag: BlockTag = @intToEnum(BlockTag, try stream.readByte());
    if (tag != .Info) {
        return LoadError.UnexpectedBlock;
    }
    _ = try stream.readIntNative(i32); // skip block size

    const k_maxFontNameLength = 256;
    const text_info = TextInfo{
        .font_size = try stream.readIntNative(i16),
        .flags = try stream.readIntNative(u8),
        .charset = try stream.readIntNative(u8),
        .stretch_h = try stream.readIntNative(u16),
        .aa = try stream.readIntNative(u8),
        .padding_up = try stream.readIntNative(u8),
        .padding_right = try stream.readIntNative(u8),
        .padding_down = try stream.readIntNative(u8),
        .padding_left = try stream.readIntNative(u8),
        .spacing_horiz = try stream.readIntNative(u8),
        .spacing_vert = try stream.readIntNative(u8),
        .outline = try stream.readIntNative(u8),
        .font_name = try stream.readUntilDelimiterAlloc(allocator, 0, k_maxFontNameLength),
    };
    errdefer allocator.free(text_info.font_name);

    tag = @intToEnum(BlockTag, try stream.readByte());
    if (tag != .Common) {
        return LoadError.UnexpectedBlock;
    }
    _ = try stream.readIntNative(i32); // skip block size

    const text_common = TextCommon{
        .line_height = try stream.readIntNative(u16),
        .base = try stream.readIntNative(u16),
        .scale_w = try stream.readIntNative(u16),
        .scale_h = try stream.readIntNative(u16),
        .pages = try stream.readIntNative(u16),
        .flags = try stream.readIntNative(u8),
        .alpha = try stream.readIntNative(u8),
        .red = try stream.readIntNative(u8),
        .green = try stream.readIntNative(u8),
        .blue = try stream.readIntNative(u8),
    };

    tag = @intToEnum(BlockTag, try stream.readByte());
    if (tag != .Pages) {
        return LoadError.UnexpectedBlock;
    }

    var pages: ?[][]u8 = null;
    errdefer {
        if (pages != null) {
            for (pages.?) |s| {
                allocator.free(s);
            }
            allocator.free(pages.?);
        }
    }

    {
        const block_size = try stream.readIntNative(i32); // skip block size
        var remaining: usize = @intCast(usize, block_size);

        var strings = std.ArrayList([]u8).init(allocator);

        while (remaining > 0) {
            var s: []u8 = try stream.readUntilDelimiterAlloc(allocator, 0, k_maxFontNameLength);
            remaining -= s.len + 1;
            try strings.append(s);
        }
        pages = strings.toOwnedSlice();
    }

    tag = @intToEnum(BlockTag, try stream.readByte());
    if (tag != .Chars) {
        return LoadError.UnexpectedBlock;
    }

    var chars: ?[]TextChar = null;
    errdefer {
        if (chars != null) {
            allocator.free(chars.?);
        }
    }

    {
        var block_size = try stream.readIntNative(i32); // skip block size
        const struct_size = @sizeOf(TextChar);
        comptime {
            std.debug.assert(@sizeOf(TextChar) == 20);
        }
        var count: usize = @divExact(@intCast(usize, block_size), struct_size);

        chars = try allocator.alloc(TextChar, count);

        try stream.readNoEof(std.mem.sliceAsBytes(chars.?));
    }

    var kerning_pairs: ?[]KerningPair = null;
    errdefer {
        if (kerning_pairs != null) {
            allocator.free(kerning_pairs.?);
        }
    }

    tag = @intToEnum(BlockTag, stream.readByte() catch 0);
    if (tag == .KerningPairs) {
        var block_size = try stream.readIntNative(i32); // skip block size
        const struct_size = @sizeOf(KerningPair);
        comptime {
            std.debug.assert(@sizeOf(KerningPair) == 10);
        }
        var count: usize = @divExact(@intCast(usize, block_size), struct_size);

        kerning_pairs = try allocator.alloc(KerningPair, count);

        try stream.readNoEof(std.mem.sliceAsBytes(kerning_pairs.?));
    }

    if (kerning_pairs == null) {
        kerning_pairs = try allocator.alloc(KerningPair, 0);
    }

    return FontInfo{
        .allocator = allocator,
        .info = text_info,
        .common = text_common,
        .pages = pages.?,
        .chars = chars.?,
        .kerning_pairs = kerning_pairs.?,
    };
}

test "single page no kerning" {
    var allocator = std.testing.allocator;
    var info: FontInfo = try loadBinaryFromPath("test/consolas.fnt", allocator);
    defer info.deinit();

    try expect(std.mem.eql(u8, info.info.font_name, "Consolas"));
    try expect(std.mem.eql(u8, info.pages[0], "consolas_0.png"));
}

test "multi page with kerning" {
    var allocator = std.testing.allocator;
    var info: FontInfo = try loadBinaryFromPath("test/dejavu.fnt", allocator);
    defer info.deinit();

    try expect(std.mem.eql(u8, info.info.font_name, "DejaVu Sans"));
    try expect(std.mem.eql(u8, info.pages[0], "dejavu_0.png"));
    try expect(std.mem.eql(u8, info.pages[1], "dejavu_1.png"));
    try expect(std.mem.eql(u8, info.pages[2], "dejavu_2.png"));
    try expect(std.mem.eql(u8, info.pages[3], "dejavu_3.png"));
    try expect(std.mem.eql(u8, info.pages[4], "dejavu_4.png"));
}
