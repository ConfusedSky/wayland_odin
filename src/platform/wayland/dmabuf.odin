package wayland

import renderer "../../renderer"
import wl_buffer "../../wayland_protocol/wl_buffer"
import zwp_linux_buffer_params_v1 "../../wayland_protocol/zwp_linux_buffer_params_v1"
import zwp_linux_dmabuf_v1 "../../wayland_protocol/zwp_linux_dmabuf_v1"

zwp_linux_dmabuf_handlers: zwp_linux_dmabuf_v1.EventHandlers

import_as_wl_buffer :: proc(
	client: ^Client,
	buf: ^renderer.VulkanFrameBuffer,
	width: u32,
	height: u32,
) -> (
	wl_buffer.t,
	Errno,
) {
	params, err := zwp_linux_dmabuf_v1.create_params(&client.zwp_linux_dmabuf)
	if err != nil do return {}, err
	defer zwp_linux_buffer_params_v1.destroy(&params)

	err = zwp_linux_buffer_params_v1.add(
		&params,
		buf.dma_fd,
		0,
		buf.offset,
		buf.stride,
		u32(renderer.DRM_FORMAT_MOD_LINEAR >> 32),
		u32(renderer.DRM_FORMAT_MOD_LINEAR),
	)
	if err != nil do return {}, err

	wl_buf, err2 := zwp_linux_buffer_params_v1.create_immed(
		&params,
		i32(width),
		i32(height),
		renderer.DRM_FORMAT_ARGB8888,
		{},
	)
	if err2 != nil do return {}, err2

	return wl_buf, nil
}

initialize_zwp_linux_dmabuf :: proc(client: ^Client, name: u32, version: u32) -> Errno {
	client.zwp_linux_dmabuf = zwp_linux_dmabuf_v1.from_global(
		&client.wl_registry,
		name,
		version,
	) or_return
	register_event_handler(
		client,
		client.zwp_linux_dmabuf.id,
		&zwp_linux_dmabuf_handlers,
		zwp_linux_dmabuf_v1.handle_event,
	)
	return nil
}
