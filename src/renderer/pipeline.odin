package renderer

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:sys/linux"
import vk "vendor:vulkan"

NoVertex :: struct {}

VulkanPipelineInfo :: struct {
	fragment_spv:        []u8,
	vertex_spv:          []u8,
	starting_capacity:   vk.DeviceSize,
	descriptor_bindings: []vk.DescriptorSetLayoutBinding, // nil = no descriptor set
}

VulkanPipeline :: struct($PushConstantCount: u32, $VertexType: typeid) {
	fragment_shader:       vk.ShaderModule,
	vertex_shader:         vk.ShaderModule,
	descriptor_set_layout: vk.DescriptorSetLayout, // 0 if unused
	layout:                vk.PipelineLayout,
	vk_pipeline:           vk.Pipeline,
	n_quads:               u32,
	index_buffer:          vk.Buffer,
	index_memory:          vk.DeviceMemory,
	vertex_buffer:         vk.Buffer,
	vertex_memory:         vk.DeviceMemory,
	vertex_capacity:       vk.DeviceSize,
	vertex_data:           rawptr,
}

initialize_rendering_pipeline :: proc(
	state: ^VulkanState,
	pipeline: ^VulkanPipeline($PushConstantCount, $VertexType),
	info: ^VulkanPipelineInfo,
) -> (
	err: linux.Errno,
) {
	defer if err != nil do destroy_pipeline(state, pipeline)
	pipeline.vertex_shader = create_shader_module(state.device, info.vertex_spv) or_return
	pipeline.fragment_shader = create_shader_module(state.device, info.fragment_spv) or_return

	if len(info.descriptor_bindings) > 0 {
		dsl_info := vk.DescriptorSetLayoutCreateInfo {
			sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = u32(len(info.descriptor_bindings)),
			pBindings    = raw_data(info.descriptor_bindings),
		}
		if res := vk.CreateDescriptorSetLayout(
			state.device,
			&dsl_info,
			nil,
			&pipeline.descriptor_set_layout,
		); res != .SUCCESS {
			fmt.eprintln("vulkan: vkCreateDescriptorSetLayout failed:", res)
			return .EINVAL
		}
	}

	push_constant_range: vk.PushConstantRange
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}
	if pipeline.descriptor_set_layout != 0 {
		layout_info.setLayoutCount = 1
		layout_info.pSetLayouts = &pipeline.descriptor_set_layout
	}
	when PushConstantCount > 0 {
		push_constant_range = {
			stageFlags = {.VERTEX, .FRAGMENT},
			offset     = 0,
			size       = PushConstantCount * size_of(f32),
		}

		layout_info.pushConstantRangeCount = 1
		layout_info.pPushConstantRanges = &push_constant_range
	}

	binding: vk.VertexInputBindingDescription
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	attrs: []vk.VertexInputAttributeDescription = nil

	when VertexType != NoVertex {
		binding = {
			binding   = 0,
			stride    = size_of(VertexType),
			inputRate = .VERTEX,
		}
		attrs = get_vertex_attribute_descriptions(VertexType, 0)
		defer delete(attrs)
		vertex_input_info.vertexBindingDescriptionCount = 1
		vertex_input_info.pVertexBindingDescriptions = &binding
		vertex_input_info.vertexAttributeDescriptionCount = u32(len(attrs))
		vertex_input_info.pVertexAttributeDescriptions = raw_data(attrs)
	}

	if res := vk.CreatePipelineLayout(state.device, &layout_info, nil, &pipeline.layout);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreatePipelineLayout failed:", res)
		return .EINVAL
	}

	shader_stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = pipeline.vertex_shader,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = pipeline.fragment_shader,
			pName = "main",
		},
	}

	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = &dynamic_states[0],
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
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
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisample,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state_info,
		layout              = pipeline.layout,
		renderPass          = state.render_pass,
		subpass             = 0,
	}

	if res := vk.CreateGraphicsPipelines(
		state.device,
		0,
		1,
		&pipeline_info,
		nil,
		&pipeline.vk_pipeline,
	); res != .SUCCESS {
		fmt.eprintln("shapes: vkCreateGraphicsPipelines failed:", res)
		return .EINVAL
	}

	if info.starting_capacity > 0 {
		allocate_pipeline_buffers(state, pipeline, info.starting_capacity) or_return
	}

	return nil
}

apply_pipeline :: proc(
	command_buffer: vk.CommandBuffer,
	pipeline: ^VulkanPipeline($C, $V),
	push_data: ^[C]f32,
	descriptor_set: ^vk.DescriptorSet = nil,
) {
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline.vk_pipeline)

	vk.CmdPushConstants(
		command_buffer,
		pipeline.layout,
		{.VERTEX, .FRAGMENT},
		0,
		u32(size_of(push_data^)),
		push_data,
	)

	if descriptor_set != nil {
		vk.CmdBindDescriptorSets(
			command_buffer,
			.GRAPHICS,
			pipeline.layout,
			0,
			1,
			descriptor_set,
			0,
			nil,
		)
	}

	when V == NoVertex {
		// Full-screen triangle — no vertex buffer
		vk.CmdDraw(command_buffer, 3, 1, 0, 0)
	} else {
		offset: vk.DeviceSize = 0
		vk.CmdBindVertexBuffers(command_buffer, 0, 1, &pipeline.vertex_buffer, &offset)
		vk.CmdBindIndexBuffer(command_buffer, pipeline.index_buffer, 0, .UINT16)

		vk.CmdDrawIndexed(command_buffer, u32(pipeline.n_quads * 6), 1, 0, 0, 0)
	}

}

update_pipeline_verticies :: proc(
	state: ^VulkanState,
	pipeline: ^VulkanPipeline($C, $V),
	verticies: []V,
) -> linux.Errno {
	n_verticies := vk.DeviceSize(len(verticies))
	if n_verticies > pipeline.vertex_capacity {
		destroy_pipeline_buffers(state, pipeline)
		new_cap := max(n_verticies * 2, vk.DeviceSize(64))
		new_cap = (new_cap + 3) / 4 * 4
		allocate_pipeline_buffers(state, pipeline, new_cap) or_return
	}

	mem.copy(pipeline.vertex_data, raw_data(verticies), len(verticies) * size_of(V))
	flush_mapped_memory(state.device, pipeline.vertex_memory)

	pipeline.n_quads = u32(len(verticies) / 4)

	return nil
}

get_vertex_attribute_descriptions :: proc(
	id: typeid,
	binding: u32 = 0,
	allocator := context.allocator,
) -> []vk.VertexInputAttributeDescription {
	ti := runtime.type_info_base(type_info_of(id))
	info, ok := ti.variant.(runtime.Type_Info_Struct)
	if !ok {
		fmt.panicf("vertex attr: %v is not a struct", id)
	}
	if .packed not_in info.flags {
		fmt.panicf("vertex attr: %v must be #packed", id)
	}

	count := int(info.field_count)
	attrs := make([]vk.VertexInputAttributeDescription, count, allocator)
	for i in 0 ..< count {
		field_ti := runtime.type_info_base(info.types[i])
		attrs[i] = {
			location = u32(i),
			binding  = binding,
			format   = f32_format_for(field_ti, info.names[i]),
			offset   = u32(info.offsets[i]),
		}
	}
	return attrs
}

@(private = "file")
f32_format_for :: proc(ti: ^runtime.Type_Info, name: string) -> vk.Format {
	if ti.id == f32 {
		return .R32_SFLOAT
	}
	if arr, ok := ti.variant.(runtime.Type_Info_Array); ok {
		if runtime.type_info_base(arr.elem).id == f32 {
			switch arr.count {
			case 1:
				return .R32_SFLOAT
			case 2:
				return .R32G32_SFLOAT
			case 3:
				return .R32G32B32_SFLOAT
			case 4:
				return .R32G32B32A32_SFLOAT
			}
		}
	}
	fmt.panicf("vertex attr: unsupported type for field %q: %v", name, ti)
}

@(private = "file")
flush_mapped_memory :: proc(device: vk.Device, memory: vk.DeviceMemory) {
	r := vk.MappedMemoryRange {
		sType  = .MAPPED_MEMORY_RANGE,
		memory = memory,
		offset = 0,
		size   = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.FlushMappedMemoryRanges(device, 1, &r)
}

@(private = "file")
allocate_pipeline_buffers :: proc(
	state: ^VulkanState,
	pipeline: ^VulkanPipeline($C, $VertexType),
	vertex_capacity: vk.DeviceSize,
) -> (
	err: linux.Errno,
) {
	assert(vertex_capacity % 4 == 0)

	defer if err != nil do destroy_pipeline_buffers(state, pipeline)

	allocate_pipeline_buffer(
		state,
		&pipeline.vertex_buffer,
		&pipeline.vertex_memory,
		{.VERTEX_BUFFER},
		&state.mem_props,
		vertex_capacity * size_of(VertexType),
	) or_return
	allocate_pipeline_buffer(
		state,
		&pipeline.index_buffer,
		&pipeline.index_memory,
		{.INDEX_BUFFER},
		&state.mem_props,
		vertex_capacity / 4 * 6 * size_of(u16),
	) or_return

	if res := vk.MapMemory(
		state.device,
		pipeline.vertex_memory,
		0,
		vk.DeviceSize(vk.WHOLE_SIZE),
		{},
		&pipeline.vertex_data,
	); res != .SUCCESS {
		fmt.eprintln("shapes: vkMapMemory failed:", res)
		return .EINVAL
	}

	n_quads := vertex_capacity / 4
	indices := make([]u16, n_quads * 6)
	defer delete(indices)

	for q in 0 ..< n_quads {
		base := q * 4
		i := q * 6
		indices[i + 0] = u16(base + 0)
		indices[i + 1] = u16(base + 1)
		indices[i + 2] = u16(base + 2)
		indices[i + 3] = u16(base + 2)
		indices[i + 4] = u16(base + 1)
		indices[i + 5] = u16(base + 3)
	}
	index_size := vk.DeviceSize(len(indices) * size_of(u16))

	idx_mapped: rawptr
	vk.MapMemory(
		state.device,
		pipeline.index_memory,
		0,
		vk.DeviceSize(vk.WHOLE_SIZE),
		{},
		&idx_mapped,
	)
	mem.copy(idx_mapped, &indices[0], int(index_size))
	flush_mapped_memory(state.device, pipeline.index_memory)
	vk.UnmapMemory(state.device, pipeline.index_memory)

	pipeline.vertex_capacity = vertex_capacity
	return nil
}

@(private = "file")
allocate_pipeline_buffer :: proc(
	state: ^VulkanState,
	buffer: ^vk.Buffer,
	memory: ^vk.DeviceMemory,
	buffer_usage: vk.BufferUsageFlags,
	mem_props: ^vk.PhysicalDeviceMemoryProperties,
	capacity: vk.DeviceSize,
) -> (
	err: linux.Errno,
) {
	buf_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = capacity,
		usage       = buffer_usage,
		sharingMode = .EXCLUSIVE,
	}
	if res := vk.CreateBuffer(state.device, &buf_info, nil, buffer); res != .SUCCESS {
		fmt.eprintln("shapes: vkCreateBuffer (vertex) failed:", res)
		return .EINVAL
	}
	defer if err != nil {
		vk.DestroyBuffer(state.device, buffer^, nil)
		buffer^ = 0
	}

	mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(state.device, buffer^, &mem_reqs)

	mem_type := find_memory_type(
		mem_props^,
		mem_reqs.memoryTypeBits,
		{.HOST_VISIBLE, .HOST_COHERENT},
		vk.MemoryPropertyFlags{.HOST_VISIBLE},
	) or_return

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type,
	}
	if res := vk.AllocateMemory(state.device, &alloc_info, nil, memory); res != .SUCCESS {
		fmt.eprintln("shapes: vkAllocateMemory (vertex) failed:", res)
		return .ENOMEM
	}
	defer if err != nil {
		vk.FreeMemory(state.device, memory^, nil)
		memory^ = 0
	}

	vk.BindBufferMemory(state.device, buffer^, memory^, 0)

	return nil
}

@(private = "file")
destroy_pipeline_buffers :: proc(state: ^VulkanState, pipeline: ^VulkanPipeline($C, $V)) {
	if pipeline.vertex_buffer != 0 {
		if pipeline.vertex_data != nil {
			vk.UnmapMemory(state.device, pipeline.vertex_memory)
			pipeline.vertex_data = nil
		}
		vk.DestroyBuffer(state.device, pipeline.vertex_buffer, nil)
		vk.FreeMemory(state.device, pipeline.vertex_memory, nil)
		pipeline.vertex_buffer = 0
		pipeline.vertex_memory = 0
	}
	if pipeline.index_buffer != 0 {
		vk.DestroyBuffer(state.device, pipeline.index_buffer, nil)
		vk.FreeMemory(state.device, pipeline.index_memory, nil)
		pipeline.index_buffer = 0
		pipeline.index_memory = 0
	}
	pipeline.vertex_capacity = 0
}

destroy_pipeline :: proc(state: ^VulkanState, pipeline: ^VulkanPipeline($C, $V)) {
	if pipeline.vk_pipeline != 0 {
		vk.DestroyPipeline(state.device, pipeline.vk_pipeline, nil)
		pipeline.vk_pipeline = 0
	}
	if pipeline.layout != 0 {
		vk.DestroyPipelineLayout(state.device, pipeline.layout, nil)
		pipeline.layout = 0
	}
	if pipeline.descriptor_set_layout != 0 {
		vk.DestroyDescriptorSetLayout(state.device, pipeline.descriptor_set_layout, nil)
		pipeline.descriptor_set_layout = 0
	}
	if pipeline.fragment_shader != 0 {
		vk.DestroyShaderModule(state.device, pipeline.fragment_shader, nil)
		pipeline.fragment_shader = 0
	}
	if pipeline.vertex_shader != 0 {
		vk.DestroyShaderModule(state.device, pipeline.vertex_shader, nil)
		pipeline.vertex_shader = 0
	}
	destroy_pipeline_buffers(state, pipeline)
}
