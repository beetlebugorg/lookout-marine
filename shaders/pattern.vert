#version 450
// Area FILL PATTERN (S-52 AP(...)): the tessellated polygon interior, in world
// space, same tile57_gpu_vertex as chart.vert. The tiling is done per-fragment
// (pattern.frag) so the cell keeps a constant screen size and, crucially, stays
// ANCHORED TO THE CHART (world) under a pan instead of swimming with the screen.
// This shader only projects + gates the interior; it forwards the world-anchor
// and cell period the fragment needs.
layout(location = 0) in vec2  a_world;
layout(location = 1) in vec2  a_local;
layout(location = 2) in float a_scamin;
layout(location = 3) in uint  a_packed;

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
    vec2  anchor_px;   // framebuffer-px position of the scene's world origin
    vec2  cell_px;     // cell period in framebuffer px (constant screen size)
} u;

layout(location = 0) out vec2 v_anchor;
layout(location = 1) out vec2 v_cell;

void main() {
    uint disp_cat = a_packed & 0xFFu;
    // Longitude is cyclic: draw this vertex at the world instance nearest the
    // camera (x, x-1 or x+1), so a view straddling the antimeridian is seamless.
    vec2 world = vec2(a_world.x + round(u.wrap_x - a_world.x), a_world.y);
    vec4 clip = u.mvp * vec4(world, 0.0, 1.0);
    bool vis = (u.cat_mask & (1u << disp_cat)) != 0u;
    if (a_scamin > 0.0 && disp_cat != 0u && u.current_scale > a_scamin) vis = false;
    gl_Position = vis ? clip : vec4(0.0, 0.0, 2.0, 1.0);
    v_anchor = u.anchor_px;
    v_cell = u.cell_px;
}
