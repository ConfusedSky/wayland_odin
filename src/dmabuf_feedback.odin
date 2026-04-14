package Main

import renderer "./renderer"
import "core:fmt"
import "core:mem"
import "core:sys/linux"
import zwp_linux_dmabuf_feedback_v1 "wayland_protocol/zwp_linux_dmabuf_feedback_v1"
import zwp_linux_dmabuf_v1 "wayland_protocol/zwp_linux_dmabuf_v1"

// Matches the compositor's packed format table layout: 16 bytes per entry.
DmabufFormatEntry :: struct #packed {
	format:   u32,
	_pad:     u32,
	modifier: u64,
}

// Heap-allocated accumulation state for one feedback object.
// Freed automatically by unregister_event_handler (user_data != state).
DmabufFeedbackState :: struct {
	feedback:         zwp_linux_dmabuf_feedback_v1.t,
	format_table_fd:  linux.Fd,
	format_table:     []DmabufFormatEntry, // slice into mmap'd region
	format_table_len: uint,                // byte length of the mmap (for munmap)
	modifiers:        [dynamic]u64,        // collected modifiers for DRM_FORMAT_ARGB8888
	state:            ^state_t,
}

dmabuf_feedback_handlers := zwp_linux_dmabuf_feedback_v1.EventHandlers{
	on_format_table    = on_dmabuf_feedback_format_table,
	on_tranche_formats = on_dmabuf_feedback_tranche_formats,
	on_done            = on_dmabuf_feedback_done,
}

on_dmabuf_feedback_format_table :: proc(
	_:    u32,
	fd:   linux.Fd,
	size: u32,
	user_data: rawptr,
) {
	fb := (^DmabufFeedbackState)(user_data)

	// Release any previous table.
	if fb.format_table != nil {
		linux.munmap(raw_data(fb.format_table), fb.format_table_len)
		fb.format_table = nil
	}
	if fb.format_table_fd >= 0 {
		linux.close(fb.format_table_fd)
	}

	fb.format_table_fd  = fd
	fb.format_table_len = uint(size)

	ptr, mmap_err := linux.mmap(uintptr(0), uint(size), {.READ}, {.PRIVATE}, fd, 0)
	if mmap_err != nil {
		fmt.eprintln("dmabuf_feedback: mmap failed:", mmap_err)
		fb.state.last_err = mmap_err
		return
	}

	count := uint(size) / size_of(DmabufFormatEntry)
	fb.format_table = ([^]DmabufFormatEntry)(ptr)[:count]
}

on_dmabuf_feedback_tranche_formats :: proc(
	_:         u32,
	indices:   []u8,
	user_data: rawptr,
) {
	fb := (^DmabufFeedbackState)(user_data)
	if fb.format_table == nil do return

	// indices is a packed array of u16 in native endian.
	// The slice is owned by the dispatcher and freed after this callback returns,
	// so we must copy out values before returning.
	n := len(indices) / 2
	idx_ptr := ([^]u16)(raw_data(indices))
	for i in 0 ..< n {
		idx := idx_ptr[i]
		if int(idx) >= len(fb.format_table) do continue
		entry := fb.format_table[idx]
		// Collect ARGB8888 entries.  Also collect INVALID modifier entries for
		// any format so we can detect legacy implicit-modifier support.
		if entry.format == renderer.DRM_FORMAT_ARGB8888 {
			append(&fb.modifiers, entry.modifier)
		}
	}
}

on_dmabuf_feedback_done :: proc(_: u32, user_data: rawptr) {
	fb := (^DmabufFeedbackState)(user_data)

	// Intersect compositor-advertised modifiers with Vulkan-supported ones.
	// Only modifiers in both lists can actually be allocated AND imported.
	vk_supported := fb.state.dmabuf.supported_modifiers

	is_vk_supported :: proc(vk_mods: []u64, m: u64) -> bool {
		for vm in vk_mods {
			if vm == m do return true
		}
		return false
	}

	has_linear := false
	first_other: u64
	first_other_found := false

	for mod in fb.modifiers {
		if !is_vk_supported(vk_supported, mod) do continue
		if mod == renderer.DRM_FORMAT_MOD_LINEAR {
			has_linear = true
		} else if !first_other_found {
			first_other = mod
			first_other_found = true
		}
	}

	// Prefer LINEAR (universally importable), then first other intersection match,
	// then keep the Vulkan-picked default already in state.dmabuf.modifier.
	chosen := fb.state.dmabuf.modifier // keep current default if no overlap
	if has_linear {
		chosen = renderer.DRM_FORMAT_MOD_LINEAR
	} else if first_other_found {
		chosen = first_other
	}

	fmt.printfln(
		"dmabuf_feedback: chose modifier 0x%x for ARGB8888 (%d compositor, %d vulkan, linear=%v)",
		chosen,
		len(fb.modifiers),
		len(vk_supported),
		has_linear,
	)

	fb.state.dmabuf.modifier      = chosen
	fb.state.dmabuf.feedback_done = true

	// Cleanup mmap and fd.
	if fb.format_table != nil {
		linux.munmap(raw_data(fb.format_table), fb.format_table_len)
	}
	if fb.format_table_fd >= 0 {
		linux.close(fb.format_table_fd)
	}
	delete(fb.modifiers)

	// Destroy the Wayland object and remove from handler list.
	// unregister_event_handler will free fb since user_data != state.
	zwp_linux_dmabuf_feedback_v1.destroy(&fb.feedback)
	unregister_event_handler(fb.state, fb.feedback.id)
}

initialize_dmabuf_feedback :: proc(state: ^state_t) -> Errno {
	feedback, err := zwp_linux_dmabuf_v1.get_default_feedback(&state.dmabuf.proxy)
	if err != nil do return err

	fb := new(DmabufFeedbackState)
	fb^ = DmabufFeedbackState{
		feedback        = feedback,
		format_table_fd = -1,
		state           = state,
	}

	register_event_handler(
		state,
		feedback.id,
		&dmabuf_feedback_handlers,
		zwp_linux_dmabuf_feedback_v1.handle_event,
		fb,
	)
	return nil
}
