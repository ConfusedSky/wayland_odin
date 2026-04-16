package renderer

import "core:fmt"
import "core:sys/linux"
import vk "vendor:vulkan"

create_shader_module :: proc(device: vk.Device, spv: []u8) -> (vk.ShaderModule, linux.Errno) {
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spv),
		pCode    = cast([^]u32)raw_data(spv),
	}
	mod: vk.ShaderModule
	if res := vk.CreateShaderModule(device, &info, nil, &mod); res != .SUCCESS {
		fmt.eprintln("vulkan: vkCreateShaderModule failed:", res)
		return {}, .EINVAL
	}
	return mod, nil
}
