//! The world coastline the app carries inside itself.
//!
//! With no chart open, or outside chart coverage, the window would otherwise
//! be empty. This renders GSHHG land and lakes under whatever chart there is, at
//! a scale that says where you are and nothing more.
//!
//! It is deliberately NOT S-52: flat greys, no depth shading, no aids, no
//! labels. A mariner must never mistake it for coverage. See
//! vendor/gshhg/README.md for the data and its licence.

const std = @import("std");
const ct = @import("charttable");
const cc = @import("c.zig").c;

/// The style source name, and the archive's source-layer names.
pub const source_name = "basemap";

/// The archive stops here; charttable overzooms past it. Must match the
/// MAX_ZOOM tools/basemap.zig baked, or the map asks for tiles that can only
/// be answered "no tile there".
pub const max_zoom: u8 = 5;

/// The baked tiles, in the binary. `zig build basemap` regenerates them.
const archive: []const u8 = @embedFile("basemap_pmtiles");

/// One bound archive. Self-referential (`src` points at `reader`), so it is
/// heap-allocated and never moved, exactly like the single-chart path.
pub const Basemap = struct {
    reader: ct.pmtiles.Reader,
    src: ct.cache.PmtilesSource,

    pub fn create(alloc: std.mem.Allocator) !*Basemap {
        const self = try alloc.create(Basemap);
        errdefer alloc.destroy(self);
        self.reader = try ct.pmtiles.Reader.init(alloc, archive);
        self.src = .{ .reader = &self.reader };
        return self;
    }

    pub fn destroy(self: *Basemap, alloc: std.mem.Allocator) void {
        self.reader.deinit();
        alloc.destroy(self);
    }
};

/// The three tones the basemap renders in, per colour scheme. Night keeps the
/// land dark: a bright landmass in a dark wheelhouse costs the night vision
/// the whole palette exists to protect.
const Tones = struct {
    land: []const u8,
    lake: []const u8,
    coast: []const u8,
};

fn tones(scheme: cc.tile57_scheme) Tones {
    return switch (scheme) {
        cc.TILE57_SCHEME_NIGHT => .{ .land = "#2a2b2d", .lake = "#15181c", .coast = "#4a4d52" },
        cc.TILE57_SCHEME_DUSK => .{ .land = "#6f6e6b", .lake = "#3d444b", .coast = "#8b8f95" },
        else => .{ .land = "#d8d5cf", .lake = "#e8edf0", .coast = "#9aa0a6" },
    };
}

/// The `"sources"` entry, ready to splice. Trailing comma: it rides in front
/// of the sources already there.
pub fn sourceJson(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "\"{s}\":{{\"type\":\"vector\",\"tiles\":[\"{s}/{{z}}/{{x}}/{{y}}\"]," ++
            "\"minzoom\":0,\"maxzoom\":{d}}},",
        .{ source_name, source_name, max_zoom },
    );
}

/// The layers, ready to splice above the style's background and below every
/// chart layer. Trailing comma, for the same reason.
pub fn layersJson(alloc: std.mem.Allocator, scheme: cc.tile57_scheme) ![]u8 {
    const t = tones(scheme);
    return std.fmt.allocPrint(
        alloc,
        "{{\"id\":\"basemap-land\",\"type\":\"fill\",\"source\":\"{s}\",\"source-layer\":\"land\"," ++
            "\"paint\":{{\"fill-color\":\"{s}\"}}}}," ++
            "{{\"id\":\"basemap-lake\",\"type\":\"fill\",\"source\":\"{s}\",\"source-layer\":\"lake\"," ++
            "\"paint\":{{\"fill-color\":\"{s}\"}}}}," ++
            "{{\"id\":\"basemap-coast\",\"type\":\"line\",\"source\":\"{s}\",\"source-layer\":\"coast\"," ++
            "\"paint\":{{\"line-color\":\"{s}\",\"line-width\":0.8}}}},",
        .{ source_name, t.land, source_name, t.lake, source_name, t.coast },
    );
}
