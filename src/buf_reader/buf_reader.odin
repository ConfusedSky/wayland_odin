package buf_reader

import utils "../utils"
import "core:mem"

read_u32 :: proc(buf: ^^u8, buf_size: ^int) -> u32 {
	assert(buf_size^ >= size_of(u32))
	assert(uintptr(buf^) % size_of(u32) == 0)
	res := (^u32)(buf^)^
	buf^ = mem.ptr_offset(buf^, size_of(u32))
	buf_size^ -= size_of(u32)
	return res
}

read_u16 :: proc(buf: ^^u8, buf_size: ^int) -> u16 {
	assert(buf_size^ >= size_of(u16))
	assert(uintptr(buf^) % size_of(u16) == 0)
	res := (^u16)(buf^)^
	buf^ = mem.ptr_offset(buf^, size_of(u16))
	buf_size^ -= size_of(u16)
	return res
}

read_i32 :: proc(buf: ^^u8, buf_size: ^int) -> i32 {
	assert(buf_size^ >= size_of(i32))
	assert(uintptr(buf^) % size_of(i32) == 0)
	res := (^i32)(buf^)^
	buf^ = mem.ptr_offset(buf^, size_of(i32))
	buf_size^ -= size_of(i32)
	return res
}

read_fixed :: proc(buf: ^^u8, buf_size: ^int) -> f64 {
	return f64(read_i32(buf, buf_size)) / 256
}

// read_string reads a Wayland length-prefixed, null-terminated, 4-byte-padded string.
// The length prefix includes the null terminator; the returned string does not.
// Allocates with the provided allocator; caller must delete.
read_string :: proc(buf: ^^u8, buf_size: ^int, allocator := context.allocator) -> string {
	length := int(read_u32(buf, buf_size))
	padded := utils.roundup_4(length)
	assert(buf_size^ >= padded)
	content_len := max(length - 1, 0)
	result := make([]u8, content_len, allocator)
	if content_len > 0 {
		mem.copy(raw_data(result), buf^, content_len)
	}
	buf^ = mem.ptr_offset(buf^, padded)
	buf_size^ -= padded
	return string(result)
}

// read_array reads a Wayland length-prefixed, 4-byte-padded byte array.
// Allocates with the provided allocator; caller must delete.
read_array :: proc(buf: ^^u8, buf_size: ^int, allocator := context.allocator) -> []u8 {
	length := int(read_u32(buf, buf_size))
	padded := utils.roundup_4(length)
	assert(buf_size^ >= padded)
	result := make([]u8, length, allocator)
	if length > 0 {
		mem.copy(raw_data(result), buf^, length)
	}
	buf^ = mem.ptr_offset(buf^, padded)
	buf_size^ -= padded
	return result
}
