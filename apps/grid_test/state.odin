package grid_test

import component "src:component"
import "src:renderer"
import "src:runtime_log"

State :: struct {
	vulkan:         renderer.VulkanState,
	frame_buf:      renderer.VulkanFrameBuffer,
	logger:         ^runtime_log.Logger,
	grid:           component.Grid(3),
	sub_grids:      [3][3]component.Grid(3),
	grid_component: component.Component,
	initialized:    bool,
}
