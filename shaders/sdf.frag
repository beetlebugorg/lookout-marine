#version 450
// SDF text: sample the signed-distance field (.r), antialias with the screen-space
// derivative so text stays crisp at any zoom. Tinted by the glyph color.
//
// The label tier draws bold/italic from their OWN atlas (real bold/italic shapes),
// so this shader no longer emboldens. `v_weight` is now the HALO width (SDF field
// units, 0 = none): the bold and italic name tiers carry a small value so a subtle
// white outline lifts them off busy soundings; every other label passes 0.
layout(set = 2, binding = 0) uniform sampler2D atlas;
layout(location = 0) in  vec2 v_uv;
layout(location = 1) in  vec4 v_color;
layout(location = 2) in  float v_weight; // halo width (0 = no halo)
layout(location = 0) out vec4 o_color;

void main() {
    float d = texture(atlas, v_uv).r;
    float w = fwidth(d);
    float a = smoothstep(0.5 - w, 0.5 + w, d);
    if (v_weight > 0.0) {
        // Subtle white halo behind the glyph: a wider field threshold, composited
        // under the glyph colour, just enough to keep a name legible over soundings.
        float halo_a = smoothstep(0.5 - v_weight - w, 0.5 - v_weight + w, d);
        float cov = max(a, halo_a);
        if (cov <= 0.0) discard;
        vec3 col = mix(vec3(1.0), v_color.rgb, a); // white halo, glyph colour inside
        o_color = vec4(col, cov * v_color.a);
        return;
    }
    if (a <= 0.0) discard;
    o_color = vec4(v_color.rgb, v_color.a * a);
}
