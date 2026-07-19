#version 450
// Tile the pattern cell across the polygon in SCREEN space: wrap the fragment's
// framebuffer position into [0,1) at the cell's screen size, then map that into
// the cell's rect in the shared sprite atlas. Wrapping happens here rather than
// via a repeat sampler because the cell is a sub-rect of an atlas, where
// hardware repeat would bleed into neighbouring symbols.
layout(location = 0) in vec4 v_cell;
layout(location = 1) in vec2 v_cellpx;

layout(set = 2, binding = 0) uniform sampler2D atlas;

layout(location = 0) out vec4 frag;

void main() {
    vec2 sz = max(v_cellpx, vec2(1.0));
    vec2 t = fract(gl_FragCoord.xy / sz);
    vec2 uv = mix(v_cell.xy, v_cell.zw, t);
    vec4 c = texture(atlas, uv);
    if (c.a < 0.02) discard; // pattern cells are mostly transparent
    frag = c;
}
