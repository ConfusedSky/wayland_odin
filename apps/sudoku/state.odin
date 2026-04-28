package demo

import component "src:component"
import "src:renderer"
import "src:runtime_log"

State :: struct {
	vulkan:           renderer.VulkanState,
	frame_buf:        renderer.VulkanFrameBuffer,
	logger:           ^runtime_log.Logger,
	initialized:      bool,
	board:            [81]int,
	selected_cell:    int,
	hovered_cell:     int,
	grid_component:   component.Component,
	conflicted_cells: [81]bool,
	conflicted_rows:  [9]bool,
	conflicted_cols:  [9]bool,
	conflicted_boxes: [9]bool,
}
