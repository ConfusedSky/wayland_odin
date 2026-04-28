package demo

import component "src:component"
import "src:renderer"
import "src:runtime_log"

State :: struct {
	vulkan:         renderer.VulkanState,
	frame_buf:      renderer.VulkanFrameBuffer,
	logger:         ^runtime_log.Logger,
	initialized:    bool,
	board:          [81]int,
	selected_cell:  int,
	hovered_cell:   int,
	grid_component: component.Component,
}
