package component

import platform "../platform"
import renderer "../renderer"

ComponentInfo :: struct {
	bbox: renderer.Rect,
}

UpdateProc :: proc(this_ptr: rawptr, cinfo: ComponentInfo, finfo: platform.FrameInfo) -> bool
RenderProc :: proc(this_ptr: rawptr, state: ^renderer.VulkanState, cinfo: ComponentInfo)

ComponentVTable :: struct {
	update: UpdateProc,
	render: RenderProc,
}

Component :: struct {
	vtable: ComponentVTable,
	ctx:    rawptr,
}

update :: proc(component: ^Component, cinfo: ComponentInfo, finfo: platform.FrameInfo) {
	component.vtable.update(component.ctx, cinfo, finfo)
}

render :: proc(component: ^Component, state: ^renderer.VulkanState, cinfo: ComponentInfo) {
	component.vtable.render(component.ctx, state, cinfo)
}
