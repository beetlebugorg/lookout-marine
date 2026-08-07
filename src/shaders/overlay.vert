#version 450
// Plugin-overlay vertex shader (Vulkan and SDL_GPU). The chart's shaders come
// from the engine (tile57 shaders/vk/); the overlay is the host's own content,
// so its source lives here — the same split the Metal backend makes, where this
// program is LKM_OVERLAY_MSL in src/metal_shim.m.
//
// The .spv beside it is a committed artifact, as tile57's are: there is no
// shader-compile step in this build. Recompile it by hand from the repository
// root, and keep LKM_OVERLAY_MSL in step:
//   glslangValidator -V --target-env vulkan1.0 -o src/shaders/overlay.vert.spv src/shaders/overlay.vert

// overlay.Vertex (24 B): world f2@0, colour f4@8.
layout(location = 0) in vec2 a_world; // web-mercator, RELATIVE to the frame origin
layout(location = 1) in vec4 a_color; // straight-alpha RGBA, token already resolved

// 128 B, byte-identical to tile57_gpu_uniforms and to the chart's `U`, so the
// overlay rides the same UBO slot. Only mvp and wrap_x are read.
layout(set = 1, binding = 0) uniform U {
    mat4  mvp;
    vec2  px_to_clip;
    float size_scale;
    float current_scale;
    uint  cat_mask;
    float wrap_x;
    float rot_sin;
    float rot_cos;
    vec4  color;
    vec2  anchor_px;
    vec2  cell_px;
} u;

layout(location = 0) out vec4 v_color;

void main() {
    // The chart shader's antimeridian wrap: draw at the world instance nearest
    // the camera. A whole world width is 1.0 in the relative frame too.
    vec2 world = vec2(a_world.x + round(u.wrap_x - a_world.x), a_world.y);
    vec4 clip = u.mvp * vec4(world, 0.0, 1.0);
    // z = 0 is the near plane. The chart's paint-order depths are all in (0,1)
    // and this pass writes no depth, so plugin content is never hidden by the
    // chart and never hides it from a later pass.
    clip.z = 0.0;
    gl_Position = clip;
    v_color = a_color;
}
