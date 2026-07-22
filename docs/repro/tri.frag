#version 450
layout(location = 0) in vec3 v_color;
layout(location = 0) out vec4 o;
void main() { o = vec4(v_color, 1.0); }
