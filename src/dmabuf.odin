package Main

import renderer "./renderer"
import wl_buffer "wayland_protocol/wl_buffer"
import zwp_linux_buffer_params_v1 "wayland_protocol/zwp_linux_buffer_params_v1"
import zwp_linux_dmabuf_v1 "wayland_protocol/zwp_linux_dmabuf_v1"

zwp_linux_dmabuf_handlers: zwp_linux_dmabuf_v1.EventHandlers

// Wrap a VulkanBuffer's DMA-buf FD into a wl_buffer the compositor can display.
// The params object is single-shot per the protocol and is always destroyed after use.
import_as_wl_buffer :: proc(
	state: ^state_t,
	buf: ^renderer.VulkanBuffer,
	w: u32,
	h: u32,
) -> (
	wl_buffer.t,
	Errno,
) {
	params, err := zwp_linux_dmabuf_v1.create_params(&state.zwp_linux_dmabuf)
	if err != nil do return {}, err
	defer zwp_linux_buffer_params_v1.destroy(&params)

	err = zwp_linux_buffer_params_v1.add(
		&params,
		buf.dma_fd,
		0, // plane_idx
		buf.offset,
		buf.stride,
		u32(renderer.DRM_FORMAT_MOD_LINEAR >> 32), // modifier_hi
		u32(renderer.DRM_FORMAT_MOD_LINEAR), // modifier_lo
	)
	if err != nil do return {}, err

	wl_buf, err2 := zwp_linux_buffer_params_v1.create_immed(
		&params,
		i32(w),
		i32(h),
		renderer.DRM_FORMAT_ARGB8888,
		{},
	)
	if err2 != nil do return {}, err2

	return wl_buf, nil
}

initialize_zwp_linux_dmabuf :: proc(state: ^state_t, name: u32, version: u32) -> Errno {
	state.zwp_linux_dmabuf = zwp_linux_dmabuf_v1.from_global(
		&state.wl_registry,
		name,
		version,
	) or_return
	register_event_handler(
		state,
		state.zwp_linux_dmabuf.id,
		&zwp_linux_dmabuf_handlers,
		zwp_linux_dmabuf_v1.handle_event,
	)
	return nil
}
