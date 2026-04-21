package wayland

import constants "../../constants"
import wl_buffer "../../wayland_protocol/wl_buffer"
import wl_compositor "../../wayland_protocol/wl_compositor"
import wl_pointer "../../wayland_protocol/wl_pointer"
import wl_seat "../../wayland_protocol/wl_seat"
import wl_shm "../../wayland_protocol/wl_shm"
import wl_shm_pool "../../wayland_protocol/wl_shm_pool"
import wl_surface "../../wayland_protocol/wl_surface"
import xcursor "../../xcursor"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"

BTN_LEFT :: 0x110

Cursor :: struct {
	pool:        ShmPool,
	buffer:      wl_buffer.t,
	surface:     wl_surface.t,
	xhot:        u32,
	yhot:        u32,
	initialized: bool,
}

initialize_cursor :: proc(compositor: ^wl_compositor.t, shm: ^wl_shm.t, cursor: ^Cursor) -> Errno {
	assert(cursor.initialized == false)

	xcursor_size_buf: [64]u8 = ---
	xcursor_size_s := os.lookup_env(xcursor_size_buf[:], "XCURSOR_SIZE") or_else ""
	xcursor_size := strconv.parse_int(xcursor_size_s) or_else 25

	images := xcursor.library_load_images("default", "default", xcursor_size)
	assert(images != nil)
	assert(len(images.images) == 1)
	defer xcursor.images_destroy(images)

	image := images.images[0]
	fmt.printfln("Loaded cursor %v", images.name)
	size := image.height * image.width * constants.COLOR_CHANNELS

	cursor.xhot = image.xhot
	cursor.yhot = image.yhot

	initialize_wl_shm_pool(shm, &cursor.pool, size) or_return
	mem.copy(cursor.pool.data, raw_data(image.pixels), int(size))

	cursor.buffer = wl_shm_pool.create_buffer(
		&cursor.pool.wl_shm_pool,
		0,
		i32(image.width),
		i32(image.height),
		i32(image.width * constants.COLOR_CHANNELS),
		wl_shm.Format.Argb8888,
	) or_return

	cursor.surface = wl_compositor.create_surface(compositor) or_return
	wl_surface.attach(&cursor.surface, &cursor.buffer, 0, 0) or_return
	wl_surface.commit(&cursor.surface) or_return

	cursor.initialized = true
	return nil
}

cleanup_cursor :: proc(cursor: ^Cursor) -> Errno {
	assert(cursor.initialized)
	wl_surface.destroy(&cursor.surface) or_return
	wl_buffer.destroy(&cursor.buffer) or_return
	cleanup_wl_shm_pool(&cursor.pool) or_return
	cursor^ = {}
	return nil
}

wl_pointer_handlers := wl_pointer.EventHandlers {
	on_enter = proc(
		source_object_id: u32,
		serial: u32,
		surface: u32,
		surface_x: f64,
		surface_y: f64,
		user_data: rawptr,
	) {
		client := (^Client)(user_data)
		assert(client.cursor.initialized == true)

		wl_pointer.set_cursor(
			&client.wl_pointer,
			serial,
			&client.cursor.surface,
			i32(client.cursor.xhot),
			i32(client.cursor.yhot),
		)
	},
	on_motion = proc(
		source_object_id: u32,
		time: u32,
		surface_x: f64,
		surface_y: f64,
		user_data: rawptr,
	) {
		client := (^Client)(user_data)
		client.pointer.x = surface_x
		client.pointer.y = surface_y
		if client.surface_state == .ATTACHED {
			client.surface_state = .ACKED_CONFIGURE
		}
	},
	on_button = proc(
		source_object_id: u32,
		serial: u32,
		time: u32,
		button: u32,
		state: wl_pointer.ButtonState,
		user_data: rawptr,
	) {
		client := (^Client)(user_data)
		if button != BTN_LEFT do return

		is_pressed := state == .Pressed
		was_down := client.pointer.left_button_down
		client.pointer.left_button_down = is_pressed
		if is_pressed && !was_down {
			client.pointer.left_button_pressed = true
		}
		if !is_pressed && was_down {
			client.pointer.left_button_released = true
		}
		if client.surface_state == .ATTACHED {
			client.surface_state = .ACKED_CONFIGURE
		}
	},
}

initialize_pointer :: proc(client: ^Client) -> Errno {
	client.wl_pointer = wl_seat.get_pointer(&client.wl_seat) or_return
	register_event_handler(
		client,
		client.wl_pointer.id,
		&wl_pointer_handlers,
		wl_pointer.handle_event,
	)
	return nil
}
