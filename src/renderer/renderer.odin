package renderer

import "core:c"
import "core:dynlib"
import "core:fmt"
import "base:runtime"
import "core:sys/linux"
import vk "vendor:vulkan"

// DRM fourcc for B8G8R8A8 in memory (matches VK_FORMAT_B8G8R8A8_UNORM)
DRM_FORMAT_ARGB8888 :: u32(0x34325241)
// Linear (unmodified) layout
DRM_FORMAT_MOD_LINEAR :: u64(0)

VulkanBuffer :: struct {
	// LINEAR image: DMA-buf exported to the compositor (written to via vkCmdCopyImage)
	image:  vk.Image,
	memory: vk.DeviceMemory,
	dma_fd: linux.Fd,
	stride: u32,
	offset: u32,
	// OPTIMAL image: GPU render target (rendered into, then copied to the LINEAR image)
	render_image:      vk.Image,
	render_memory:     vk.DeviceMemory,
	render_image_view: vk.ImageView,
	framebuffer:       vk.Framebuffer,
}

VulkanState :: struct {
	lib:              dynlib.Library,
	instance:         vk.Instance,
	debug_messenger:  vk.DebugUtilsMessengerEXT,
	physical_device:  vk.PhysicalDevice,
	device:           vk.Device,
	graphics_queue:  vk.Queue,
	graphics_family: u32,
	render_pass:     vk.RenderPass,
	vert_shader:     vk.ShaderModule,
	frag_shader:     vk.ShaderModule,
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
	command_pool:    vk.CommandPool,
	command_buffer:  vk.CommandBuffer,
	render_fence:    vk.Fence,
	shapes:          ShapeRenderer,
}

RenderParams :: struct {
	width:     u32,
	height:    u32,
	pointer_x: f32,
	pointer_y: f32,
}

VULKAN_DEVICE_EXTENSIONS :: [?]cstring{
	"VK_KHR_external_memory",
	"VK_KHR_external_memory_fd",
	"VK_EXT_external_memory_dma_buf",
}

VULKAN_VALIDATION_LAYER :: cstring("VK_LAYER_KHRONOS_validation")
VULKAN_INSTANCE_EXTENSIONS :: [?]cstring{"VK_EXT_debug_utils"}

vulkan_debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	prefix: string
	if .ERROR in message_severity {
		prefix = "ERROR"
	} else if .WARNING in message_severity {
		prefix = "WARNING"
	} else if .INFO in message_severity {
		prefix = "INFO"
	} else {
		prefix = "VERBOSE"
	}
	fmt.eprintfln("vulkan [%s]: %s", prefix, callback_data.pMessage)
	return false
}

initialize_vulkan :: proc(state: ^VulkanState) -> linux.Errno {
	lib, ok := dynlib.load_library("libvulkan.so.1")
	if !ok {
		fmt.eprintln("vulkan: failed to load libvulkan.so.1")
		return .ENOENT
	}
	state.lib = lib

	get_proc_addr, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !found {
		fmt.eprintln("vulkan: vkGetInstanceProcAddr not found in libvulkan")
		return .ENOENT
	}
	vk.load_proc_addresses_global(get_proc_addr)

	// Check if the validation layer is available
	layer_count: u32
	vk.EnumerateInstanceLayerProperties(&layer_count, nil)
	available_layers := make([]vk.LayerProperties, layer_count)
	defer delete(available_layers)
	vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers))

	validation_available := false
	for &layer in available_layers {
		if string(cstring(&layer.layerName[0])) == string(VULKAN_VALIDATION_LAYER) {
			validation_available = true
			break
		}
	}
	if !validation_available {
		fmt.eprintln("vulkan: VK_LAYER_KHRONOS_validation not found — install vulkan-validation-layers")
	}

	app_info := vk.ApplicationInfo{
		sType              = .APPLICATION_INFO,
		pApplicationName   = "wayland_from_scratch",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "none",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_2,
	}
	enabled_layers := [?]cstring{VULKAN_VALIDATION_LAYER}
	instance_extensions := VULKAN_INSTANCE_EXTENSIONS
	instance_info := vk.InstanceCreateInfo{
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledLayerCount       = 1 if validation_available else 0,
		ppEnabledLayerNames     = &enabled_layers[0] if validation_available else nil,
		enabledExtensionCount   = u32(len(instance_extensions)) if validation_available else 0,
		ppEnabledExtensionNames = &instance_extensions[0] if validation_available else nil,
	}
	if res := vk.CreateInstance(&instance_info, nil, &state.instance); res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateInstance failed:", res)
		return .EINVAL
	}
	vk.load_proc_addresses_instance(state.instance)
	fmt.printfln("vulkan: instance created")

	if validation_available {
		debug_messenger_info := vk.DebugUtilsMessengerCreateInfoEXT{
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = vulkan_debug_callback,
		}
		if res := vk.CreateDebugUtilsMessengerEXT(
			state.instance,
			&debug_messenger_info,
			nil,
			&state.debug_messenger,
		); res != .SUCCESS {
			fmt.eprintln("vulkan: failed to create debug messenger:", res)
			// Non-fatal — continue without the messenger
		} else {
			fmt.printfln("vulkan: validation layers active")
		}
	}

	device_count: u32
	vk.EnumeratePhysicalDevices(state.instance, &device_count, nil)
	if device_count == 0 {
		fmt.eprintln("vulkan: no physical devices found")
		return .ENODEV
	}
	physical_devices := make([]vk.PhysicalDevice, device_count)
	defer delete(physical_devices)
	vk.EnumeratePhysicalDevices(state.instance, &device_count, raw_data(physical_devices))

	chosen: vk.PhysicalDevice
	for pd in physical_devices {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(pd, &props)
		if props.deviceType == .INTEGRATED_GPU {
			chosen = pd
			break
		}
		if chosen == nil do chosen = pd
	}
	state.physical_device = chosen

	{
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(chosen, &props)
		fmt.printfln("vulkan: selected device '%s'", cstring(&props.deviceName[0]))
	}

	qf_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(chosen, &qf_count, nil)
	qf_props := make([]vk.QueueFamilyProperties, qf_count)
	defer delete(qf_props)
	vk.GetPhysicalDeviceQueueFamilyProperties(chosen, &qf_count, raw_data(qf_props))

	state.graphics_family = max(u32)
	for qf, i in qf_props {
		if .GRAPHICS in qf.queueFlags {
			state.graphics_family = u32(i)
			break
		}
	}
	if state.graphics_family == max(u32) {
		fmt.eprintln("vulkan: no graphics queue family found")
		return .ENODEV
	}
	fmt.printfln("vulkan: graphics queue family %v", state.graphics_family)

	priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo{
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = state.graphics_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	extensions := VULKAN_DEVICE_EXTENSIONS
	device_info := vk.DeviceCreateInfo{
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = &extensions[0],
	}
	if res := vk.CreateDevice(chosen, &device_info, nil, &state.device); res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateDevice failed:", res)
		return .EINVAL
	}
	vk.load_proc_addresses_device(state.device)

	vk.GetDeviceQueue(state.device, state.graphics_family, 0, &state.graphics_queue)
	fmt.printfln("vulkan: device and graphics queue ready")

	return nil
}

allocate_vulkan_buffer :: proc(
	vk_state: ^VulkanState,
	w: u32,
	h: u32,
) -> (
	result: VulkanBuffer,
	err: linux.Errno,
) {
	buf: VulkanBuffer

	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(vk_state.physical_device, &mem_props)

	ext_mem_image_info := vk.ExternalMemoryImageCreateInfo{
		sType       = .EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		handleTypes = {.DMA_BUF_EXT},
	}
	linear_image_info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		pNext         = &ext_mem_image_info,
		imageType     = .D2,
		format        = .B8G8R8A8_UNORM,
		extent        = {width = w, height = h, depth = 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .LINEAR,
		usage         = {.TRANSFER_DST},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(vk_state.device, &linear_image_info, nil, &buf.image);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateImage (linear) failed:", res)
		return {}, .EINVAL
	}
	defer if err != nil do vk.DestroyImage(vk_state.device, buf.image, nil)

	linear_mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(vk_state.device, buf.image, &linear_mem_reqs)

	linear_mem_type_idx: u32 = max(u32)
	for i in 0 ..< mem_props.memoryTypeCount {
		if linear_mem_reqs.memoryTypeBits & (1 << i) == 0 do continue
		if .HOST_VISIBLE in mem_props.memoryTypes[i].propertyFlags {
			linear_mem_type_idx = i
			break
		}
	}
	if linear_mem_type_idx == max(u32) {
		fmt.eprintln("vulkan: no host-visible memory type found for linear image")
		return {}, .ENOMEM
	}

	export_alloc_info := vk.ExportMemoryAllocateInfo{
		sType       = .EXPORT_MEMORY_ALLOCATE_INFO,
		handleTypes = {.DMA_BUF_EXT},
	}
	linear_alloc_info := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &export_alloc_info,
		allocationSize  = linear_mem_reqs.size,
		memoryTypeIndex = linear_mem_type_idx,
	}
	if res := vk.AllocateMemory(vk_state.device, &linear_alloc_info, nil, &buf.memory);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkAllocateMemory (linear) failed:", res)
		return {}, .ENOMEM
	}
	defer if err != nil do vk.FreeMemory(vk_state.device, buf.memory, nil)

	if res := vk.BindImageMemory(vk_state.device, buf.image, buf.memory, 0); res != .SUCCESS {
		fmt.eprintln("vulkan: vkBindImageMemory (linear) failed:", res)
		return {}, .EINVAL
	}

	fd_info := vk.MemoryGetFdInfoKHR{
		sType      = .MEMORY_GET_FD_INFO_KHR,
		memory     = buf.memory,
		handleType = {.DMA_BUF_EXT},
	}
	raw_fd: c.int
	if res := vk.GetMemoryFdKHR(vk_state.device, &fd_info, &raw_fd); res != .SUCCESS {
		fmt.eprintln("vulkan: vkGetMemoryFdKHR failed:", res)
		return {}, .EINVAL
	}
	buf.dma_fd = linux.Fd(raw_fd)
	defer if err != nil do linux.close(buf.dma_fd)

	subresource := vk.ImageSubresource{
		aspectMask = {.COLOR},
		mipLevel   = 0,
		arrayLayer = 0,
	}
	layout: vk.SubresourceLayout
	vk.GetImageSubresourceLayout(vk_state.device, buf.image, &subresource, &layout)
	buf.stride = u32(layout.rowPitch)
	buf.offset = u32(layout.offset)

	render_image_info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = .B8G8R8A8_UNORM,
		extent        = {width = w, height = h, depth = 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.COLOR_ATTACHMENT, .TRANSFER_SRC},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(vk_state.device, &render_image_info, nil, &buf.render_image);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateImage (render) failed:", res)
		return {}, .EINVAL
	}
	defer if err != nil do vk.DestroyImage(vk_state.device, buf.render_image, nil)

	render_mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(vk_state.device, buf.render_image, &render_mem_reqs)

	render_mem_type_idx: u32 = max(u32)
	for i in 0 ..< mem_props.memoryTypeCount {
		if render_mem_reqs.memoryTypeBits & (1 << i) == 0 do continue
		if .DEVICE_LOCAL in mem_props.memoryTypes[i].propertyFlags {
			render_mem_type_idx = i
			break
		}
	}
	if render_mem_type_idx == max(u32) {
		for i in 0 ..< mem_props.memoryTypeCount {
			if render_mem_reqs.memoryTypeBits & (1 << i) != 0 {
				render_mem_type_idx = i
				break
			}
		}
	}
	if render_mem_type_idx == max(u32) {
		fmt.eprintln("vulkan: no compatible memory type found for render image")
		return {}, .ENOMEM
	}

	render_alloc_info := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = render_mem_reqs.size,
		memoryTypeIndex = render_mem_type_idx,
	}
	if res := vk.AllocateMemory(vk_state.device, &render_alloc_info, nil, &buf.render_memory);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkAllocateMemory (render) failed:", res)
		return {}, .ENOMEM
	}
	defer if err != nil do vk.FreeMemory(vk_state.device, buf.render_memory, nil)

	if res := vk.BindImageMemory(vk_state.device, buf.render_image, buf.render_memory, 0);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkBindImageMemory (render) failed:", res)
		return {}, .EINVAL
	}

	view_info := vk.ImageViewCreateInfo{
		sType    = .IMAGE_VIEW_CREATE_INFO,
		image    = buf.render_image,
		viewType = .D2,
		format   = .B8G8R8A8_UNORM,
		subresourceRange = vk.ImageSubresourceRange{
			aspectMask     = {.COLOR},
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}
	if res := vk.CreateImageView(vk_state.device, &view_info, nil, &buf.render_image_view);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateImageView failed:", res)
		return {}, .EINVAL
	}
	defer if err != nil do vk.DestroyImageView(vk_state.device, buf.render_image_view, nil)

	fb_info := vk.FramebufferCreateInfo{
		sType           = .FRAMEBUFFER_CREATE_INFO,
		renderPass      = vk_state.render_pass,
		attachmentCount = 1,
		pAttachments    = &buf.render_image_view,
		width           = w,
		height          = h,
		layers          = 1,
	}
	if res := vk.CreateFramebuffer(vk_state.device, &fb_info, nil, &buf.framebuffer);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateFramebuffer failed:", res)
		return {}, .EINVAL
	}

	fmt.printfln(
		"vulkan: buffer allocated — stride=%v offset=%v fd=%v",
		buf.stride,
		buf.offset,
		buf.dma_fd,
	)
	return buf, nil
}

initialize_vulkan_pipeline :: proc(state: ^VulkanState) -> linux.Errno {
	color_attachment := vk.AttachmentDescription{
		format         = .B8G8R8A8_UNORM,
		samples         = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .GENERAL,
	}
	color_attachment_ref := vk.AttachmentReference{
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}
	subpass := vk.SubpassDescription{
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}
	dependency := vk.SubpassDependency{
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	render_pass_info := vk.RenderPassCreateInfo{
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}
	if res := vk.CreateRenderPass(state.device, &render_pass_info, nil, &state.render_pass);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateRenderPass failed:", res)
		return .EINVAL
	}

	vert_spv := #load("shaders/grid.vert.spv")
	frag_spv := #load("shaders/grid.frag.spv")

	vert_info := vk.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(vert_spv),
		pCode    = cast([^]u32)raw_data(vert_spv),
	}
	if res := vk.CreateShaderModule(state.device, &vert_info, nil, &state.vert_shader);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateShaderModule (vert) failed:", res)
		return .EINVAL
	}

	frag_info := vk.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(frag_spv),
		pCode    = cast([^]u32)raw_data(frag_spv),
	}
	if res := vk.CreateShaderModule(state.device, &frag_info, nil, &state.frag_shader);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateShaderModule (frag) failed:", res)
		return .EINVAL
	}

	// Push constant: 5 × f32
	push_constant_range := vk.PushConstantRange{
		stageFlags = {.FRAGMENT},
		offset     = 0,
		size       = 5 * size_of(f32),
	}
	layout_info := vk.PipelineLayoutCreateInfo{
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}
	if res := vk.CreatePipelineLayout(state.device, &layout_info, nil, &state.pipeline_layout);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreatePipelineLayout failed:", res)
		return .EINVAL
	}

	shader_stages := [2]vk.PipelineShaderStageCreateInfo{
		{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.VERTEX},
			module = state.vert_shader,
			pName  = "main",
		},
		{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.FRAGMENT},
			module = state.frag_shader,
			pName  = "main",
		},
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_info := vk.PipelineDynamicStateCreateInfo{
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = &dynamic_states[0],
	}

	viewport_state := vk.PipelineViewportStateCreateInfo{
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo{
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1.0,
	}

	multisample := vk.PipelineMultisampleStateCreateInfo{
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	// Opaque — grid pipeline needs no blending
	color_blend_attachment := vk.PipelineColorBlendAttachmentState{
		colorWriteMask = {.R, .G, .B, .A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = u32(len(shader_stages)),
		pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisample,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state_info,
		layout              = state.pipeline_layout,
		renderPass          = state.render_pass,
		subpass             = 0,
	}
	if res := vk.CreateGraphicsPipelines(
		state.device,
		0,
		1,
		&pipeline_info,
		nil,
		&state.pipeline,
	); res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateGraphicsPipelines failed:", res)
		return .EINVAL
	}

	fmt.printfln("vulkan: grid pipeline ready")
	return nil
}

initialize_vulkan_commands :: proc(state: ^VulkanState) -> linux.Errno {
	pool_info := vk.CommandPoolCreateInfo{
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = state.graphics_family,
	}
	if res := vk.CreateCommandPool(state.device, &pool_info, nil, &state.command_pool);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateCommandPool failed:", res)
		return .EINVAL
	}

	alloc_info := vk.CommandBufferAllocateInfo{
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = state.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if res := vk.AllocateCommandBuffers(state.device, &alloc_info, &state.command_buffer);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkAllocateCommandBuffers failed:", res)
		return .EINVAL
	}

	fence_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	if res := vk.CreateFence(state.device, &fence_info, nil, &state.render_fence);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateFence failed:", res)
		return .EINVAL
	}

	fmt.printfln("vulkan: command buffer and fence ready")
	return nil
}

NUM_CELLS :: 10

render_frame :: proc(
	vk_state: ^VulkanState,
	buf: ^VulkanBuffer,
	params: RenderParams,
) -> linux.Errno {
	if res := vk.WaitForFences(vk_state.device, 1, &vk_state.render_fence, true, max(u64));
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkWaitForFences failed:", res)
		return .EINVAL
	}
	if res := vk.ResetFences(vk_state.device, 1, &vk_state.render_fence); res != .SUCCESS {
		fmt.eprintln("vulkan: vkResetFences failed:", res)
		return .EINVAL
	}

	if res := vk.ResetCommandBuffer(vk_state.command_buffer, {}); res != .SUCCESS {
		fmt.eprintln("vulkan: vkResetCommandBuffer failed:", res)
		return .EINVAL
	}

	begin_info := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if res := vk.BeginCommandBuffer(vk_state.command_buffer, &begin_info); res != .SUCCESS {
		fmt.eprintln("vulkan: vkBeginCommandBuffer failed:", res)
		return .EINVAL
	}

	clear_value := vk.ClearValue{color = {float32 = {0, 0, 0, 1}}}
	render_pass_begin := vk.RenderPassBeginInfo{
		sType       = .RENDER_PASS_BEGIN_INFO,
		renderPass  = vk_state.render_pass,
		framebuffer = buf.framebuffer,
		renderArea  = vk.Rect2D{extent = {width = params.width, height = params.height}},
		clearValueCount = 1,
		pClearValues    = &clear_value,
	}
	vk.CmdBeginRenderPass(vk_state.command_buffer, &render_pass_begin, .INLINE)

	vk.CmdBindPipeline(vk_state.command_buffer, .GRAPHICS, vk_state.pipeline)

	viewport := vk.Viewport{
		x        = 0,
		y        = 0,
		width    = f32(params.width),
		height   = f32(params.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(vk_state.command_buffer, 0, 1, &viewport)

	scissor := vk.Rect2D{extent = {width = params.width, height = params.height}}
	vk.CmdSetScissor(vk_state.command_buffer, 0, 1, &scissor)

	push_data := [5]f32{
		f32(params.width),
		f32(params.height),
		params.pointer_x,
		params.pointer_y,
		f32(NUM_CELLS),
	}
	vk.CmdPushConstants(
		vk_state.command_buffer,
		vk_state.pipeline_layout,
		{.FRAGMENT},
		0,
		u32(size_of(push_data)),
		&push_data,
	)

	// Full-screen triangle — no vertex buffer
	vk.CmdDraw(vk_state.command_buffer, 3, 1, 0, 0)

	// Draw shapes over the grid if any were submitted this frame
	if len(vk_state.shapes.vertices) > 0 {
		end_shapes(vk_state, vk_state.command_buffer, params.width, params.height) or_return
	}

	vk.CmdEndRenderPass(vk_state.command_buffer)

	full_subresource_range := vk.ImageSubresourceRange{
		aspectMask     = {.COLOR},
		baseMipLevel   = 0,
		levelCount     = 1,
		baseArrayLayer = 0,
		layerCount     = 1,
	}

	pre_copy_barriers := [2]vk.ImageMemoryBarrier{
		{
			sType               = .IMAGE_MEMORY_BARRIER,
			srcAccessMask       = {.COLOR_ATTACHMENT_WRITE},
			dstAccessMask       = {.TRANSFER_READ},
			oldLayout           = .GENERAL,
			newLayout           = .TRANSFER_SRC_OPTIMAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image               = buf.render_image,
			subresourceRange    = full_subresource_range,
		},
		{
			sType               = .IMAGE_MEMORY_BARRIER,
			srcAccessMask       = {},
			dstAccessMask       = {.TRANSFER_WRITE},
			oldLayout           = .UNDEFINED,
			newLayout           = .GENERAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image               = buf.image,
			subresourceRange    = full_subresource_range,
		},
	}
	vk.CmdPipelineBarrier(
		vk_state.command_buffer,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER},
		{},
		0, nil,
		0, nil,
		u32(len(pre_copy_barriers)), &pre_copy_barriers[0],
	)

	copy_region := vk.ImageCopy{
		srcSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		dstSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		extent         = {width = params.width, height = params.height, depth = 1},
	}
	vk.CmdCopyImage(
		vk_state.command_buffer,
		buf.render_image, .TRANSFER_SRC_OPTIMAL,
		buf.image, .GENERAL,
		1, &copy_region,
	)

	post_copy_barrier := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {.TRANSFER_WRITE},
		dstAccessMask       = {.MEMORY_READ},
		oldLayout           = .GENERAL,
		newLayout           = .GENERAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = buf.image,
		subresourceRange    = full_subresource_range,
	}
	vk.CmdPipelineBarrier(
		vk_state.command_buffer,
		{.TRANSFER},
		{.BOTTOM_OF_PIPE},
		{},
		0, nil,
		0, nil,
		1, &post_copy_barrier,
	)

	if res := vk.EndCommandBuffer(vk_state.command_buffer); res != .SUCCESS {
		fmt.eprintln("vulkan: vkEndCommandBuffer failed:", res)
		return .EINVAL
	}

	submit_info := vk.SubmitInfo{
		sType                = .SUBMIT_INFO,
		commandBufferCount   = 1,
		pCommandBuffers      = &vk_state.command_buffer,
	}
	if res := vk.QueueSubmit(vk_state.graphics_queue, 1, &submit_info, vk_state.render_fence);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkQueueSubmit failed:", res)
		return .EINVAL
	}

	if res := vk.WaitForFences(vk_state.device, 1, &vk_state.render_fence, true, max(u64));
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkWaitForFences (post-submit) failed:", res)
		return .EINVAL
	}

	return nil
}

free_vulkan_buffer :: proc(vk_state: ^VulkanState, buf: ^VulkanBuffer) {
	if buf.framebuffer != 0 {
		vk.DestroyFramebuffer(vk_state.device, buf.framebuffer, nil)
		buf.framebuffer = 0
	}
	if buf.render_image_view != 0 {
		vk.DestroyImageView(vk_state.device, buf.render_image_view, nil)
		buf.render_image_view = 0
	}
	if buf.render_image != 0 {
		vk.DestroyImage(vk_state.device, buf.render_image, nil)
		buf.render_image = 0
	}
	if buf.render_memory != 0 {
		vk.FreeMemory(vk_state.device, buf.render_memory, nil)
		buf.render_memory = 0
	}
	if buf.dma_fd > 0 {
		linux.close(buf.dma_fd)
		buf.dma_fd = -1
	}
	if buf.image != 0 {
		vk.DestroyImage(vk_state.device, buf.image, nil)
		buf.image = 0
	}
	if buf.memory != 0 {
		vk.FreeMemory(vk_state.device, buf.memory, nil)
		buf.memory = 0
	}
}

cleanup_vulkan :: proc(state: ^VulkanState) {
	if state.device != nil {
		vk.DeviceWaitIdle(state.device)
		destroy_shape_renderer(state)
		if state.render_fence != 0 {
			vk.DestroyFence(state.device, state.render_fence, nil)
			state.render_fence = 0
		}
		if state.command_pool != 0 {
			vk.DestroyCommandPool(state.device, state.command_pool, nil)
			state.command_pool = 0
		}
		if state.pipeline != 0 {
			vk.DestroyPipeline(state.device, state.pipeline, nil)
			state.pipeline = 0
		}
		if state.pipeline_layout != 0 {
			vk.DestroyPipelineLayout(state.device, state.pipeline_layout, nil)
			state.pipeline_layout = 0
		}
		if state.frag_shader != 0 {
			vk.DestroyShaderModule(state.device, state.frag_shader, nil)
			state.frag_shader = 0
		}
		if state.vert_shader != 0 {
			vk.DestroyShaderModule(state.device, state.vert_shader, nil)
			state.vert_shader = 0
		}
		if state.render_pass != 0 {
			vk.DestroyRenderPass(state.device, state.render_pass, nil)
			state.render_pass = 0
		}
		vk.DestroyDevice(state.device, nil)
		state.device = nil
	}
	if state.instance != nil {
		if state.debug_messenger != 0 {
			vk.DestroyDebugUtilsMessengerEXT(state.instance, state.debug_messenger, nil)
			state.debug_messenger = 0
		}
		vk.DestroyInstance(state.instance, nil)
		state.instance = nil
	}
	if state.lib != nil {
		dynlib.unload_library(state.lib)
		state.lib = nil
	}
}
