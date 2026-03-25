package buf_writer

import utils "../utils"
import "core:mem"
import "core:sys/linux"
import "core:sys/posix"

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

// This should probably use linux instead of posix to be consistent but I
// couldn't get it to work
send_with_fd :: proc(writer: ^Writer($N), socket: linux.Fd, fd: linux.Fd) -> posix.Errno {
	msg := &writer.buf[0]
	msg_size := writer.buf_size

	CMSG_ALIGN :: proc(len: $T) -> T {
		return (len + size_of(u64) - 1) & (~(int(size_of(u64) - 1)))
	}
	CMSG_SPACE :: proc(len: $T) -> T {
		return CMSG_ALIGN(len) + CMSG_ALIGN(size_of(posix.cmsghdr))
	}
	CMSG_LEN :: proc(len: $T) -> T {
		return len + CMSG_ALIGN(size_of(posix.cmsghdr))
	}

	buf: [128]u8

	io := posix.iovec {
		iov_base = msg,
		iov_len  = uint(msg_size),
	}

	socket_msg := posix.msghdr {
		msg_iov        = &io,
		msg_iovlen     = 1,
		msg_control    = &buf[0],
		msg_controllen = size_of(buf),
	}

	cmsg := posix.CMSG_FIRSTHDR(&socket_msg)
	cmsg.cmsg_level = posix.SOL_SOCKET
	cmsg.cmsg_type = posix.SCM_RIGHTS
	cmsg.cmsg_len = uint(CMSG_LEN(size_of(fd)))

	(^int)(posix.CMSG_DATA(cmsg))^ = int(fd)
	socket_msg.msg_controllen = uint(CMSG_SPACE(size_of(fd)))

	bytes_sent := posix.sendmsg((posix.FD)(socket), &socket_msg, {})
	if bytes_sent != msg_size {
		return posix.errno()
	}
	return .NONE
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
write_u16_raw :: proc(buf: ^u8, buf_size: ^int, buf_cap: int, x: u16) {
	destination := mem.ptr_offset(buf, buf_size^)
	assert(buf_size^ + size_of(x) <= buf_cap)
	assert(uintptr(destination) % size_of(x) == 0)
	(^u16)(destination)^ = x
	buf_size^ += size_of(u16)
}

@(private)
write_string_raw :: proc(buf: ^u8, buf_size: ^int, buf_cap: int, src: string) {
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

write_u16 :: proc(writer: ^Writer($N), x: u16) {
	write_u16_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), x)
	get_announced_size(writer)^ += size_of(u16)
}

write_string :: proc(writer: ^Writer($N), src: string) {
	write_string_raw(&writer.buf[0], &writer.buf_size, size_of(writer.buf), src)
	get_announced_size(writer)^ += u16(size_of(u32) + utils.roundup_4(len(src)))
}
