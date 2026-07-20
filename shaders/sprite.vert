#version 450
// Textured-quad vertex shader for sprite symbols and SDF text — the engine
// (tile57) emits these quads against the sprite / glyph atlas the host uploads.
// Same anchor + screen-space local-px model as chart.vert (constant screen
// size), plus a UV into the atlas. One quad per symbol / glyph.

// tile57_gpu_quad: world(0), local(8), uv(16), color(24, ubyte4), weight(28),
//                  scamin(32), packed(36)=disp_cat|map_align<<8
layout(location = 0) in vec2  a_world;
layout(location = 1) in vec2  a_local;
layout(location = 2) in vec2  a_uv;
layout(location = 3) in vec4  a_color;   // sprite: white; text: glyph colour
layout(location = 4) in float a_weight;  // SDF stroke weight (0 for sprites)
layout(location = 5) in float a_scamin;
layout(location = 6) in uint  a_packed;  // low byte disp_cat, next byte map_align

layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float current_scale;
    uint  cat_mask;
    uint  _pad0;
    float rot_sin;
    float rot_cos;
    vec4  color;
    vec2  anchor_px;
    vec2  cell_px;
} u;

layout(location = 0) out vec2  v_uv;
layout(location = 1) out vec4  v_color;
layout(location = 2) out float v_weight;

void main() {
    uint disp_cat = a_packed & 0xFFu;
    bool map_align = ((a_packed >> 8) & 0xFFu) != 0u;

    vec4 clip = u.mvp * vec4(a_world, 0.0, 1.0);
    vec2 local = a_local;
    if (map_align) {
        local = vec2(local.x * u.rot_cos - local.y * u.rot_sin,
                     local.x * u.rot_sin + local.y * u.rot_cos);
    }
    clip.xy += local * u.px_to_clip * u.size_scale * clip.w;

    // A symbol/label carries its feature's SCAMIN and category so an over-zoomed
    // view thins them live, exactly as the fills gate — the engine emits every
    // one and lets the host cull, avoiding a rebuild per zoom.
    bool vis = (u.cat_mask & (1u << disp_cat)) != 0u;
    if (a_scamin > 0.0 && disp_cat != 0u && u.current_scale > a_scamin) vis = false;

    gl_Position = vis ? clip : vec4(0.0, 0.0, 2.0, 1.0);
    v_uv = a_uv;
    v_color = a_color;
    v_weight = a_weight;
}
