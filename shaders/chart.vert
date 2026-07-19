#version 450
//
// lookout chart vertex shader — the whole "tessellate once, transform per frame"
// contract lives here. Geometry is uploaded ONCE in web-mercator space (camera-
// relative f32); every frame only the uniforms below change:
//   * pan/zoom            -> mvp
//   * day/night           -> a different color vertex buffer bound to slot 1
//   * SCAMIN / category /  -> current_scale, cat_mask, kind_mask (pure culling)
//     text / soundings
// Nothing here re-tessellates.

// slot 0: geometry (shared across all palettes)
layout(location = 0) in vec2  a_world;   // web-mercator [0,1], camera-relative (origin pre-subtracted)
layout(location = 1) in vec2  a_local;   // anchor-relative reference px (0 for area/line verts)
layout(location = 2) in float a_scamin;  // SCAMIN 1:N denominator (<=0 => always visible)
layout(location = 3) in uint  a_flags;   // bits 0..1 disp_cat, bits 2..4 kind, bit 5 align(map)
// slot 1: per-scheme resolved color (swapped on day/night; geometry untouched)
layout(location = 4) in vec4  a_color;

// SDL_GPU Vulkan convention: vertex uniform buffers live in descriptor set 1.
layout(set = 1, binding = 0) uniform U {
    mat4  mvp;             // world-relative -> clip
    vec2  px_to_clip;      // (2/vw, -2/vh): reference px -> clip-space delta
    float size_scale;      // icon/line/text physical multiplier
    float current_scale;   // current view display-scale denominator (for SCAMIN)
    uint  cat_mask;        // bit i set => disp_cat i visible
    uint  kind_mask;       // bit k set => kind k visible (text/soundings toggles)
    float rot_sin;         // view rotation (for align==MAP marks); 0 at north-up
    float rot_cos;
} u;

layout(location = 0) out vec4 v_color;

const uint KIND_AREA = 0u, KIND_LINE = 1u, KIND_SYMBOL = 2u, KIND_SOUNDING = 3u, KIND_TEXT = 4u;

void main() {
    uint disp_cat = a_flags & 3u;
    uint kind     = (a_flags >> 2) & 7u;
    bool map_align = ((a_flags >> 5) & 1u) != 0u;

    // world position (ortho => w == 1)
    vec4 clip = u.mvp * vec4(a_world, 0.0, 1.0);

    // anchored marks: add a constant-screen-size local px offset (optionally
    // rotated with the chart for MAP-aligned marks). local is 0 for area/line.
    vec2 local = a_local;
    if (map_align) {
        local = vec2(local.x * u.rot_cos - local.y * u.rot_sin,
                     local.x * u.rot_sin + local.y * u.rot_cos);
    }
    clip.xy += local * u.px_to_clip * u.size_scale * clip.w;

    // ---- live gates: cull by pushing the whole (per-feature) triangle off-clip ----
    bool vis = (u.cat_mask & (1u << disp_cat)) != 0u
            && (u.kind_mask & (1u << kind)) != 0u;
    // SCAMIN: hide when the view is COARSER than the feature's min display scale.
    // disp_cat BASE (0) is never SCAMIN-gated (S-52 display base = never hide).
    if (a_scamin > 0.0 && disp_cat != 0u && u.current_scale > a_scamin) vis = false;

    if (!vis) { gl_Position = vec4(0.0, 0.0, 2.0, 1.0); }  // z=2 -> depth-clipped, invisible
    else      { gl_Position = clip; }

    v_color = a_color;
}
