#version 450

// Push constants: surface dimensions for NDC conversion
layout(push_constant) uniform PC {
    float surface_width;
    float surface_height;
} push;

// Per-vertex: bounding-quad corner in screen pixels
layout(location = 0) in vec2 pos;

// Per-vertex (flat — same value for all 4 corners of a quad)
layout(location = 1) in float shape_type;
layout(location = 2) in vec2 p0;
layout(location = 3) in vec2 p1;
layout(location = 4) in vec2 p2;
layout(location = 5) in vec4 fill_color;
layout(location = 6) in vec4 border_color;
layout(location = 7) in float border_width;

layout(location = 0) flat out float v_shape_type;
layout(location = 1) flat out vec2  v_p0;
layout(location = 2) flat out vec2  v_p1;
layout(location = 3) flat out vec2  v_p2;
layout(location = 4) flat out vec4  v_fill_color;
layout(location = 5) flat out vec4  v_border_color;
layout(location = 6) flat out float v_border_width;

void main() {
    // Convert screen-pixel position to NDC.
    // Vulkan: y=0 at top, NDC y=-1 at top.
    float nx = (pos.x / push.surface_width)  * 2.0 - 1.0;
    float ny = (pos.y / push.surface_height) * 2.0 - 1.0;
    gl_Position = vec4(nx, ny, 0.0, 1.0);

    v_shape_type   = shape_type;
    v_p0           = p0;
    v_p1           = p1;
    v_p2           = p2;
    v_fill_color   = fill_color;
    v_border_color = border_color;
    v_border_width = border_width;
}
