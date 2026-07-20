#version 450
//
// lookout chart vertex shader — flat-colour triangles (area fills, line work).
// The engine (tile57) tessellates once and hands these back in world space; a
// frame only changes the uniforms:
//   * pan/zoom              -> mvp
//   * day/night, palette    -> a different `color` per range (pushed per draw)
//   * SCAMIN / category      -> current_scale, cat_mask (pure culling)
// Nothing here re-tessellates. Colour is per-RANGE now (one draw = one colour),
// pushed in the uniform, not a per-vertex buffer.

// tile57_gpu_vertex: world(0), local(8), scamin(16), packed(20)=disp_cat|map_align<<8
layout(location = 0) in vec2  a_world;   // web-mercator [0,1], camera-relative
layout(location = 1) in vec2  a_local;   // anchor-relative reference px (0 for area/line interiors)
layout(location = 2) in float a_scamin;  // SCAMIN 1:N denominator (<=0 => always visible)
layout(location = 3) in uint  a_packed;  // low byte disp_cat, next byte map_align

layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float current_scale;
    uint  cat_mask;
    uint  _pad0;
    float rot_sin;
    float rot_cos;
    vec4  color;        // per-range flat colour (straight alpha, 0..1)
    vec2  anchor_px;    // pattern only
    vec2  cell_px;      // pattern only
} u;

layout(location = 0) out vec4 v_color;

void main() {
    uint disp_cat = a_packed & 0xFFu;
    bool map_align = ((a_packed >> 8) & 0xFFu) != 0u;

    vec4 clip = u.mvp * vec4(a_world, 0.0, 1.0);

    // line edges carry a constant-screen-size local px offset; area interiors
    // have local == 0. MAP-aligned marks turn with the chart.
    vec2 local = a_local;
    if (map_align) {
        local = vec2(local.x * u.rot_cos - local.y * u.rot_sin,
                     local.x * u.rot_sin + local.y * u.rot_cos);
    }
    clip.xy += local * u.px_to_clip * u.size_scale * clip.w;

    bool vis = (u.cat_mask & (1u << disp_cat)) != 0u;
    if (a_scamin > 0.0 && disp_cat != 0u && u.current_scale > a_scamin) vis = false;

    gl_Position = vis ? clip : vec4(0.0, 0.0, 2.0, 1.0); // z=2 -> depth-clipped
    v_color = u.color;
}
