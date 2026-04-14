#version 450

layout(location = 0) flat in float v_shape_type;
layout(location = 1) flat in vec2  v_p0;
layout(location = 2) flat in vec2  v_p1;
layout(location = 3) flat in vec2  v_p2;
layout(location = 4) flat in vec4  v_fill_color;
layout(location = 5) flat in vec4  v_border_color;
layout(location = 6) flat in float v_border_width;

layout(location = 0) out vec4 out_color;

// ---------------------------------------------------------------------------
// SDFs — all operate in screen-pixel space (gl_FragCoord.xy)
// Negative inside the shape, zero at the boundary, positive outside.
// ---------------------------------------------------------------------------

float sdf_segment(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    vec2 ap = p - a;
    float t = clamp(dot(ap, ab) / dot(ab, ab), 0.0, 1.0);
    return length(ap - ab * t);
}

// cap == 0 → square (box cap), cap == 1 → round
float sdf_line(vec2 p, vec2 a, vec2 b, float hw, float cap) {
    if (cap > 0.5) {
        // Round cap: capsule
        return sdf_segment(p, a, b) - hw;
    } else {
        // Square cap: standard box SDF in segment-local space.
        // Transform p so the segment runs from origin to (len, 0).
        vec2 ab  = b - a;
        float len = length(ab);
        if (len < 0.0001) return length(p - a) - hw;
        vec2 dir    = ab / len;
        vec2 ap     = p - a;
        float lx    = dot(ap, dir);
        float ly    = dot(ap, vec2(-dir.y, dir.x));
        // Box centered at segment midpoint, half-extents (len/2, hw)
        vec2 d = abs(vec2(lx - len * 0.5, ly)) - vec2(len * 0.5, hw);
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    }
}

float sdf_box(vec2 p, vec2 center, vec2 hs) {
    vec2 d = abs(p - center) - hs;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdf_rounded_box(vec2 p, vec2 center, vec2 hs, float r) {
    vec2 d = abs(p - center) - hs + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

float sdf_triangle(vec2 p, vec2 a, vec2 b, vec2 c) {
    vec2 e0 = b - a, e1 = c - b, e2 = a - c;
    vec2 v0 = p - a, v1 = p - b, v2 = p - c;
    vec2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    vec2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    vec2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    vec2 d = min(
        min(
            vec2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
            vec2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))
        ),
        vec2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x))
    );
    return -sqrt(d.x) * sign(d.y);
}

// Exact ellipse SDF (Inigo Quilez).
// Returns true Euclidean signed distance — gradient magnitude is 1, so the
// inset border calculation (d + border_width) is exact.
float sdf_ellipse(vec2 p, vec2 center, vec2 ab) {
    vec2 q = abs(p - center);
    // Formula requires the first component to be the smaller semi-axis
    if (q.x > q.y) { q = q.yx; ab = ab.yx; }
    float l  = ab.y * ab.y - ab.x * ab.x;
    float m  = ab.x * q.x / l;   float m2 = m * m;
    float n  = ab.y * q.y / l;   float n2 = n * n;
    float c  = (m2 + n2 - 1.0) / 3.0;
    float c3 = c * c * c;
    float qv = c3 + m2 * n2 * 2.0;
    float d  = c3 + m2 * n2;
    float g  = m + m * n2;
    float co;
    if (d < 0.0) {
        float h  = acos(qv / c3) / 3.0;
        float s  = cos(h);
        float t  = sin(h) * sqrt(3.0);
        float rx = sqrt(-c * (s + t + 2.0) + m2);
        float ry = sqrt(-c * (s - t + 2.0) + m2);
        co = (ry + sign(l) * rx + abs(g) / (rx * ry) - m) / 2.0;
    } else {
        float h  = 2.0 * m * n * sqrt(d);
        float s  = sign(qv + h) * pow(abs(qv + h), 1.0 / 3.0);
        float u  = sign(qv - h) * pow(abs(qv - h), 1.0 / 3.0);
        float rx = -s - u - c * 4.0 + 2.0 * m2;
        float ry = (s - u) * sqrt(3.0);
        float rm = sqrt(rx * rx + ry * ry);
        co = (ry / sqrt(rm - rx) + 2.0 * g / rm - m) / 2.0;
    }
    vec2 r = ab * vec2(co, sqrt(1.0 - co * co));
    return length(r - q) * sign(q.y - r.y);
}

float sdf_circle(vec2 p, vec2 center, float r) {
    return length(p - center) - r;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
    vec2 pixel = gl_FragCoord.xy;

    float d;
    int stype = int(round(v_shape_type));
    switch (stype) {
        case 0: // Line — p0=start p1=end p2=(half_width, cap)
            d = sdf_line(pixel, v_p0, v_p1, v_p2.x, v_p2.y);
            break;
        case 1: // Rect — p0=center p1=half_size
            d = sdf_box(pixel, v_p0, v_p1);
            break;
        case 2: // RoundedRect — p0=center p1=half_size p2=(corner_radius,0)
            d = sdf_rounded_box(pixel, v_p0, v_p1, v_p2.x);
            break;
        case 3: // Triangle — p0=v0 p1=v1 p2=v2
            d = sdf_triangle(pixel, v_p0, v_p1, v_p2);
            break;
        case 4: // Oval — p0=center p1=radii
            d = sdf_ellipse(pixel, v_p0, v_p1);
            break;
        case 5: // Circle — p0=center p2=(radius,0)
            d = sdf_circle(pixel, v_p0, v_p2.x);
            break;
        default:
            discard;
    }

    // Antialiasing: 1-pixel smooth band around the boundary
    float aa = max(fwidth(d), 0.0001) * 0.5;

    // outer_a: 1 inside the shape boundary, 0 outside
    float outer_a = 1.0 - smoothstep(-aa, aa, d);
    // fill_a:  1 inside the inset fill region (border is inset from boundary)
    float fill_a  = 1.0 - smoothstep(-aa, aa, d + v_border_width);
    // ring_a:  the border ring (inside boundary, outside fill)
    float ring_a  = outer_a * (1.0 - fill_a);

    // Multiply geometric alpha by user-specified color alpha
    float eff_fill = fill_a * v_fill_color.a;
    float eff_ring = ring_a * v_border_color.a;

    // Fill and ring regions are mutually exclusive — addition is correct
    out_color = vec4(
        v_fill_color.rgb  * eff_fill + v_border_color.rgb * eff_ring,
        eff_fill + eff_ring
    );

    if (out_color.a < 0.001) discard;
}
