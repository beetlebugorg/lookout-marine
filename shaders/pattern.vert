#version 450
// Area FILL PATTERN (S-52 AP(...)): tessellated polygon geometry in world space,
// textured with a pattern cell tiled at a CONSTANT SCREEN SIZE. Unlike sprites
// there is no anchor/local-px model — the triangles are the polygon itself; the
// tiling is derived per fragment from screen position, so the pattern does not
// swim when the camera pans or zooms between tile rebuilds.
layout(location = 0) in vec2 a_world;  // web-mercator [0,1], camera-relative
layout(location = 1) in vec4 a_cell;   // atlas cell rect (u0,v0,u1,v1), normalized
layout(location = 2) in vec2 a_cellpx; // cell size in PHYSICAL px (density folded in)

layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float current_scale;
    uint  cat_mask;
    uint  kind_mask;
    float rot_sin;
    float rot_cos;
} u;

layout(location = 0) out vec4 v_cell;
layout(location = 1) out vec2 v_cellpx;

void main() {
    gl_Position = u.mvp * vec4(a_world, 0.0, 1.0);
    v_cell = a_cell;
    v_cellpx = a_cellpx * u.size_scale;
}
