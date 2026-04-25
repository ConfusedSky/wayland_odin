package demo

import "src:renderer"
import "src:runtime_log"

State :: struct {
	vulkan:        renderer.VulkanState,
	frame_buf:     renderer.VulkanFrameBuffer,
	logger:        ^runtime_log.Logger,
	initialized:   bool,
	board:         [81]int,
	selected_cell: int,
	hovered_cell:  int,
	pointer_x:     f32,
	pointer_y:     f32,
}
