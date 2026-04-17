package renderer

import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:sys/linux"
import vk "vendor:vulkan"

LineCap :: enum int {
	Square = 0,
	Round  = 1,
}

Style :: struct {
	fill_color:   [4]f32,
	border_color: [4]f32,
	border_width: f32,
}

Transform :: struct {
	angle:  f32,
	zindex: f32,
}

LineData :: struct {
	p0, p1: [2]f32,
	width:  f32,
	cap:    LineCap,
}

RectData :: struct {
	pos:  [2]f32,
	size: [2]f32,
}

RoundedRectData :: struct {
	pos:           [2]f32,
	size:          [2]f32,
	corner_radius: f32,
}

TriangleData :: struct {
	p0, p1, p2: [2]f32,
}

OvalData :: struct {
	center: [2]f32,
	radii:  [2]f32,
}

CircleData :: struct {
	center: [2]f32,
	radius: f32,
}

ShapeData :: struct {
	data:      union {
		LineData,
		RectData,
		RoundedRectData,
		TriangleData,
		OvalData,
		CircleData,
	},
	transform: Transform,
	style:     Style,
}

@(private)
ShapeType :: enum int {
	Line        = 0,
	Rect        = 1,
	RoundedRect = 2,
	Triangle    = 3,
	Oval        = 4,
	Circle      = 5,
}

// 76 bytes, 19 × f32.
// All fields except pos carry the same value for all 4 vertices of a quad —
// they are declared `flat` in the shaders (no interpolation).
ShapeVertex :: struct #packed {
	pos:          [2]f32, // bounding-quad corner in screen pixels
	shape_type:   f32,
	p0:           [2]f32,
	p1:           [2]f32,
	p2:           [2]f32, // geometric point OR (scalar_a, scalar_b)
	fill_color:   [4]f32,
	border_color: [4]f32,
	border_width: f32,
	angle:        f32, // rotation in radians (counter-clockwise)
}

ShapeRenderer :: struct {
	shape_data: [dynamic]ShapeData, // one entry per submitted shape, sorted before upload
	vertices:   [dynamic]ShapeVertex, // per-frame scratch: sorted shapes expanded to 4 verts each
	pipeline:   VulkanPipeline(2, ShapeVertex),
}

// ---------------------------------------------------------------------------
// Initialization / teardown
// ---------------------------------------------------------------------------

initialize_shape_renderer :: proc(state: ^VulkanState) -> linux.Errno {
	s := &state.shape_renderer
	s.shape_data = make([dynamic]ShapeData)
	s.vertices = make([dynamic]ShapeVertex)

	// Shape pipeline
	initialize_shape_pipeline(state) or_return

	fmt.printfln("shapes: renderer initialized")
	return nil
}

destroy_shape_renderer :: proc(state: ^VulkanState) {
	s := &state.shape_renderer
	destroy_pipeline(state, &s.pipeline)
	delete(s.shape_data)
	delete(s.vertices)
}

// ---------------------------------------------------------------------------
// Per-frame API
// ---------------------------------------------------------------------------

start_shapes :: proc(state: ^VulkanState) {
	clear(&state.shape_renderer.shape_data)
}

draw_shape :: proc(state: ^VulkanState, shape: ShapeData) {
	append(&state.shape_renderer.shape_data, shape)
}

// Called from render_frame after the grid draw, inside the render pass.
end_shapes :: proc(
	state: ^VulkanState,
	cmd: vk.CommandBuffer,
	surf_w: u32,
	surf_h: u32,
) -> linux.Errno {
	shapes := &state.shape_renderer
	n_shapes := len(shapes.shape_data)
	if n_shapes == 0 do return nil
	assert(n_shapes <= 16383, "too many shapes: u16 index buffer overflow")

	// Sort back-to-front by zindex; stable so equal-zindex shapes keep submission order
	slice.stable_sort_by(shapes.shape_data[:], proc(a, b: ShapeData) -> bool {
		return a.transform.zindex < b.transform.zindex
	})

	// Expand sorted shapes into the vertex scratch buffer
	clear(&shapes.vertices)
	for sh in shapes.shape_data {
		expand_shape(sh, &shapes.vertices)
	}

	update_pipeline_verticies(state, &shapes.pipeline, shapes.vertices[:])

	push := [2]f32{f32(surf_w), f32(surf_h)}
	apply_pipeline(cmd, &shapes.pipeline, &push)

	return nil
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

@(private)
expand_shape :: proc(sh: ShapeData, vertices: ^[dynamic]ShapeVertex) {
	style := sh.style
	angle := sh.transform.angle

	min_x, min_y, max_x, max_y: f32
	shape_type_f32: f32
	gp0, gp1, gp2: [2]f32
	vert_angle: f32

	switch data in sh.data {
	case LineData:
		half_width := data.width / 2
		pad := half_width + 1
		pivot := (data.p0 + data.p1) * 0.5
		if angle != 0 {
			r := linalg.length(data.p1 - data.p0) * 0.5 + pad
			min_x = pivot.x - r
			min_y = pivot.y - r
			max_x = pivot.x + r
			max_y = pivot.y + r
			vert_angle = angle
		} else {
			min_x = min(data.p0.x, data.p1.x) - pad
			min_y = min(data.p0.y, data.p1.y) - pad
			max_x = max(data.p0.x, data.p1.x) + pad
			max_y = max(data.p0.y, data.p1.y) + pad
		}
		shape_type_f32 = f32(int(ShapeType.Line))
		gp0 = data.p0
		gp1 = data.p1
		gp2 = {half_width, f32(int(data.cap))}

	case RectData, RoundedRectData:
		half_size, center: [2]f32
		#partial switch d in data {
		case RectData:
			half_size = d.size / 2
			center = d.pos + half_size
			shape_type_f32 = f32(int(ShapeType.Rect))
		case RoundedRectData:
			half_size = d.size / 2
			center = d.pos + half_size
			shape_type_f32 = f32(int(ShapeType.RoundedRect))
			gp2 = {d.corner_radius, 0}
		}
		pad := f32(1)
		if angle != 0 {
			r := linalg.length(half_size) + pad
			min_x = center.x - r
			min_y = center.y - r
			max_x = center.x + r
			max_y = center.y + r
			vert_angle = angle
		} else {
			min_x = center.x - half_size.x - pad
			min_y = center.y - half_size.y - pad
			max_x = center.x + half_size.x + pad
			max_y = center.y + half_size.y + pad
		}
		gp0 = center
		gp1 = half_size

	case TriangleData:
		pad := f32(1)
		centroid := (data.p0 + data.p1 + data.p2) / 3.0
		if angle != 0 {
			r :=
				max(
					linalg.length(data.p0 - centroid),
					linalg.length(data.p1 - centroid),
					linalg.length(data.p2 - centroid),
				) +
				pad
			min_x = centroid.x - r
			min_y = centroid.y - r
			max_x = centroid.x + r
			max_y = centroid.y + r
			vert_angle = angle
		} else {
			min_x = min(data.p0.x, data.p1.x, data.p2.x) - pad
			min_y = min(data.p0.y, data.p1.y, data.p2.y) - pad
			max_x = max(data.p0.x, data.p1.x, data.p2.x) + pad
			max_y = max(data.p0.y, data.p1.y, data.p2.y) + pad
		}
		shape_type_f32 = f32(int(ShapeType.Triangle))
		gp0 = data.p0
		gp1 = data.p1
		gp2 = data.p2

	case OvalData:
		pad := f32(1)
		if angle != 0 {
			r := max(data.radii.x, data.radii.y) + pad
			min_x = data.center.x - r
			min_y = data.center.y - r
			max_x = data.center.x + r
			max_y = data.center.y + r
			vert_angle = angle
		} else {
			min_x = data.center.x - data.radii.x - pad
			min_y = data.center.y - data.radii.y - pad
			max_x = data.center.x + data.radii.x + pad
			max_y = data.center.y + data.radii.y + pad
		}
		shape_type_f32 = f32(int(ShapeType.Oval))
		gp0 = data.center
		gp1 = data.radii

	case CircleData:
		r := data.radius + 1
		min_x = data.center.x - r
		min_y = data.center.y - r
		max_x = data.center.x + r
		max_y = data.center.y + r
		shape_type_f32 = f32(int(ShapeType.Circle))
		gp0 = data.center
		gp2 = {data.radius, 0}
	}

	corners := [4][2]f32{{min_x, min_y}, {max_x, min_y}, {min_x, max_y}, {max_x, max_y}}
	for c in corners {
		append(
			vertices,
			ShapeVertex {
				pos = c,
				shape_type = shape_type_f32,
				p0 = gp0,
				p1 = gp1,
				p2 = gp2,
				fill_color = style.fill_color,
				border_color = style.border_color,
				border_width = style.border_width,
				angle = vert_angle,
			},
		)
	}
}

@(private)
initialize_shape_pipeline :: proc(state: ^VulkanState) -> linux.Errno {
	shapes := &state.shape_renderer

	info := VulkanPipelineInfo {
		vertex_spv        = #load("shaders/shapes.vert.spv"),
		fragment_spv      = #load("shaders/shapes.frag.spv"),
		starting_capacity = 64,
	}
	initialize_rendering_pipeline(state, &shapes.pipeline, &info) or_return

	fmt.printfln("shapes: pipeline ready")
	return nil
}
