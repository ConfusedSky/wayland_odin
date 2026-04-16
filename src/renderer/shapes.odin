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

Shape :: struct {
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
	shapes:          [dynamic]Shape, // one entry per submitted shape, sorted before upload
	vertices:        [dynamic]ShapeVertex, // per-frame scratch: sorted shapes expanded to 4 verts each
	pipeline:        vk.Pipeline,
	pipeline_layout: vk.PipelineLayout,
	vert_shader:     vk.ShaderModule,
	frag_shader:     vk.ShaderModule,
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
	s := &state.shapes
	s.shapes = make([dynamic]Shape)
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

	idx_mem_type := find_host_visible_memory(mem_props, idx_mem_reqs.memoryTypeBits) or_return

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
	s := &state.shapes
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
	if s.pipeline != 0 {
		vk.DestroyPipeline(state.device, s.pipeline, nil)
		s.pipeline = 0
	}
	if s.pipeline_layout != 0 {
		vk.DestroyPipelineLayout(state.device, s.pipeline_layout, nil)
		s.pipeline_layout = 0
	}
	if s.frag_shader != 0 {
		vk.DestroyShaderModule(state.device, s.frag_shader, nil)
		s.frag_shader = 0
	}
	if s.vert_shader != 0 {
		vk.DestroyShaderModule(state.device, s.vert_shader, nil)
		s.vert_shader = 0
	}
	delete(s.shapes)
	delete(s.vertices)
}

// ---------------------------------------------------------------------------
// Per-frame API
// ---------------------------------------------------------------------------

start_shapes :: proc(state: ^VulkanState) {
	clear(&state.shapes.shapes)
}

draw_shape :: proc(state: ^VulkanState, shape: Shape) {
	append(&state.shapes.shapes, shape)
}

// Called from render_frame after the grid draw, inside the render pass.
end_shapes :: proc(
	state: ^VulkanState,
	cmd: vk.CommandBuffer,
	surf_w: u32,
	surf_h: u32,
) -> linux.Errno {
	s := &state.shapes
	n_shapes := len(s.shapes)
	if n_shapes == 0 do return nil

	// Sort back-to-front by zindex; stable so equal-zindex shapes keep submission order
	slice.stable_sort_by(s.shapes[:], proc(a, b: Shape) -> bool {
		return a.transform.zindex < b.transform.zindex
	})

	// Expand sorted shapes into the vertex scratch buffer
	clear(&s.vertices)
	for sh in s.shapes {
		expand_shape(sh, &s.vertices)
	}

	n_verts := len(s.vertices)
	needed := vk.DeviceSize(n_verts * size_of(ShapeVertex))
	if needed > s.buffer_capacity {
		grow_shape_vertex_buffer(state, needed) or_return
	}

	mem.copy(s.mapped_ptr, raw_data(s.vertices), int(needed))

	// Flush if not HOST_COHERENT — harmless if it is
	flush := vk.MappedMemoryRange {
		sType  = .MAPPED_MEMORY_RANGE,
		memory = s.vk_memory,
		offset = 0,
		size   = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.FlushMappedMemoryRanges(state.device, 1, &flush)

	vk.CmdBindPipeline(cmd, .GRAPHICS, s.pipeline)

	push := [2]f32{f32(surf_w), f32(surf_h)}
	vk.CmdPushConstants(cmd, s.pipeline_layout, {.VERTEX}, 0, size_of(push), &push)

	offset: vk.DeviceSize = 0
	vk.CmdBindVertexBuffers(cmd, 0, 1, &s.vk_buffer, &offset)
	vk.CmdBindIndexBuffer(cmd, s.index_buffer, 0, .UINT16)

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
expand_shape :: proc(sh: Shape, vertices: ^[dynamic]ShapeVertex) {
	style := sh.style
	angle := sh.transform.angle

	min_x, min_y, max_x, max_y: f32
	shape_type_f32: f32
	gp0, gp1, gp2: [2]f32
	vert_angle: f32

	switch data in sh.data {
	case LineData:
		half_width := data.width / 2
		pad := half_width + style.border_width + 1
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

	case RectData:
		half_size := data.size / 2
		center := data.pos + half_size
		pad := f32(1)
		if angle != 0 {
			r := linalg.length(half_size) + style.border_width + pad
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
		shape_type_f32 = f32(int(ShapeType.Rect))
		gp0 = center
		gp1 = half_size

	case RoundedRectData:
		half_size := data.size / 2
		center := data.pos + half_size
		pad := f32(1)
		if angle != 0 {
			r := linalg.length(half_size) + style.border_width + pad
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
		shape_type_f32 = f32(int(ShapeType.RoundedRect))
		gp0 = center
		gp1 = half_size
		gp2 = {data.corner_radius, 0}

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
				style.border_width +
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
			r := max(data.radii.x, data.radii.y) + style.border_width + pad
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
		r := data.radius + style.border_width + 1
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
find_host_visible_memory :: proc(
	mem_props: vk.PhysicalDeviceMemoryProperties,
	type_bits: u32,
) -> (
	u32,
	linux.Errno,
) {
	// Prefer HOST_VISIBLE | HOST_COHERENT together
	for i in 0 ..< mem_props.memoryTypeCount {
		if type_bits & (1 << i) == 0 do continue
		flags := mem_props.memoryTypes[i].propertyFlags
		if .HOST_VISIBLE in flags && .HOST_COHERENT in flags {
			return i, nil
		}
	}
	// Fall back to HOST_VISIBLE only
	for i in 0 ..< mem_props.memoryTypeCount {
		if type_bits & (1 << i) == 0 do continue
		if .HOST_VISIBLE in mem_props.memoryTypes[i].propertyFlags {
			return i, nil
		}
	}
	fmt.eprintln("shapes: no host-visible memory type found")
	return 0, .ENOMEM
}

@(private)
allocate_shape_vertex_buffer :: proc(state: ^VulkanState, capacity: vk.DeviceSize) -> linux.Errno {
	s := &state.shapes

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

	mem_type := find_host_visible_memory(mem_props, mem_reqs.memoryTypeBits) or_return

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
	s := &state.shapes
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
	s := &state.shapes

	vert_spv := #load("shaders/shapes.vert.spv")
	frag_spv := #load("shaders/shapes.frag.spv")

	vert_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(vert_spv),
		pCode    = cast([^]u32)raw_data(vert_spv),
	}
	if res := vk.CreateShaderModule(state.device, &vert_info, nil, &s.vert_shader);
	   res != .SUCCESS {
		fmt.eprintln("shapes: vkCreateShaderModule (vert) failed:", res)
		return .EINVAL
	}

	frag_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(frag_spv),
		pCode    = cast([^]u32)raw_data(frag_spv),
	}
	if res := vk.CreateShaderModule(state.device, &frag_info, nil, &s.frag_shader);
	   res != .SUCCESS {
		fmt.eprintln("shapes: vkCreateShaderModule (frag) failed:", res)
		return .EINVAL
	}

	// Push constant: surface_width + surface_height (vertex stage only)
	push_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = 2 * size_of(f32),
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_range,
	}
	if res := vk.CreatePipelineLayout(state.device, &layout_info, nil, &s.pipeline_layout);
	   res != .SUCCESS {
		fmt.eprintln("shapes: vkCreatePipelineLayout failed:", res)
		return .EINVAL
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

	shader_stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = s.vert_shader,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = s.frag_shader,
			pName = "main",
		},
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = &dynamic_states[0],
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1.0,
	}

	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	// Premultiplied-alpha blending — the shader already multiplies RGB by alpha,
	// so the source factor must be ONE (not SRC_ALPHA) to avoid a second multiply
	// that would darken anti-aliased and translucent edges.
	blend_attach := vk.PipelineColorBlendAttachmentState {
		blendEnable         = true,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attach,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisample,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state_info,
		layout              = s.pipeline_layout,
		renderPass          = state.render_pass,
		subpass             = 0,
	}
	if res := vk.CreateGraphicsPipelines(state.device, 0, 1, &pipeline_info, nil, &s.pipeline);
	   res != .SUCCESS {
		fmt.eprintln("shapes: vkCreateGraphicsPipelines failed:", res)
		return .EINVAL
	}

	fmt.printfln("shapes: pipeline ready")
	return nil
}
