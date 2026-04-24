package renderer

import runtime_log "../runtime_log"
import "core:c"
import "core:fmt"
import "core:sys/linux"
import vk "vendor:vulkan"

VulkanFrameBuffer :: struct {
	// LINEAR image: DMA-buf exported to the compositor (written to via vkCmdCopyImage)
	image:             vk.Image,
	memory:            vk.DeviceMemory,
	dma_fd:            linux.Fd,
	stride:            u32,
	offset:            u32,
	// OPTIMAL image: GPU render target (rendered into, then copied to the LINEAR image)
	render_image:      vk.Image,
	render_memory:     vk.DeviceMemory,
	render_image_view: vk.ImageView,
	framebuffer:       vk.Framebuffer,
}

allocate_frame_buffer :: proc(
	vk_state: ^VulkanState,
	w: u32,
	h: u32,
) -> (
	result: VulkanFrameBuffer,
	err: linux.Errno,
) {
	buf: VulkanFrameBuffer

	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(vk_state.physical_device, &mem_props)

	linear_modifier := DRM_FORMAT_MOD_LINEAR
	modifier_list_info := vk.ImageDrmFormatModifierListCreateInfoEXT {
		sType                  = .IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
		drmFormatModifierCount = 1,
		pDrmFormatModifiers    = &linear_modifier,
	}
	ext_mem_image_info := vk.ExternalMemoryImageCreateInfo {
		sType       = .EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		pNext       = &modifier_list_info,
		handleTypes = {.DMA_BUF_EXT},
	}
	linear_image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		pNext = &ext_mem_image_info,
		imageType = .D2,
		format = .B8G8R8A8_UNORM,
		extent = {width = w, height = h, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .DRM_FORMAT_MODIFIER_EXT,
		usage = {.TRANSFER_DST},
		sharingMode = .EXCLUSIVE,
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

	linear_mem_type_idx := find_memory_type(
		mem_props,
		linear_mem_reqs.memoryTypeBits,
		{.HOST_VISIBLE},
	) or_return

	dedicated_alloc_info := vk.MemoryDedicatedAllocateInfo {
		sType = .MEMORY_DEDICATED_ALLOCATE_INFO,
		image = buf.image,
	}
	export_alloc_info := vk.ExportMemoryAllocateInfo {
		sType       = .EXPORT_MEMORY_ALLOCATE_INFO,
		pNext       = &dedicated_alloc_info,
		handleTypes = {.DMA_BUF_EXT},
	}
	linear_alloc_info := vk.MemoryAllocateInfo {
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

	fd_info := vk.MemoryGetFdInfoKHR {
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

	subresource := vk.ImageSubresource {
		aspectMask = {.MEMORY_PLANE_0_EXT},
		mipLevel   = 0,
		arrayLayer = 0,
	}
	layout: vk.SubresourceLayout
	vk.GetImageSubresourceLayout(vk_state.device, buf.image, &subresource, &layout)
	buf.stride = u32(layout.rowPitch)
	buf.offset = u32(layout.offset)

	render_image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = .B8G8R8A8_UNORM,
		extent = {width = w, height = h, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.COLOR_ATTACHMENT, .TRANSFER_SRC},
		sharingMode = .EXCLUSIVE,
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

	render_mem_type_idx := find_memory_type(
		mem_props,
		render_mem_reqs.memoryTypeBits,
		{.DEVICE_LOCAL},
		vk.MemoryPropertyFlags{},
	) or_return

	render_alloc_info := vk.MemoryAllocateInfo {
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

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = buf.render_image,
		viewType = .D2,
		format = .B8G8R8A8_UNORM,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	if res := vk.CreateImageView(vk_state.device, &view_info, nil, &buf.render_image_view);
	   res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateImageView failed:", res)
		return {}, .EINVAL
	}
	defer if err != nil do vk.DestroyImageView(vk_state.device, buf.render_image_view, nil)

	fb_info := vk.FramebufferCreateInfo {
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

	if runtime_log.should_log(vk_state.logger, "renderer.buffer.allocated") {
		fmt.printfln(
			"vulkan: buffer allocated — stride=%v offset=%v fd=%v",
			buf.stride,
			buf.offset,
			buf.dma_fd,
		)
	}
	return buf, nil
}
free_frame_buffer :: proc(vk_state: ^VulkanState, buf: ^VulkanFrameBuffer) {
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
