package component

import platform "../platform"
import rect "../rect"
import renderer "../renderer"

ComponentInfo :: struct {
	bbox: rect.Rect,
}

UpdateProc :: proc(this_ptr: rawptr, cinfo: ComponentInfo, finfo: platform.FrameInfo) -> bool
RenderProc :: proc(this_ptr: rawptr, state: ^renderer.VulkanState, cinfo: ComponentInfo)
DestroyProc :: proc(this_ptr: rawptr)

ComponentVTable :: struct {
	update:  UpdateProc,
	render:  RenderProc,
	destroy: DestroyProc,
}

Component :: struct {
	vtable: ComponentVTable,
	type:   typeid,
	ctx:    rawptr,
}

update :: proc(component: ^Component, cinfo: ComponentInfo, finfo: platform.FrameInfo) -> bool {
	if component.vtable.update != nil {
		return component.vtable.update(component.ctx, cinfo, finfo)
	}
	return false
}

render :: proc(component: ^Component, state: ^renderer.VulkanState, cinfo: ComponentInfo) {
	if component.vtable.render != nil {
		component.vtable.render(component.ctx, state, cinfo)
	}
}

destroy :: proc(component: ^Component) {
	if component.vtable.destroy != nil {
		component.vtable.destroy(component.ctx)
	}
	free(component.ctx)
	component.ctx = nil
	component.vtable = {}
	component.type = nil
}
