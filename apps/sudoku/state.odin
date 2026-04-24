package demo

import "src:renderer"
import "src:runtime_log"

State :: struct {
	vulkan:      renderer.VulkanState,
	frame_buf:   renderer.VulkanFrameBuffer,
	font:        ^renderer.Font,
	logger:      ^runtime_log.Logger,
	initialized: bool,
	board:       [81]int,
}
