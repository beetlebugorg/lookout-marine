#version 450
// Textured-quad vertex shader for sprite symbols and SDF text — the engine
// (tile57) emits these quads against the sprite / glyph atlas the host uploads.
// Same anchor + screen-space local-px model as chart.vert (constant screen
// size), plus a UV into the atlas. One quad per symbol / glyph.

// tile57_gpu_quad: world(0), local(8), uv(16), color(24, ubyte4), weight(28),
//                  scamin(32), packed(36)=disp_cat | map_align<<8 |
//                                          flip<<16 | tangent_q<<24
layout(location = 0) in vec2  a_world;
layout(location = 1) in vec2  a_local;
layout(location = 2) in vec2  a_uv;
layout(location = 3) in vec4  a_color;   // sprite: white; text: glyph colour
layout(location = 4) in float a_weight;  // SDF stroke weight (0 for sprites)
layout(location = 5) in float a_scamin;
layout(location = 6) in uint  a_packed;  // disp_cat|map_align|flip|tangent_q

layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float current_scale;
    uint  cat_mask;
    float wrap_x;   // camera center world-x: wrap each vertex to the NEAR world instance
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
    bool flip      = ((a_packed >> 16) & 0xFFu) != 0u;
    float tangent  = float((a_packed >> 24) & 0xFFu) / 256.0 * 6.2831853071795864;

    // Longitude is cyclic: draw this vertex at the world instance nearest the
    // camera (x, x-1 or x+1), so a view straddling the antimeridian is seamless.
    vec2 world = vec2(a_world.x + round(u.wrap_x - a_world.x), a_world.y);
    vec4 clip = u.mvp * vec4(world, 0.0, 1.0);
    vec2 local = a_local;
    // Keep a tangent-rotated run (a depth-contour value) upright: if the run,
    // once the view rotation is added, would read into the screen's left
    // half-plane, turn it 180° about the anchor. cos(tangent + view_rotation) =
    // cos·rot_cos − sin·rot_sin (rot_{sin,cos} are the view rotation's).
    if (flip && (cos(tangent) * u.rot_cos - sin(tangent) * u.rot_sin) < 0.0) {
        local = -local;
    }
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
