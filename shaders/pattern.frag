#version 450
// Tile ONE pattern cell across the polygon at a constant screen size, anchored
// to the CHART. The cell is its own texture (tile57 hands one per pattern), so
// the tile coordinate maps straight to [0,1] with no atlas sub-rect.
//
// Phase = (fragment - world-origin) / cell, both in framebuffer px. Because a
// pan shifts the fragment's framebuffer position and the world origin's by the
// same amount, their difference is invariant — the pattern is fixed to the
// chart, not the screen, so it does not swim. The size stays constant because
// the period is expressed in screen px.
layout(location = 0) in vec2 v_anchor; // framebuffer px of the world origin
layout(location = 1) in vec2 v_cell;   // cell period, framebuffer px

layout(set = 2, binding = 0) uniform sampler2D cell;

layout(location = 0) out vec4 frag;

void main() {
    vec2 sz = max(v_cell, vec2(1.0));
    vec2 uv = fract((gl_FragCoord.xy - v_anchor) / sz);
    vec4 c = texture(cell, uv);
    if (c.a < 0.02) discard; // pattern cells are mostly transparent
    frag = c;
}
