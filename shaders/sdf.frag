#version 450
// SDF text: sample the signed-distance field (.r), antialias with the screen-space
// derivative so text stays crisp at any zoom. Tinted by the glyph color.
layout(set = 2, binding = 0) uniform sampler2D atlas;
layout(location = 0) in  vec2 v_uv;
layout(location = 1) in  vec4 v_color;
layout(location = 0) out vec4 o_color;
void main() {
    float d = texture(atlas, v_uv).r;
    float w = fwidth(d);
    float a = smoothstep(0.5 - w, 0.5 + w, d);
    if (a <= 0.0) discard;
    o_color = vec4(v_color.rgb, v_color.a * a);
}
