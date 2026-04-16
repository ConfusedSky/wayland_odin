package renderer

import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import vk "vendor:vulkan"

VulkanPipelineInfo :: struct {
	fragment_spv: []u8,
	vertex_spv:   []u8,
	vertex_input: vk.PipelineVertexInputStateCreateInfo,
}

VulkanPipeline :: struct($PushConstantCount: u32) {
	fragment_shader: vk.ShaderModule,
	vertex_shader:   vk.ShaderModule,
	layout:          vk.PipelineLayout,
	vk_pipeline:     vk.Pipeline,
}

initialize_rendering_pipeline :: proc(
	state: ^VulkanState,
	pipeline: ^VulkanPipeline($N),
	info: ^VulkanPipelineInfo,
) -> (
	err: linux.Errno,
) {
	defer if err != nil do destroy_pipeline(state, pipeline)
	pipeline.vertex_shader = create_shader_module(state.device, info.vertex_spv) or_return
	pipeline.fragment_shader = create_shader_module(state.device, info.fragment_spv) or_return

	push_constant_range: vk.PushConstantRange
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}
	if N > 0 {
		push_constant_range = {
			stageFlags = {.VERTEX, .FRAGMENT},
			offset     = 0,
			size       = N * size_of(f32),
		}

		layout_info.pushConstantRangeCount = N
		layout_info.pPushConstantRanges = &push_constant_range
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
		pVertexInputState   = &info.vertex_input,
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

	return nil
}

bind_pipeline :: proc(
	command_buffer: vk.CommandBuffer,
	pipeline: ^VulkanPipeline($N),
	width: u32,
	height: u32,
	push_data: ^[N]f32,
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

@(private)
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

destroy_pipeline :: proc(state: ^VulkanState, pipeline: ^VulkanPipeline($N)) {
	if pipeline.vk_pipeline != 0 {
		vk.DestroyPipeline(state.device, pipeline.vk_pipeline, nil)
		pipeline.vk_pipeline = 0
	}
	if pipeline.layout != 0 {
		vk.DestroyPipelineLayout(state.device, pipeline.layout, nil)
		pipeline.layout = 0
	}
	if pipeline.fragment_shader != 0 {
		vk.DestroyShaderModule(state.device, pipeline.fragment_shader, nil)
		pipeline.fragment_shader = 0
	}
	if pipeline.vertex_shader != 0 {
		vk.DestroyShaderModule(state.device, pipeline.vertex_shader, nil)
		pipeline.vertex_shader = 0
	}
}
