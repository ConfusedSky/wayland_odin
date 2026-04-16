package renderer

import "core:fmt"
import "core:sys/linux"
import vk "vendor:vulkan"

PipelineInfo :: struct {
	push_constants: []vk.PushConstantRange,
	fragment_spv:   []u8,
	vertex_spv:     []u8,
	vertex_input:   vk.PipelineVertexInputStateCreateInfo,
}

Pipeline :: struct {
	fragment_shader: vk.ShaderModule,
	vertex_shader:   vk.ShaderModule,
	layout:          vk.PipelineLayout,
	vk_pipeline:     vk.Pipeline,
}

initialize_rendering_pipeline :: proc(
	state: ^VulkanState,
	pipeline: ^Pipeline,
	info: ^PipelineInfo,
) -> (
	err: linux.Errno,
) {
	defer if err != nil do destroy_pipeline(state, pipeline)
	pipeline.vertex_shader = create_shader_module(state.device, info.vertex_spv) or_return
	pipeline.fragment_shader = create_shader_module(state.device, info.fragment_spv) or_return

	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}
	if len(info.push_constants) > 0 {
		layout_info.pushConstantRangeCount = u32(len(info.push_constants))
		layout_info.pPushConstantRanges = &info.push_constants[0]
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

destroy_pipeline :: proc(state: ^VulkanState, pipeline: ^Pipeline) {
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
