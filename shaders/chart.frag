#version 450
// Flat-color fragment shader. Colors arrive already resolved for the active S-52
// palette (straight-alpha), blended in paint order by the fixed-function blend
// state. That is the entire "resolve token->RGB" step for this ABI: the engine
// resolved them, we captured one color buffer per scheme (see chart.vert slot 1).
layout(location = 0) in  vec4 v_color;
layout(location = 0) out vec4 o_color;
void main() { o_color = v_color; }
