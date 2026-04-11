#version 450

void main() {
    // Positions for a single oversized triangle that covers the entire screen.
    // The GPU clips it to the viewport — every pixel is covered exactly once,
    // with no shared diagonal edge (unlike a two-triangle quad).
    vec2 positions[3] = vec2[](
        vec2(-1.0, -1.0),
        vec2( 3.0, -1.0),
        vec2(-1.0,  3.0)
    );
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}
