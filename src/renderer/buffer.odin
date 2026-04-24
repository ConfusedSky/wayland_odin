package renderer

import "core:fmt"
import "core:mem"
import "core:sys/linux"
import vk "vendor:vulkan"

VulkanBuffer :: struct(Stage: vk.BufferUsageFlag, Type: typeid) {
	buffer:   vk.Buffer,
	memory:   vk.DeviceMemory,
	capacity: vk.DeviceSize,
	data:     rawptr,
}

QuadIndexBuffer :: VulkanBuffer(.INDEX_BUFFER, u16)

allocate_buffer :: proc(
	state: ^VulkanState,
	buffer: ^VulkanBuffer($Stage, $Type),
	capacity: vk.DeviceSize,
) -> (
	err: linux.Errno,
) {
	buf_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = capacity * size_of(Type),
		usage       = {Stage},
		sharingMode = .EXCLUSIVE,
	}
	if res := vk.CreateBuffer(state.device, &buf_info, nil, &buffer.buffer); res != .SUCCESS {
		fmt.eprintln("shapes: vkCreateBuffer (vertex) failed:", res)
		return .EINVAL
	}
	defer if err != nil {
		vk.DestroyBuffer(state.device, buffer.buffer, nil)
		buffer.buffer = 0
	}

	mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(state.device, buffer.buffer, &mem_reqs)

	mem_type := find_memory_type(
		state.mem_props,
		mem_reqs.memoryTypeBits,
		{.HOST_VISIBLE, .HOST_COHERENT},
		vk.MemoryPropertyFlags{.HOST_VISIBLE},
	) or_return

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type,
	}
	if res := vk.AllocateMemory(state.device, &alloc_info, nil, &buffer.memory); res != .SUCCESS {
		fmt.eprintln("shapes: vkAllocateMemory (vertex) failed:", res)
		return .ENOMEM
	}
	defer if err != nil {
		vk.FreeMemory(state.device, buffer.memory, nil)
		buffer.memory = 0
	}

	if res := vk.BindBufferMemory(state.device, buffer.buffer, buffer.memory, 0); res != .SUCCESS {
		fmt.eprintln("shapes: vkBindBufferMemory failed:", res)
		return .EINVAL
	}

	if res := vk.MapMemory(
		state.device,
		buffer.memory,
		0,
		vk.DeviceSize(vk.WHOLE_SIZE),
		{},
		&buffer.data,
	); res != .SUCCESS {
		return .EINVAL
	}
	defer if err != nil {
		vk.UnmapMemory(state.device, buffer.memory)
		buffer.data = nil
	}

	buffer.capacity = capacity

	return nil
}

set_buffer_data :: proc(state: ^VulkanState, buffer: ^VulkanBuffer($Stage, $Type), data: []Type) {
	ensure_buffer_capacity(state, buffer, vk.DeviceSize(len(data)))

	mem.copy(buffer.data, raw_data(data), len(data) * size_of(Type))
	flush_buffer(state, buffer)
}

flush_buffer :: proc(state: ^VulkanState, buffer: ^VulkanBuffer($Stage, $Type)) {
	r := vk.MappedMemoryRange {
		sType  = .MAPPED_MEMORY_RANGE,
		memory = buffer.memory,
		offset = 0,
		size   = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.FlushMappedMemoryRanges(state.device, 1, &r)
}

ensure_buffer_capacity :: proc(
	state: ^VulkanState,
	buffer: ^VulkanBuffer($Stage, $Type),
	capacity: vk.DeviceSize,
) -> linux.Errno {
	if capacity <= buffer.capacity do return nil

	destroy_buffer(state, buffer)
	allocate_buffer(state, buffer, capacity) or_return

	return nil
}

destroy_buffer :: proc(state: ^VulkanState, buffer: ^VulkanBuffer($Stage, $Type)) {
	if buffer.buffer != 0 {
		if buffer.data != nil {
			vk.UnmapMemory(state.device, buffer.memory)
			buffer.data = nil
		}
		vk.DestroyBuffer(state.device, buffer.buffer, nil)
		vk.FreeMemory(state.device, buffer.memory, nil)
		buffer.buffer = 0
		buffer.memory = 0
	}
}

allocate_quad_index_buffer :: proc(
	state: ^VulkanState,
	buffer: ^QuadIndexBuffer,
	n_quads: vk.DeviceSize,
) -> linux.Errno {
	allocate_buffer(state, buffer, n_quads * 6) or_return

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
	set_buffer_data(state, buffer, indices)

	return nil
}

ensure_quad_index_buffer :: proc(
	state: ^VulkanState,
	buffer: ^QuadIndexBuffer,
	n_quads: vk.DeviceSize,
) -> linux.Errno {
	if n_quads * 6 <= buffer.capacity do return nil

	destroy_buffer(state, buffer)
	allocate_quad_index_buffer(state, buffer, n_quads) or_return

	return nil
}
