#version 450

layout(location = 0) out vec4 out_color;

layout(push_constant) uniform PushConstants {
    float surface_width;
    float surface_height;
    float pointer_x;
    float pointer_y;
    float num_cells;
} push;

void main() {
    float cell_width  = push.surface_width  / push.num_cells;
    float cell_height = push.surface_height / push.num_cells;

    // Which cell does this fragment fall in?
    // gl_FragCoord has y=0 at the top in Vulkan, matching the CPU loop direction.
    float cell_x = floor(gl_FragCoord.x / cell_width);
    float cell_y = floor(gl_FragCoord.y / cell_height);

    // Which cell does the pointer fall in?
    float pointer_cell_x = floor(push.pointer_x / cell_width);
    float pointer_cell_y = floor(push.pointer_y / cell_height);

    if (cell_x == pointer_cell_x && cell_y == pointer_cell_y) {
        out_color = vec4(1.0, 0.0, 0.0, 1.0); // red pointer cell
    } else {
        float brightness = mod(cell_x + cell_y, 2.0); // checkerboard: 0.0 or 1.0
        out_color = vec4(brightness, brightness, brightness, 1.0);
    }
}
