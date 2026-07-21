#version 450
// SDF text: sample the signed-distance field (.r), antialias with the screen-space
// derivative so text stays crisp at any zoom. Tinted by the glyph color.
layout(set = 2, binding = 0) uniform sampler2D atlas;
layout(location = 0) in  vec2 v_uv;
layout(location = 1) in  vec4 v_color;
layout(location = 2) in  float v_weight; // >0 embolden + white halo (bold place-name tier)
layout(location = 0) out vec4 o_color;

// White-halo width for the bold tier, in SDF field units. The field spans ~0.5
// over the atlas pad, so ~0.14 is roughly a 1.5 px outline that scales with the
// text size. The halo colour is white — matched to the day palette's black text;
// a dark palette would want the halo colour passed through instead.
const float HALO = 0.30;

void main() {
    float d = texture(atlas, v_uv).r;
    float w = fwidth(d);
    // Emboldening is a threshold shift: accepting a little more of the field
    // grows the glyph outward by roughly v_weight of an em, which is what a
    // real bold weight does to the stem without needing a second atlas.
    float edge = 0.5 - v_weight;
    float a = smoothstep(edge - w, edge + w, d);
    if (v_weight > 0.0) {
        // Bold place-name tier: a white outline behind the glyph so major names
        // stay legible over busy soundings. The halo is a wider field threshold
        // (accept more field => grow outward); the glyph colour composites on top.
        float halo_a = smoothstep(edge - HALO - w, edge - HALO + w, d);
        float cov = max(a, halo_a);
        if (cov <= 0.0) discard;
        vec3 col = mix(vec3(1.0), v_color.rgb, a); // white halo, glyph colour inside
        o_color = vec4(col, cov * v_color.a);
        return;
    }
    if (a <= 0.0) discard;
    o_color = vec4(v_color.rgb, v_color.a * a);
}
