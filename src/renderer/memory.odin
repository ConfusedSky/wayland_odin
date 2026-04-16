package renderer

import "core:fmt"
import "core:sys/linux"
import vk "vendor:vulkan"

find_memory_type :: proc(
	mem_props: vk.PhysicalDeviceMemoryProperties,
	type_bits: u32,
	required_flags: vk.MemoryPropertyFlags,
	fallback_flags: Maybe(vk.MemoryPropertyFlags) = nil,
) -> (
	u32,
	linux.Errno,
) {
	for i in 0 ..< mem_props.memoryTypeCount {
		if type_bits & (1 << i) == 0 do continue
		if required_flags <= mem_props.memoryTypes[i].propertyFlags {
			return i, nil
		}
	}
	if fb, ok := fallback_flags.?; ok {
		for i in 0 ..< mem_props.memoryTypeCount {
			if type_bits & (1 << i) == 0 do continue
			if fb <= mem_props.memoryTypes[i].propertyFlags {
				return i, nil
			}
		}
	}
	fmt.eprintln("vulkan: no compatible memory type found")
	return 0, .ENOMEM
}
