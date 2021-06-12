const std = @import("std");
// const math = @import("math");

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

pub const Pages = struct {
    names: std.ArrayList([]u8),
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
    pages: Pages,
    chars: []TextChar,
    kerning_pairs: []KerningPair,

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.info.font_name);
        for (self.pages.names.items) |name| {
            self.allocator.free(name);
        }
        self.pages.names.deinit();
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

// TODO change this to use a stream
// TODO provice loadFromPath, loadFromAbsolutePath as alternate methods for convenience
pub fn load(filepath: []const u8, allocator: *std.mem.Allocator) !FontInfo {
    // var file = try std.fs.openFileAbsolute(filepath, .{
    var file = try std.fs.cwd().openFile(filepath, .{
        .read = true,
    });
    defer file.close();

    var data = try file.readToEndAlloc(allocator, 4 * 1024 * 1024); // max size 4 MB
    defer allocator.free(data);

    var stream = std.io.fixedBufferStream(data);

    // header and version checks
    {
        var header = [_]u8{0} ** 3;
        _ = try stream.read(header[0..]);
        if (std.mem.eql(u8, header[0..], "BMF"[0..2])) {
            return LoadError.BadHeader;
        }

        const version = try stream.reader().readByte();
        if (version != 3) {
            std.debug.print("bmfont load expected version 3, got version {}\n", .{version});
            return LoadError.IncompatibleVersion;
        }
    }

    var tag: BlockTag = @intToEnum(BlockTag, try stream.reader().readByte());
    if (tag != .Info) {
        return LoadError.UnexpectedBlock;
    }
    _ = try stream.reader().readIntNative(i32); // skip block size

    const k_maxFontNameLength = 256;
    const text_info = TextInfo{
        .font_size = try stream.reader().readIntNative(i16),
        .flags = try stream.reader().readIntNative(u8),
        .charset = try stream.reader().readIntNative(u8),
        .stretch_h = try stream.reader().readIntNative(u16),
        .aa = try stream.reader().readIntNative(u8),
        .padding_up = try stream.reader().readIntNative(u8),
        .padding_right = try stream.reader().readIntNative(u8),
        .padding_down = try stream.reader().readIntNative(u8),
        .padding_left = try stream.reader().readIntNative(u8),
        .spacing_horiz = try stream.reader().readIntNative(u8),
        .spacing_vert = try stream.reader().readIntNative(u8),
        .outline = try stream.reader().readIntNative(u8),
        .font_name = try stream.reader().readUntilDelimiterAlloc(allocator, 0, k_maxFontNameLength),
    };
    errdefer allocator.free(text_info.font_name);

    tag = @intToEnum(BlockTag, try stream.reader().readByte());
    if (tag != .Common) {
        return LoadError.UnexpectedBlock;
    }
    _ = try stream.reader().readIntNative(i32); // skip block size

    const text_common = TextCommon{
        .line_height = try stream.reader().readIntNative(u16),
        .base = try stream.reader().readIntNative(u16),
        .scale_w = try stream.reader().readIntNative(u16),
        .scale_h = try stream.reader().readIntNative(u16),
        .pages = try stream.reader().readIntNative(u16),
        .flags = try stream.reader().readIntNative(u8),
        .alpha = try stream.reader().readIntNative(u8),
        .red = try stream.reader().readIntNative(u8),
        .green = try stream.reader().readIntNative(u8),
        .blue = try stream.reader().readIntNative(u8),
    };

    tag = @intToEnum(BlockTag, try stream.reader().readByte());
    if (tag != .Pages) {
        return LoadError.UnexpectedBlock;
    }

    var pages = Pages{ .names = std.ArrayList([]u8).init(allocator) };
    errdefer {
        for (pages.names.items) |s| {
            allocator.free(s);
        }
        pages.names.deinit();
    }

    {
        const block_size = try stream.reader().readIntNative(i32); // skip block size
        var remaining: usize = @intCast(usize, block_size);

        while (remaining > 0) {
            var s: []u8 = try stream.reader().readUntilDelimiterAlloc(allocator, 0, k_maxFontNameLength);
            remaining -= s.len + 1;
            try pages.names.append(s);
        }
    }

    tag = @intToEnum(BlockTag, try stream.reader().readByte());
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
        var block_size = try stream.reader().readIntNative(i32); // skip block size
        const struct_size = @sizeOf(TextChar);
        comptime {
            std.debug.assert(@sizeOf(TextChar) == 20);
        }
        var count: usize = @divExact(@intCast(usize, block_size), struct_size);

        chars = try allocator.alloc(TextChar, count);

        try stream.reader().readNoEof(std.mem.sliceAsBytes(chars.?));
    }

    var kerning_pairs: ?[]KerningPair = null;
    errdefer {
        if (kerning_pairs != null) {
            allocator.free(kerning_pairs.?);
        }
    }

    tag = @intToEnum(BlockTag, stream.reader().readByte() catch 0);
    if (tag == .KerningPairs) {
        var block_size = try stream.reader().readIntNative(i32); // skip block size
        const struct_size = @sizeOf(KerningPair);
        comptime {
            std.debug.assert(@sizeOf(KerningPair) == 10);
        }
        var count: usize = @divExact(@intCast(usize, block_size), struct_size);

        kerning_pairs = try allocator.alloc(KerningPair, count);

        try stream.reader().readNoEof(std.mem.sliceAsBytes(kerning_pairs.?));
    }

    if (kerning_pairs == null) {
        kerning_pairs = try allocator.alloc(KerningPair, 0);
    }

    return FontInfo{
        .allocator = allocator,
        .info = text_info,
        .common = text_common,
        .pages = pages,
        .chars = chars.?,
        .kerning_pairs = kerning_pairs.?,
    };
}

test "single page no kerning" {
    var allocator = std.testing.allocator;
    var info: FontInfo = try load("test/consolas.fnt", allocator);
    defer info.deinit();
}

test "multi page with kerning" {
    var allocator = std.testing.allocator;
    var info: FontInfo = try load("test/dejavu.fnt", allocator);
    defer info.deinit();
}
