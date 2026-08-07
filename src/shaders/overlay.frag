#version 450
// Plugin-overlay fragment shader: the vertex colour, straight out. The overlay
// store resolved the palette token to RGBA at build time, and the pipeline's
// blend state does the alpha. Matches overlay_frag in src/metal_shim.m.
//
// Recompile by hand from the repository root:
//   glslangValidator -V --target-env vulkan1.0 -o src/shaders/overlay.frag.spv src/shaders/overlay.frag
layout(location = 0) in  vec4 v_color;
layout(location = 0) out vec4 o_color;
void main() { o_color = v_color; }
