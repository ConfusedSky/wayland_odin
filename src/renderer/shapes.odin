package renderer

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:sys/linux"
import vk "vendor:vulkan"

SHAPES_PER_BATCH :: 682
INDEX_BUFFER_LEN :: 4096
// Initial vertex buffer capacity in bytes — enough for 64 shapes
INITIAL_SHAPE_BUFFER_CAPACITY :: 64 * 4 * size_of(ShapeVertex)

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
	shape_data:      [dynamic]ShapeData, // one entry per submitted shape, sorted before upload
	vertices:        [dynamic]ShapeVertex, // per-frame scratch: sorted shapes expanded to 4 verts each
	pipeline:        Pipeline,
	index_buffer:    vk.Buffer,
	index_memory:    vk.DeviceMemory,
	vk_buffer:       vk.Buffer,
	vk_memory:       vk.DeviceMemory,
	buffer_capacity: vk.DeviceSize,
	mapped_ptr:      rawptr, // persistently mapped; valid while vk_buffer alive
}

// ---------------------------------------------------------------------------
// Initialization / teardown
// ---------------------------------------------------------------------------

initialize_shape_renderer :: proc(state: ^VulkanState) -> linux.Errno {
	s := &state.shape_renderer
	s.shape_data = make([dynamic]ShapeData)
	s.vertices = make([dynamic]ShapeVertex)

	// Static index buffer: pattern 0,1,2,2,1,3, 4,5,6,6,5,7, ...
	// 682 complete quads × 6 = 4092 entries used; 4 trailing zeros for alignment.
	indices: [INDEX_BUFFER_LEN]u16
	for q in 0 ..< SHAPES_PER_BATCH {
		base := q * 4
		i := q * 6
		indices[i + 0] = u16(base + 0)
		indices[i + 1] = u16(base + 1)
		indices[i + 2] = u16(base + 2)
		indices[i + 3] = u16(base + 2)
		indices[i + 4] = u16(base + 1)
		indices[i + 5] = u16(base + 3)
	}

	index_size := vk.DeviceSize(size_of(indices))

	// Host-visible index buffer (small, written once)
	idx_buf_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = index_size,
		usage       = {.INDEX_BUFFER},
		sharingMode = .EXCLUSIVE,
	}
	if res := vk.CreateBuffer(state.device, &idx_buf_info, nil, &s.index_buffer); res != .SUCCESS {
		fmt.eprintln("shapes: vkCreateBuffer (index) failed:", res)
		return .EINVAL
	}

	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(state.physical_device, &mem_props)

	idx_mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(state.device, s.index_buffer, &idx_mem_reqs)

	idx_mem_type := find_memory_type(
		mem_props,
		idx_mem_reqs.memoryTypeBits,
		{.HOST_VISIBLE, .HOST_COHERENT},
		vk.MemoryPropertyFlags{.HOST_VISIBLE},
	) or_return

	idx_alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = idx_mem_reqs.size,
		memoryTypeIndex = idx_mem_type,
	}
	if res := vk.AllocateMemory(state.device, &idx_alloc, nil, &s.index_memory); res != .SUCCESS {
		fmt.eprintln("shapes: vkAllocateMemory (index) failed:", res)
		return .ENOMEM
	}
	vk.BindBufferMemory(state.device, s.index_buffer, s.index_memory, 0)

	// Upload index data once
	idx_mapped: rawptr
	vk.MapMemory(state.device, s.index_memory, 0, index_size, {}, &idx_mapped)
	mem.copy(idx_mapped, &indices[0], int(index_size))

	// Flush if not HOST_COHERENT (must happen before unmap)
	flush_idx := vk.MappedMemoryRange {
		sType  = .MAPPED_MEMORY_RANGE,
		memory = s.index_memory,
		offset = 0,
		size   = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.FlushMappedMemoryRanges(state.device, 1, &flush_idx)
	vk.UnmapMemory(state.device, s.index_memory)

	// Initial dynamic vertex buffer (persistently mapped)
	allocate_shape_vertex_buffer(state, INITIAL_SHAPE_BUFFER_CAPACITY) or_return

	// Shape pipeline
	initialize_shape_pipeline(state) or_return

	fmt.printfln("shapes: renderer initialized")
	return nil
}

destroy_shape_renderer :: proc(state: ^VulkanState) {
	s := &state.shape_renderer
	if s.vk_buffer != 0 {
		if s.mapped_ptr != nil {
			vk.UnmapMemory(state.device, s.vk_memory)
			s.mapped_ptr = nil
		}
		vk.DestroyBuffer(state.device, s.vk_buffer, nil)
		vk.FreeMemory(state.device, s.vk_memory, nil)
		s.vk_buffer = 0
		s.vk_memory = 0
	}
	if s.index_buffer != 0 {
		vk.DestroyBuffer(state.device, s.index_buffer, nil)
		vk.FreeMemory(state.device, s.index_memory, nil)
		s.index_buffer = 0
		s.index_memory = 0
	}
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

	// Sort back-to-front by zindex; stable so equal-zindex shapes keep submission order
	slice.stable_sort_by(shapes.shape_data[:], proc(a, b: ShapeData) -> bool {
		return a.transform.zindex < b.transform.zindex
	})

	// Expand sorted shapes into the vertex scratch buffer
	clear(&shapes.vertices)
	for sh in shapes.shape_data {
		expand_shape(sh, &shapes.vertices)
	}

	n_verts := len(shapes.vertices)
	needed := vk.DeviceSize(n_verts * size_of(ShapeVertex))
	if needed > shapes.buffer_capacity {
		grow_shape_vertex_buffer(state, needed) or_return
	}

	mem.copy(shapes.mapped_ptr, raw_data(shapes.vertices), int(needed))

	// Flush if not HOST_COHERENT — harmless if it is
	flush := vk.MappedMemoryRange {
		sType  = .MAPPED_MEMORY_RANGE,
		memory = shapes.vk_memory,
		offset = 0,
		size   = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.FlushMappedMemoryRanges(state.device, 1, &flush)

	vk.CmdBindPipeline(cmd, .GRAPHICS, shapes.pipeline.vk_pipeline)

	push := [2]f32{f32(surf_w), f32(surf_h)}
	vk.CmdPushConstants(cmd, shapes.pipeline.layout, {.VERTEX}, 0, size_of(push), &push)

	offset: vk.DeviceSize = 0
	vk.CmdBindVertexBuffers(cmd, 0, 1, &shapes.vk_buffer, &offset)
	vk.CmdBindIndexBuffer(cmd, shapes.index_buffer, 0, .UINT16)

	total_shapes := n_verts / 4
	batch_start := 0
	for batch_start < total_shapes {
		count := min(total_shapes - batch_start, SHAPES_PER_BATCH)
		vertex_offset := i32(batch_start * 4)
		vk.CmdDrawIndexed(cmd, u32(count * 6), 1, 0, vertex_offset, 0)
		batch_start += count
	}

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
allocate_shape_vertex_buffer :: proc(state: ^VulkanState, capacity: vk.DeviceSize) -> linux.Errno {
	s := &state.shape_renderer

	buf_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = capacity,
		usage       = {.VERTEX_BUFFER},
		sharingMode = .EXCLUSIVE,
	}
	if res := vk.CreateBuffer(state.device, &buf_info, nil, &s.vk_buffer); res != .SUCCESS {
		fmt.eprintln("shapes: vkCreateBuffer (vertex) failed:", res)
		return .EINVAL
	}

	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(state.physical_device, &mem_props)

	mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(state.device, s.vk_buffer, &mem_reqs)

	mem_type := find_memory_type(
		mem_props,
		mem_reqs.memoryTypeBits,
		{.HOST_VISIBLE, .HOST_COHERENT},
		vk.MemoryPropertyFlags{.HOST_VISIBLE},
	) or_return

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type,
	}
	if res := vk.AllocateMemory(state.device, &alloc_info, nil, &s.vk_memory); res != .SUCCESS {
		fmt.eprintln("shapes: vkAllocateMemory (vertex) failed:", res)
		vk.DestroyBuffer(state.device, s.vk_buffer, nil)
		s.vk_buffer = 0
		return .ENOMEM
	}
	vk.BindBufferMemory(state.device, s.vk_buffer, s.vk_memory, 0)

	if res := vk.MapMemory(
		state.device,
		s.vk_memory,
		0,
		vk.DeviceSize(vk.WHOLE_SIZE),
		{},
		&s.mapped_ptr,
	); res != .SUCCESS {
		fmt.eprintln("shapes: vkMapMemory failed:", res)
		return .EINVAL
	}

	s.buffer_capacity = capacity
	return nil
}

@(private)
grow_shape_vertex_buffer :: proc(state: ^VulkanState, needed: vk.DeviceSize) -> linux.Errno {
	s := &state.shape_renderer
	// Unmap and destroy old buffer
	if s.mapped_ptr != nil {
		vk.UnmapMemory(state.device, s.vk_memory)
		s.mapped_ptr = nil
	}
	if s.vk_buffer != 0 {
		vk.DestroyBuffer(state.device, s.vk_buffer, nil)
		vk.FreeMemory(state.device, s.vk_memory, nil)
		s.vk_buffer = 0
		s.vk_memory = 0
	}
	new_cap := max(needed * 2, vk.DeviceSize(INITIAL_SHAPE_BUFFER_CAPACITY))
	fmt.printfln("shapes: growing vertex buffer to %v bytes", new_cap)
	return allocate_shape_vertex_buffer(state, new_cap)
}

@(private)
initialize_shape_pipeline :: proc(state: ^VulkanState) -> linux.Errno {
	s := &state.shape_renderer

	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = 2 * size_of(f32),
	}

	// Vertex attribute descriptions — 10 attributes across 16 f32s (64 bytes)
	binding := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(ShapeVertex),
		inputRate = .VERTEX,
	}

	attrs := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = 0}, // pos
		{location = 1, binding = 0, format = .R32_SFLOAT, offset = 8}, // shape_type
		{location = 2, binding = 0, format = .R32G32_SFLOAT, offset = 12}, // p0
		{location = 3, binding = 0, format = .R32G32_SFLOAT, offset = 20}, // p1
		{location = 4, binding = 0, format = .R32G32_SFLOAT, offset = 28}, // p2
		{location = 5, binding = 0, format = .R32G32B32A32_SFLOAT, offset = 36}, // fill_color
		{location = 6, binding = 0, format = .R32G32B32A32_SFLOAT, offset = 52}, // border_color
		{location = 7, binding = 0, format = .R32_SFLOAT, offset = 68}, // border_width
		{location = 8, binding = 0, format = .R32_SFLOAT, offset = 72}, // angle
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding,
		vertexAttributeDescriptionCount = u32(len(attrs)),
		pVertexAttributeDescriptions    = &attrs[0],
	}

	info := PipelineInfo {
		vertex_spv     = #load("shaders/shapes.vert.spv"),
		fragment_spv   = #load("shaders/shapes.frag.spv"),
		vertex_input   = vertex_input,
		push_constants = {push_constant_range},
	}
	initialize_rendering_pipeline(state, &s.pipeline, &info)

	fmt.printfln("shapes: pipeline ready")
	return nil
}
