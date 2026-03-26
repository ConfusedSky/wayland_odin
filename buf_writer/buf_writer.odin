package buf_writer

import utils "../utils"
import "core:mem"
import "core:sys/linux"

header_size: u16 : 8

Writer :: struct($N: int) {
	buf:                   [N]u8,
	buf_size:              int,
	announced_size_offset: int,
}

initialize :: proc(writer: ^Writer($N), object_id: u32, opcode: u16) {
	// We write these manually because we don't want it to affect the announced
	// size
	write_u32_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), object_id)
	write_u16_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), opcode)

	writer.announced_size_offset = writer.buf_size
	write_u16_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), header_size)

	assert(get_announced_size(writer)^ == header_size)
}

get_announced_size :: proc(writer: ^Writer($N)) -> ^u16 {
	return (^u16)(mem.ptr_offset(&writer.buf[0], writer.announced_size_offset))
}

send :: proc(writer: ^Writer($N), socket: linux.Fd) -> linux.Errno {
	announced_size := get_announced_size(writer)^
	assert(utils.roundup_4(announced_size) == announced_size)
	bytes_sent, send_err := linux.send(socket, writer.buf[:writer.buf_size], {})
	if bytes_sent != writer.buf_size {
		return send_err
	}
	return nil
}


send_with_fd :: proc(writer: ^Writer($N), socket: linux.Fd, fd: linux.Fd) -> linux.Errno {
	Cmsghdr :: struct {
		cmsg_len:   uint,
		cmsg_level: i32,
		cmsg_type:  i32,
	}

	SCM_RIGHTS: i32 : 1
	CMSG_ALIGN :: proc(len: $T) -> T {
		return (len + size_of(u64) - 1) & (~(int(size_of(u64) - 1)))
	}
	CMSG_SPACE :: proc(len: $T) -> T {
		return CMSG_ALIGN(len) + CMSG_ALIGN(size_of(Cmsghdr))
	}
	CMSG_LEN :: proc(len: $T) -> T {
		return len + CMSG_ALIGN(size_of(Cmsghdr))
	}

	control_buf: [128]u8
	cmsg := (^Cmsghdr)(&control_buf[0])
	cmsg.cmsg_level = i32(linux.SOL_SOCKET)
	cmsg.cmsg_type = SCM_RIGHTS
	cmsg.cmsg_len = uint(CMSG_LEN(size_of(fd)))
	(^i32)(mem.ptr_offset(&control_buf[0], CMSG_ALIGN(size_of(Cmsghdr))))^ = i32(fd)

	iov := [1]linux.IO_Vec{{base = ([^]byte)(&writer.buf[0]), len = uint(writer.buf_size)}}
	socket_msg := linux.Msg_Hdr {
		iov     = iov[:],
		control = control_buf[:CMSG_SPACE(size_of(fd))],
	}

	bytes_sent, send_err := linux.sendmsg(socket, &socket_msg, {})
	if bytes_sent != writer.buf_size {
		return send_err
	}
	return nil
}

@(private)
write_u32_raw :: proc(buf: ^u8, buf_size: ^int, buf_cap: int, x: u32) {
	destination := mem.ptr_offset(buf, buf_size^)
	assert(buf_size^ + size_of(x) <= buf_cap)
	assert(uintptr(destination) % size_of(x) == 0)
	(^u32)(destination)^ = x
	buf_size^ += size_of(u32)
}

@(private)
write_i32_raw :: proc(buf: ^u8, buf_size: ^int, buf_cap: int, x: i32) {
	destination := mem.ptr_offset(buf, buf_size^)
	assert(buf_size^ + size_of(x) <= buf_cap)
	assert(uintptr(destination) % size_of(x) == 0)
	(^i32)(destination)^ = x
	buf_size^ += size_of(u32)
}

@(private)
write_u16_raw :: proc(buf: ^u8, buf_size: ^int, buf_cap: int, x: u16) {
	destination := mem.ptr_offset(buf, buf_size^)
	assert(buf_size^ + size_of(x) <= buf_cap)
	assert(uintptr(destination) % size_of(x) == 0)
	(^u16)(destination)^ = x
	buf_size^ += size_of(u16)
}

@(private)
write_data_raw :: proc(buf: ^u8, buf_size: ^int, buf_cap: int, src: []u8) {
	assert(buf_size^ + len(src) <= buf_cap)

	// a cstring must be written here, this should probably be made more robust
	str_len := u32(len(src))
	write_u32_raw(buf, buf_size, buf_cap, str_len)
	mem.copy(mem.ptr_offset(buf, buf_size^), raw_data(src[:]), utils.roundup_4(int(str_len)))
	buf_size^ += utils.roundup_4(len(src))
}

write_u32 :: proc(writer: ^Writer($N), x: u32) {
	write_u32_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), x)
	get_announced_size(writer)^ += size_of(u32)
}

write_i32 :: proc(writer: ^Writer($N), x: i32) {
	write_i32_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), x)
	get_announced_size(writer)^ += size_of(i32)
}

write_u16 :: proc(writer: ^Writer($N), x: u16) {
	write_u16_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), x)
	get_announced_size(writer)^ += size_of(u16)
}

write_string :: proc(writer: ^Writer($N), src: string) {
	write_data_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), transmute([]u8)src)
	get_announced_size(writer)^ += u16(size_of(u32) + utils.roundup_4(len(src)))
}

write_array :: proc(writer: ^Writer($N), src: []u8) {
	write_data_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), src)
	get_announced_size(writer)^ += u16(size_of(u32) + utils.roundup_4(len(src)))
}
