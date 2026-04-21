package renderer

import runtime_log "../runtime_log"
import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:sys/linux"
import vk "vendor:vulkan"

// DRM fourcc for B8G8R8A8 in memory (matches VK_FORMAT_B8G8R8A8_UNORM)
DRM_FORMAT_ARGB8888 :: u32(0x34325241)
// Linear (unmodified) layout
DRM_FORMAT_MOD_LINEAR :: u64(0)

VulkanState :: struct {
	logger:          ^runtime_log.Logger,
	lib:             dynlib.Library,
	instance:        vk.Instance,
	debug_messenger: vk.DebugUtilsMessengerEXT,
	physical_device: vk.PhysicalDevice,
	mem_props:       vk.PhysicalDeviceMemoryProperties,
	device:          vk.Device,
	graphics_queue:  vk.Queue,
	graphics_family: u32,
	render_pass:     vk.RenderPass,
	grid_pipeline:   VulkanPipeline(5, NoVertex),
	command_pool:    vk.CommandPool,
	command_buffer:  vk.CommandBuffer,
	render_fence:    vk.Fence,
	shape_renderer:  ShapeRenderer,
	text_renderer:   TextRenderer,
}

RenderParams :: struct {
	width:     u32,
	height:    u32,
	pointer_x: f32,
	pointer_y: f32,
}

VULKAN_DEVICE_EXTENSIONS :: [?]cstring {
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

initialize_vulkan :: proc(state: ^VulkanState, logger: ^runtime_log.Logger) -> linux.Errno {
	state.logger = logger

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
		fmt.eprintln(
			"vulkan: VK_LAYER_KHRONOS_validation not found — install vulkan-validation-layers",
		)
	}

	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "wayland_from_scratch",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "none",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_2,
	}
	enabled_layers := [?]cstring{VULKAN_VALIDATION_LAYER}
	instance_extensions := VULKAN_INSTANCE_EXTENSIONS
	instance_info := vk.InstanceCreateInfo {
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
	if runtime_log.should_log(state.logger, "renderer.vulkan.instance_created") {
		fmt.printfln("vulkan: instance created")
	}

	if validation_available {
		debug_messenger_info := vk.DebugUtilsMessengerCreateInfoEXT {
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
		} else if runtime_log.should_log(state.logger, "renderer.vulkan.validation_layers") {
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
	vk.GetPhysicalDeviceMemoryProperties(chosen, &state.mem_props)

	{
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(chosen, &props)
		if runtime_log.should_log(state.logger, "renderer.vulkan.device_selected") {
			fmt.printfln("vulkan: selected device '%s'", cstring(&props.deviceName[0]))
		}
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
	if runtime_log.should_log(state.logger, "renderer.vulkan.graphics_queue_family") {
		fmt.printfln("vulkan: graphics queue family %v", state.graphics_family)
	}

	priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = state.graphics_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	extensions := VULKAN_DEVICE_EXTENSIONS
	device_info := vk.DeviceCreateInfo {
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
	if runtime_log.should_log(state.logger, "renderer.vulkan.device_ready") {
		fmt.printfln("vulkan: device and graphics queue ready")
	}

	color_attachment := vk.AttachmentDescription {
		format         = .B8G8R8A8_UNORM,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .GENERAL,
	}
	color_attachment_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}
	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}
	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	render_pass_info := vk.RenderPassCreateInfo {
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

	initialize_grid_pipeline(state) or_return
	initialize_vulkan_commands(state) or_return
	initialize_shape_renderer(state) or_return
	initialize_text_renderer(state) or_return

	return nil
}

initialize_grid_pipeline :: proc(state: ^VulkanState) -> linux.Errno {
	info := VulkanPipelineInfo {
		vertex_spv   = #load("shaders/grid.vert.spv"),
		fragment_spv = #load("shaders/grid.frag.spv"),
	}
	initialize_rendering_pipeline(state, &state.grid_pipeline, &info) or_return

	if runtime_log.should_log(state.logger, "renderer.vulkan.grid_pipeline_ready") {
		fmt.printfln("vulkan: grid pipeline ready")
	}
	return nil
}

initialize_vulkan_commands :: proc(state: ^VulkanState) -> linux.Errno {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = state.graphics_family,
	}
	if res := vk.CreateCommandPool(state.device, &pool_info, nil, &state.command_pool);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateCommandPool failed:", res)
		return .EINVAL
	}

	alloc_info := vk.CommandBufferAllocateInfo {
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

	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	if res := vk.CreateFence(state.device, &fence_info, nil, &state.render_fence);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateFence failed:", res)
		return .EINVAL
	}

	if runtime_log.should_log(state.logger, "renderer.vulkan.command_ready") {
		fmt.printfln("vulkan: command buffer and fence ready")
	}
	return nil
}

NUM_CELLS :: 10

render_frame :: proc(
	vk_state: ^VulkanState,
	buf: ^VulkanFrameBuffer,
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

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if res := vk.BeginCommandBuffer(vk_state.command_buffer, &begin_info); res != .SUCCESS {
		fmt.eprintln("vulkan: vkBeginCommandBuffer failed:", res)
		return .EINVAL
	}

	clear_value := vk.ClearValue {
		color = {float32 = {0, 0, 0, 1}},
	}
	render_pass_begin := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = vk_state.render_pass,
		framebuffer = buf.framebuffer,
		renderArea = vk.Rect2D{extent = {width = params.width, height = params.height}},
		clearValueCount = 1,
		pClearValues = &clear_value,
	}
	vk.CmdBeginRenderPass(vk_state.command_buffer, &render_pass_begin, .INLINE)

	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(params.width),
		height   = f32(params.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(vk_state.command_buffer, 0, 1, &viewport)

	scissor := vk.Rect2D {
		extent = {width = params.width, height = params.height},
	}
	vk.CmdSetScissor(vk_state.command_buffer, 0, 1, &scissor)

	push_data := [5]f32 {
		f32(params.width),
		f32(params.height),
		params.pointer_x,
		params.pointer_y,
		f32(NUM_CELLS),
	}
	apply_pipeline(vk_state.command_buffer, &vk_state.grid_pipeline, &push_data)

	// Draw shapes over the grid if any were submitted this frame
	if len(vk_state.shape_renderer.shape_data) > 0 {
		end_shapes(vk_state, vk_state.command_buffer, params.width, params.height) or_return
	}

	if len(vk_state.text_renderer.text_draws) > 0 {
		end_text(vk_state, vk_state.command_buffer, params.width, params.height) or_return
	}

	vk.CmdEndRenderPass(vk_state.command_buffer)

	full_subresource_range := vk.ImageSubresourceRange {
		aspectMask     = {.COLOR},
		baseMipLevel   = 0,
		levelCount     = 1,
		baseArrayLayer = 0,
		layerCount     = 1,
	}

	pre_copy_barriers := [2]vk.ImageMemoryBarrier {
		{
			sType = .IMAGE_MEMORY_BARRIER,
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstAccessMask = {.TRANSFER_READ},
			oldLayout = .GENERAL,
			newLayout = .TRANSFER_SRC_OPTIMAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = buf.render_image,
			subresourceRange = full_subresource_range,
		},
		{
			sType = .IMAGE_MEMORY_BARRIER,
			srcAccessMask = {},
			dstAccessMask = {.TRANSFER_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .GENERAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = buf.image,
			subresourceRange = full_subresource_range,
		},
	}
	vk.CmdPipelineBarrier(
		vk_state.command_buffer,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER},
		{},
		0,
		nil,
		0,
		nil,
		u32(len(pre_copy_barriers)),
		&pre_copy_barriers[0],
	)

	copy_region := vk.ImageCopy {
		srcSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		dstSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		extent = {width = params.width, height = params.height, depth = 1},
	}
	vk.CmdCopyImage(
		vk_state.command_buffer,
		buf.render_image,
		.TRANSFER_SRC_OPTIMAL,
		buf.image,
		.GENERAL,
		1,
		&copy_region,
	)

	post_copy_barrier := vk.ImageMemoryBarrier {
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
		0,
		nil,
		0,
		nil,
		1,
		&post_copy_barrier,
	)

	if res := vk.EndCommandBuffer(vk_state.command_buffer); res != .SUCCESS {
		fmt.eprintln("vulkan: vkEndCommandBuffer failed:", res)
		return .EINVAL
	}

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &vk_state.command_buffer,
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

cleanup_vulkan :: proc(state: ^VulkanState) {
	if state.device != nil {
		vk.DeviceWaitIdle(state.device)
		destroy_shape_renderer(state)
		destroy_text_renderer(state)
		destroy_pipeline(state, &state.grid_pipeline)
		if state.render_fence != 0 {
			vk.DestroyFence(state.device, state.render_fence, nil)
			state.render_fence = 0
		}
		if state.command_pool != 0 {
			vk.DestroyCommandPool(state.device, state.command_pool, nil)
			state.command_pool = 0
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
