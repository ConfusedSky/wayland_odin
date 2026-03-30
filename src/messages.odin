package Main

import buf_reader "./buf_reader"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"

wayland_handle_messages :: proc(state: ^state_t) {
	read_buf: [4096]u8
	read_bytes, recv_error := linux.recv(state.socket_fd, read_buf[:], {})

	if recv_error == .EINTR {
		return
	} else if read_bytes == -1 || recv_error != nil {
		fmt.eprintln("Failed to receive new events")
		os.exit(int(recv_error))
	}

	fmt.printfln("Received %d bytes", read_bytes)

	msg := &read_buf[0]
	msg_len := int(read_bytes)

	for msg_len > 0 {
		wayland_handle_message(state, &msg, &msg_len)
	}
}

wayland_handle_message :: proc(state: ^state_t, msg: ^^u8, msg_len: ^int) {
	assert(msg_len^ >= 8)

	object_id := buf_reader.read_u32(msg, msg_len)
	assert(object_id <= state.wayland_current_id)
	opcode := buf_reader.read_u16(msg, msg_len)
	announced_size := buf_reader.read_u16(msg, msg_len)

	header_size: u16 = size_of(object_id) + size_of(opcode) + size_of(announced_size)
	assert(announced_size % 4 == 0)
	assert(int(announced_size) <= int(header_size) + msg_len^)

	body_size := int(announced_size) - int(header_size)
	msg_len_before_body := msg_len^

	object_found := false

	for handler in state.event_handlers {
		if object_id == handler.object_id {
			object_found = true
			handler.handle_event(
				object_id,
				opcode,
				msg,
				msg_len,
				handler.event_handlers,
				handler.user_data,
			)
			break
		}
	}

	if !object_found {
		fmt.eprintfln(
			"unknown event: object_id=%d opcode=%d size=%d state=%v, skipping...",
			object_id,
			opcode,
			announced_size,
			state,
		)
	}

	// Skip any remaining bytes in this message (unknown opcodes or unknown objects)
	bytes_consumed := msg_len_before_body - msg_len^
	if bytes_consumed < body_size {
		to_skip := body_size - bytes_consumed
		msg^ = mem.ptr_offset(msg^, to_skip)
		msg_len^ -= to_skip
	}
}
