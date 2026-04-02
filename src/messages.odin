package Main

import buf_reader "./buf_reader"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"

wayland_handle_messages :: proc(state: ^state_t) {
	Cmsghdr :: struct {
		cmsg_len:   uint,
		cmsg_level: i32,
		cmsg_type:  i32,
	}
	SCM_RIGHTS: i32 : 1
	CMSG_ALIGN :: proc(len: int) -> int {
		return (len + size_of(u64) - 1) & ~int(size_of(u64) - 1)
	}

	read_buf: [4096]u8
	cmsg_buf: [128]u8
	iov := [1]linux.IO_Vec{{base = ([^]byte)(&read_buf[0]), len = size_of(read_buf)}}
	socket_msg := linux.Msg_Hdr {
		iov     = iov[:],
		control = cmsg_buf[:],
	}

	read_bytes, recv_err := linux.recvmsg(state.wl_display.socket, &socket_msg, {.CMSG_CLOEXEC})

	if recv_err == .EINTR {
		return
	} else if read_bytes == -1 || recv_err != nil {
		fmt.eprintln("Failed to receive new events")
		os.exit(int(recv_err))
	}

	fmt.printfln("Received %d bytes", read_bytes)

	// Extract fds from ancillary data (SCM_RIGHTS).
	// Wayland guarantees all fds in a recvmsg batch are consumed by the
	// messages in that same batch, so a local array is sufficient.
	fd_buf: [4]linux.Fd
	fd_count: int
	control := socket_msg.control // kernel updates controllen on return
	cmsg_hdr_size := CMSG_ALIGN(size_of(Cmsghdr))
	for len(control) >= size_of(Cmsghdr) {
		cmsg := (^Cmsghdr)(raw_data(control))
		cmsg_len := int(cmsg.cmsg_len)
		if cmsg.cmsg_level == i32(linux.SOL_SOCKET) && cmsg.cmsg_type == SCM_RIGHTS {
			n := (cmsg_len - cmsg_hdr_size) / size_of(linux.Fd)
			fds_raw := ([^]linux.Fd)(mem.ptr_offset(raw_data(control), cmsg_hdr_size))
			for i in 0 ..< n {
				assert(fd_count < len(fd_buf))
				fd_buf[fd_count] = fds_raw[i]
				fd_count += 1
			}
		}
		aligned_len := CMSG_ALIGN(cmsg_len)
		if aligned_len >= len(control) do break
		control = control[aligned_len:]
	}
	fds := fd_buf[:fd_count]

	msg := &read_buf[0]
	msg_len := int(read_bytes)
	for msg_len > 0 {
		wayland_handle_message(state, &msg, &msg_len, &fds)
	}
	assert(len(fds) == 0, "not all fds were consumed by messages in this batch")
}

wayland_handle_message :: proc(state: ^state_t, msg: ^^u8, msg_len: ^int, fds: ^[]linux.Fd) {
	assert(msg_len^ >= 8)

	object_id := buf_reader.read_u32(msg, msg_len)
	assert(object_id <= state.wl_display.next_id)
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
				fds,
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
