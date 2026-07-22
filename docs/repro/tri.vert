#version 450
layout(location = 0) out vec3 v_color;
void main() {
    // fullscreen-ish triangle from gl_VertexIndex, no buffers
    vec2 p = vec2((gl_VertexIndex == 1) ? 1.5 : -0.5, (gl_VertexIndex == 2) ? 1.5 : -0.5);
    gl_Position = vec4(p, 0.5, 1.0);
    v_color = vec3(1.0, 0.3, 0.1);
}
