#version 450
// Textured-quad vertex shader for sprite symbols and SDF text. Same anchor +
// screen-space local-px model as chart.vert (constant screen size), plus a UV
// into the atlas. No tessellation — one quad per symbol / glyph.
layout(location = 0) in vec2 a_world;  // web-mercator [0,1], camera-relative
layout(location = 1) in vec2 a_local;  // anchor-relative reference px
layout(location = 2) in vec2 a_uv;     // atlas UV [0,1]
layout(location = 3) in vec4 a_color;  // tint (sprites: white; text: glyph color)

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

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

void main() {
    vec4 clip = u.mvp * vec4(a_world, 0.0, 1.0);
    clip.xy += a_local * u.px_to_clip * u.size_scale * clip.w;
    gl_Position = clip;
    v_uv = a_uv;
    v_color = a_color;
}
