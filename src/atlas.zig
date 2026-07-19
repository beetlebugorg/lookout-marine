//! Portrayal atlases from tile57: the sprite-symbol atlas (tile57_bake_sprite_mln)
//! and, later, the SDF glyph atlas (tile57_bake_glyph_sdf). Decodes the PNG the
//! engine emits (via stb_image) into RGBA and parses the cell/glyph JSON. The
//! decoded pixels are uploaded once to a GPU texture; symbols/text then draw as
//! textured quads instead of tessellated outlines.
const std = @import("std");
const cc = @import("c.zig").c;

pub const Cell = struct { x: f32, y: f32, w: f32, h: f32 }; // atlas pixels

pub const SpriteAtlas = struct {
    pixels: [*c]u8, // RGBA8, stb-allocated
    width: u32,
    height: u32,
    cells: std.StringHashMapUnmanaged(Cell),
    parsed: std.json.Parsed(std.json.Value), // keeps the cell-name strings alive
    alloc: std.mem.Allocator,

    pub fn deinit(self: *SpriteAtlas) void {
        cc.stbi_image_free(self.pixels);
        self.cells.deinit(self.alloc);
        self.parsed.deinit();
    }

    pub fn rgba(self: *const SpriteAtlas) []const u8 {
        return self.pixels[0 .. self.width * self.height * 4];
    }
    pub fn lookup(self: *const SpriteAtlas, name: []const u8) ?Cell {
        return self.cells.get(name);
    }
};

fn jnum(v: std.json.Value) f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => 0,
    };
}

/// Decode a MapLibre sprite atlas: `png_bytes` (RGBA PNG) + `json_bytes`
/// ({name:{x,y,width,height,pixelRatio}}).
pub fn loadSprite(alloc: std.mem.Allocator, png_bytes: []const u8, json_bytes: []const u8) !SpriteAtlas {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = cc.stbi_load_from_memory(png_bytes.ptr, @intCast(png_bytes.len), &w, &h, &comp, 4);
    if (px == null or w <= 0 or h <= 0) return error.AtlasDecodeFailed;
    errdefer cc.stbi_image_free(px);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    var cells: std.StringHashMapUnmanaged(Cell) = .empty;
    errdefer cells.deinit(alloc);
    if (parsed.value == .object) {
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) continue;
            const o = e.value_ptr.object;
            try cells.put(alloc, e.key_ptr.*, .{
                .x = jnum(o.get("x") orelse continue),
                .y = jnum(o.get("y") orelse continue),
                .w = jnum(o.get("width") orelse continue),
                .h = jnum(o.get("height") orelse continue),
            });
        }
    }
    return .{
        .pixels = px,
        .width = @intCast(w),
        .height = @intCast(h),
        .cells = cells,
        .parsed = parsed,
        .alloc = alloc,
    };
}
