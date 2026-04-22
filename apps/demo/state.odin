package demo

import "src:platform"
import "src:renderer"
import "src:runtime_log"

LayoutProc :: proc(object: ^SceneObject, state: ^State, info: platform.FrameInfo)

SceneObject :: struct {
	id:          int,
	layout_proc: LayoutProc,
	renderable:  renderer.Renderable,
	movable:     bool,
	bounds:      renderer.Rect,
}

DragState :: struct {
	active_object_id: int,
	grab_offset:      [2]f32,
	dragging:         bool,
}

State :: struct {
	vulkan:      renderer.VulkanState,
	frame_buf:   renderer.VulkanFrameBuffer,
	font:        ^renderer.Font,
	logger:      ^runtime_log.Logger,
	objects:     [dynamic]SceneObject,
	drag:        DragState,
	next_id:     int,
	initialized: bool,
}
