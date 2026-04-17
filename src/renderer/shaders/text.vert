#version 450

layout(push_constant) uniform PC {
    float surface_width;
    float surface_height;
} pc;

layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;

void main() {
    gl_Position = vec4(
        pos.x / pc.surface_width  * 2.0 - 1.0,
        pos.y / pc.surface_height * 2.0 - 1.0,
        0.0, 1.0
    );
    frag_uv    = uv;
    frag_color = color;
}
