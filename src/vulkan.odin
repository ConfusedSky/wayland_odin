package Main

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:sys/linux"
import vk "vendor:vulkan"

// DRM fourcc for B8G8R8A8 in memory (matches VK_FORMAT_B8G8R8A8_UNORM)
DRM_FORMAT_ARGB8888 :: u32(0x34325241)
// Linear (unmodified) layout
DRM_FORMAT_MOD_LINEAR :: u64(0)

VulkanBuffer :: struct {
	image:  vk.Image,
	memory: vk.DeviceMemory,
	dma_fd: linux.Fd,
	stride: u32,
	offset: u32,
	data:   rawptr, // persistently mapped CPU-visible pointer into memory
}

VulkanState :: struct {
	lib:             dynlib.Library,
	instance:        vk.Instance,
	physical_device: vk.PhysicalDevice,
	device:          vk.Device,
	graphics_queue:  vk.Queue,
	graphics_family: u32,
}

VULKAN_DEVICE_EXTENSIONS :: [?]cstring{
	"VK_KHR_external_memory",
	"VK_KHR_external_memory_fd",
	"VK_EXT_external_memory_dma_buf",
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

	// Instance
	app_info := vk.ApplicationInfo{
		sType              = .APPLICATION_INFO,
		pApplicationName   = "wayland_from_scratch",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "none",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_2,
	}
	instance_info := vk.InstanceCreateInfo{
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app_info,
	}
	if res := vk.CreateInstance(&instance_info, nil, &state.instance); res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateInstance failed:", res)
		return .EINVAL
	}
	vk.load_proc_addresses_instance(state.instance)
	fmt.printfln("vulkan: instance created")

	// Physical device — prefer discrete GPU, fall back to first available
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
		if props.deviceType == .DISCRETE_GPU {
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

	// Graphics queue family
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

	// Logical device
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

// Allocate a Vulkan image backed by exportable memory and return its DMA-buf FD,
// stride, and byte offset. Uses linear tiling so the compositor can import it
// without needing DRM format modifiers, and so the CPU can write pixels directly.
allocate_vulkan_buffer :: proc(vk_state: ^VulkanState, w: u32, h: u32) -> (result: VulkanBuffer, err: linux.Errno) {
	buf: VulkanBuffer

	ext_mem_image_info := vk.ExternalMemoryImageCreateInfo{
		sType       = .EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		handleTypes = {.DMA_BUF_EXT},
	}
	image_info := vk.ImageCreateInfo{
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
	if res := vk.CreateImage(vk_state.device, &image_info, nil, &buf.image); res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateImage failed:", res)
		return {}, .EINVAL
	}
	defer if err != nil do vk.DestroyImage(vk_state.device, buf.image, nil)

	mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(vk_state.device, buf.image, &mem_reqs)

	// Find a host-visible memory type compatible with this image.
	// Host-visible is required for linear tiling and lets the CPU write pixels directly.
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(vk_state.physical_device, &mem_props)

	mem_type_idx: u32 = max(u32)
	for i in 0 ..< mem_props.memoryTypeCount {
		if mem_reqs.memoryTypeBits & (1 << i) == 0 do continue
		if .HOST_VISIBLE in mem_props.memoryTypes[i].propertyFlags {
			mem_type_idx = i
			break
		}
	}
	if mem_type_idx == max(u32) {
		fmt.eprintln("vulkan: no host-visible memory type found for buffer")
		return {}, .ENOMEM
	}

	export_alloc_info := vk.ExportMemoryAllocateInfo{
		sType       = .EXPORT_MEMORY_ALLOCATE_INFO,
		handleTypes = {.DMA_BUF_EXT},
	}
	alloc_info := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &export_alloc_info,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type_idx,
	}
	if res := vk.AllocateMemory(vk_state.device, &alloc_info, nil, &buf.memory); res != .SUCCESS {
		fmt.eprintln("vulkan: vkAllocateMemory failed:", res)
		return {}, .ENOMEM
	}
	defer if err != nil do vk.FreeMemory(vk_state.device, buf.memory, nil)

	if res := vk.BindImageMemory(vk_state.device, buf.image, buf.memory, 0); res != .SUCCESS {
		fmt.eprintln("vulkan: vkBindImageMemory failed:", res)
		return {}, .EINVAL
	}

	// Export the backing memory as a DMA-buf fd
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

	// Get the stride and byte offset for the compositor's add() call
	subresource := vk.ImageSubresource{
		aspectMask = {.COLOR},
		mipLevel   = 0,
		arrayLayer = 0,
	}
	layout: vk.SubresourceLayout
	vk.GetImageSubresourceLayout(vk_state.device, buf.image, &subresource, &layout)
	buf.stride = u32(layout.rowPitch)
	buf.offset = u32(layout.offset)

	fmt.printfln("vulkan: buffer allocated — stride=%v offset=%v fd=%v", buf.stride, buf.offset, buf.dma_fd)
	return buf, nil
}

map_vulkan_buffer :: proc(vk_state: ^VulkanState, buf: ^VulkanBuffer) -> linux.Errno {
	if res := vk.MapMemory(vk_state.device, buf.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &buf.data); res != .SUCCESS {
		fmt.eprintln("vulkan: vkMapMemory failed:", res)
		return .EINVAL
	}
	return nil
}

free_vulkan_buffer :: proc(vk_state: ^VulkanState, buf: ^VulkanBuffer) {
	if buf.data != nil {
		vk.UnmapMemory(vk_state.device, buf.memory)
		buf.data = nil
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
		vk.DestroyDevice(state.device, nil)
		state.device = nil
	}
	if state.instance != nil {
		vk.DestroyInstance(state.instance, nil)
		state.instance = nil
	}
	if state.lib != nil {
		dynlib.unload_library(state.lib)
		state.lib = nil
	}
}
