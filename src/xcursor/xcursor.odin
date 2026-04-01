package XCursor

import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

// ---- public types ----

Dim :: u32
Pixel :: u32

// Image holds a single cursor image frame.
Image :: struct {
	version: u32,
	size:    Dim, // nominal size for matching
	width:   Dim,
	height:  Dim,
	xhot:    Dim, // hot spot x
	yhot:    Dim, // hot spot y
	delay:   u32, // animation delay to next frame (ms)
	pixels:  []Pixel,
}

// Images holds a set of cursor image frames (one per animation step).
Images :: struct {
	images: [dynamic]^Image,
	name:   string,
}

// File is an abstract file handle with pluggable I/O operations.
// closure holds any state needed by the read/write/seek procs.
File :: struct {
	closure: rawptr,
	read:    proc(file: ^File, buf: []u8) -> int,
	write:   proc(file: ^File, buf: []u8) -> int,
	seek:    proc(file: ^File, offset: i64, whence: int) -> bool,
}

// ---- public constants ----

MAGIC :: u32(0x72756358) // "Xcur" LSBFirst
IMAGE_TYPE :: u32(0xfffd0002)
IMAGE_VERSION :: u32(1)
IMAGE_MAX_SIZE :: u32(0x7fff)
COMMENT_TYPE :: u32(0xfffe0001)

// ---- internal file format types ----

@(private)
File_Toc :: struct {
	type:     u32,
	subtype:  u32,
	position: u32,
}

@(private)
File_Header :: struct {
	magic:   u32,
	header:  u32,
	version: u32,
	ntoc:    u32,
	tocs:    []File_Toc,
}

@(private)
Chunk_Header :: struct {
	header:  u32,
	type:    u32,
	subtype: u32,
	version: u32,
}

// ---- private constants ----

@(private)
FILE_MAJOR :: u32(1)
@(private)
FILE_MINOR :: u32(0)
@(private)
FILE_VERSION :: (FILE_MAJOR << 16) | FILE_MINOR
@(private)
FILE_HEADER_LEN :: u32(4 * 4)

@(private)
SEEK_SET :: int(0)
@(private)
SEEK_CUR :: int(1)

@(private)
PATH_MAX :: 4096

@(private)
ICONDIR :: "/usr/X11R6/lib/X11/icons"
@(private)
XCURSORPATH_DEFAULT :: "~/.icons:/usr/share/icons:/usr/share/pixmaps:" + ICONDIR


// ---- public procs ----

image_create :: proc(width, height: u32) -> ^Image {
	image := new(Image)
	image.version = IMAGE_VERSION
	image.size = max(width, height)
	image.width = width
	image.height = height
	image.delay = 0
	image.pixels = make([]Pixel, int(width) * int(height))
	return image
}

image_destroy :: proc(image: ^Image) {
	if image == nil do return
	delete(image.pixels)
	free(image)
}

images_create :: proc(cap: int) -> ^Images {
	images := new(Images)
	images.images = make([dynamic]^Image, 0, cap)
	return images
}

images_destroy :: proc(images: ^Images) {
	if images == nil do return
	for img in images.images {
		image_destroy(img)
	}
	delete(images.images)
	if images.name != "" {
		delete(images.name)
	}
	free(images)
}

images_set_name :: proc(images: ^Images, name: string) {
	if images == nil || name == "" do return
	if images.name != "" {
		delete(images.name)
	}
	images.name = strings.clone(name)
}

// xcfile_load_images loads cursor images of the nearest-matching size from
// an abstract File.
xcfile_load_images :: proc(file: ^File, size: int) -> ^Images {
	if file == nil || size < 0 do return nil

	fh := _read_file_header(file)
	if fh == nil do return nil
	defer _file_header_destroy(fh)

	best_size, nsize := _find_best_size(fh, Dim(size))
	if best_size == 0 do return nil

	images := images_create(nsize)
	if images == nil do return nil

	for n in 0 ..< nsize {
		toc := _find_image_toc(fh, best_size, n)
		if toc < 0 do break
		img := _read_image(file, fh, toc)
		if img == nil do break
		append(&images.images, img)
	}

	if len(images.images) != nsize {
		images_destroy(images)
		return nil
	}
	return images
}

// file_load_images loads cursor images from an open file descriptor.
// Does not close fd.
file_load_images :: proc(fd: linux.Fd, size: int) -> ^Images {
	if fd < 0 do return nil
	f: File
	_stdio_file_init(&f, fd)
	return xcfile_load_images(&f, size)
}

// library_load_images loads cursor images by name from a theme directory,
// falling back to "default" if the named theme does not have the cursor.
library_load_images :: proc(name, theme: string, size: int) -> ^Images {
	if name == "" do return nil

	fd := linux.Fd(-1)
	if theme != "" {
		fd = _scan_theme(theme, name)
	}
	if fd < 0 {
		fd = _scan_theme("default", name)
	}
	if fd < 0 do return nil
	defer linux.close(fd)

	images := file_load_images(fd, size)
	if images != nil {
		images_set_name(images, name)
	}
	return images
}

// load_theme loads every cursor in a theme (and its inherited themes),
// calling load_callback for each XcursorImages set found.
// The caller is responsible for calling images_destroy on the Images
// passed to the callback.
load_theme :: proc(
	theme: string,
	size: int,
	load_callback: proc(_: ^Images, _: rawptr),
	user_data: rawptr,
) {
	t := theme if theme != "" else "default"

	path := _library_path()
	inherits := ""

	p := path
	for p != "" {
		dir := _build_theme_dir(p, t)
		if dir != "" {
			cursor_dir := _build_fullname(dir, "cursors", "")
			if cursor_dir != "" {
				_load_all_cursors_from_dir(cursor_dir, size, load_callback, user_data)
				delete(cursor_dir)
			}
			if inherits == "" {
				full := _build_fullname(dir, "", "index.theme")
				if full != "" {
					inherits = _theme_inherits(full)
					delete(full)
				}
			}
			delete(dir)
		}
		p = _next_path(p)
	}

	i := inherits
	for i != "" {
		load_theme(i, size, load_callback, user_data)
		i = _next_path(i)
	}
	if inherits != "" do delete(inherits)
}

// ---- private helpers: wire reading ----

@(private)
_read_uint :: proc(file: ^File) -> (u: u32, ok: bool) {
	b: [4]u8
	if file.read(file, b[:]) != 4 do return 0, false
	return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24), true
}

@(private)
_file_header_create :: proc(ntoc: u32) -> ^File_Header {
	if ntoc > 0x10000 do return nil
	h := new(File_Header)
	h.tocs = make([]File_Toc, ntoc)
	return h
}

@(private)
_file_header_destroy :: proc(h: ^File_Header) {
	if h == nil do return
	delete(h.tocs)
	free(h)
}

@(private)
_read_file_header :: proc(file: ^File) -> ^File_Header {
	if file == nil do return nil

	magic, ok := _read_uint(file)
	if !ok || magic != MAGIC do return nil

	hlen, ok1 := _read_uint(file)
	ver, ok2 := _read_uint(file)
	ntoc, ok3 := _read_uint(file)
	if !ok1 || !ok2 || !ok3 do return nil

	skip := i64(hlen) - i64(FILE_HEADER_LEN)
	if skip > 0 && !file.seek(file, skip, SEEK_CUR) do return nil

	fh := _file_header_create(ntoc)
	if fh == nil do return nil
	fh.magic = magic
	fh.header = hlen
	fh.version = ver
	fh.ntoc = ntoc

	for n in 0 ..< int(ntoc) {
		t, ok_t := _read_uint(file)
		s, ok_s := _read_uint(file)
		p, ok_p := _read_uint(file)
		if !ok_t || !ok_s || !ok_p {
			_file_header_destroy(fh)
			return nil
		}
		fh.tocs[n] = {
			type     = t,
			subtype  = s,
			position = p,
		}
	}
	return fh
}

@(private)
_seek_to_toc :: proc(file: ^File, fh: ^File_Header, toc: int) -> bool {
	if file == nil || fh == nil do return false
	return file.seek(file, i64(fh.tocs[toc].position), SEEK_SET)
}

@(private)
_read_chunk_header :: proc(
	file: ^File,
	fh: ^File_Header,
	toc: int,
) -> (
	ch: Chunk_Header,
	ok: bool,
) {
	if file == nil || fh == nil do return {}, false
	if !_seek_to_toc(file, fh, toc) do return {}, false
	ch.header, ok = _read_uint(file); if !ok do return {}, false
	ch.type, ok = _read_uint(file); if !ok do return {}, false
	ch.subtype, ok = _read_uint(file); if !ok do return {}, false
	ch.version, ok = _read_uint(file); if !ok do return {}, false
	if ch.type != fh.tocs[toc].type || ch.subtype != fh.tocs[toc].subtype {
		return {}, false
	}
	return ch, true
}

@(private)
_dist :: #force_inline proc(a, b: Dim) -> Dim {
	return a > b ? a - b : b - a
}

@(private)
_find_best_size :: proc(fh: ^File_Header, size: Dim) -> (best_size: Dim, nsize: int) {
	if fh == nil do return 0, 0
	for n in 0 ..< int(fh.ntoc) {
		if fh.tocs[n].type != IMAGE_TYPE do continue
		this_size := fh.tocs[n].subtype
		if best_size == 0 || _dist(this_size, size) < _dist(best_size, size) {
			best_size = this_size
			nsize = 1
		} else if this_size == best_size {
			nsize += 1
		}
	}
	return
}

@(private)
_find_image_toc :: proc(fh: ^File_Header, size: Dim, count: int) -> int {
	if fh == nil do return -1
	c := count
	for toc in 0 ..< int(fh.ntoc) {
		if fh.tocs[toc].type != IMAGE_TYPE do continue
		if fh.tocs[toc].subtype != size do continue
		if c == 0 do return toc
		c -= 1
	}
	return -1
}

@(private)
_read_image :: proc(file: ^File, fh: ^File_Header, toc: int) -> ^Image {
	if file == nil || fh == nil do return nil

	ch, ok := _read_chunk_header(file, fh, toc)
	if !ok do return nil

	width, ok1 := _read_uint(file)
	height, ok2 := _read_uint(file)
	xhot, ok3 := _read_uint(file)
	yhot, ok4 := _read_uint(file)
	delay, ok5 := _read_uint(file)
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 do return nil

	if width >= 0x10000 || height > 0x10000 do return nil
	if width == 0 || height == 0 do return nil
	if xhot > width || yhot > height do return nil

	image := image_create(width, height)
	if ch.version < image.version do image.version = ch.version
	image.size = ch.subtype
	image.xhot = xhot
	image.yhot = yhot
	image.delay = delay

	for i in 0 ..< len(image.pixels) {
		p, ok_p := _read_uint(file)
		if !ok_p {
			image_destroy(image)
			return nil
		}
		image.pixels[i] = p
	}
	return image
}

// ---- private helpers: stdio File implementation ----

@(private)
_stdio_read :: proc(file: ^File, buf: []u8) -> int {
	fd := linux.Fd(int(uintptr(file.closure)))
	n, err := linux.read(fd, buf)
	if err != nil do return 0
	return n
}

@(private)
_stdio_write :: proc(file: ^File, buf: []u8) -> int {
	fd := linux.Fd(int(uintptr(file.closure)))
	n, err := linux.write(fd, buf)
	if err != nil do return 0
	return n
}

@(private)
_stdio_seek :: proc(file: ^File, offset: i64, whence: int) -> bool {
	fd := linux.Fd(int(uintptr(file.closure)))
	lwhence := linux.Seek_Whence(whence)
	_, err := linux.lseek(fd, offset, lwhence)
	return err == nil
}

@(private)
_stdio_file_init :: proc(f: ^File, fd: linux.Fd) {
	f.closure = rawptr(uintptr(int(fd)))
	f.read = _stdio_read
	f.write = _stdio_write
	f.seek = _stdio_seek
}

// ---- private helpers: path and theme resolution ----

// _library_path returns the XCursor search path from the environment or the
// built-in default. Returns a string that must NOT be deleted — it is either
// a pointer into the process environment or a string literal.
@(private)
_library_path :: proc() -> string {
	env := posix.getenv("XCURSOR_PATH")
	if env != nil do return string(env)
	return XCURSORPATH_DEFAULT
}

// _to_cstring copies s into buf (which must be at least len(s)+1 bytes),
// appends a null terminator, and returns a cstring pointing into buf.
@(private)
_to_cstring :: proc(s: string, buf: []u8) -> (cstring, bool) {
	if len(s) >= len(buf) do return nil, false
	copy(buf[:len(s)], s)
	buf[len(s)] = 0
	return cstring(&buf[0]), true
}

// _add_path_elt appends elt[:n] (or all of elt when n == -1) to b,
// ensuring exactly one '/' separator between the existing content and elt,
// and stripping any leading '/' from elt.
@(private)
_add_path_elt :: proc(b: ^strings.Builder, elt: string, n: int = -1) {
	s := strings.to_string(b^)
	if len(s) == 0 || s[len(s) - 1] != '/' {
		strings.write_byte(b, '/')
	}
	e := elt
	l := len(elt) if n == -1 else n
	for l > 0 && len(e) > 0 && e[0] == '/' {
		e = e[1:]
		l -= 1
	}
	if l > 0 {
		strings.write_string(b, e[:l])
	}
}

// _build_theme_dir returns an allocated "<home><dir>/<theme>" path,
// expanding a leading '~' to $HOME. Caller must delete the result.
@(private)
_build_theme_dir :: proc(dir, theme: string) -> string {
	if dir == "" || theme == "" do return ""

	dir_len := strings.index(dir, ":")
	if dir_len == -1 do dir_len = len(dir)

	theme_len := strings.index(theme, ":")
	if theme_len == -1 do theme_len = len(theme)

	home := ""
	d := dir[:dir_len]
	if len(d) > 0 && d[0] == '~' {
		home_cstr := posix.getenv("HOME")
		if home_cstr == nil do return ""
		home = string(home_cstr)
		d = d[1:]
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	if home != "" do _add_path_elt(&b, home)
	_add_path_elt(&b, d)
	_add_path_elt(&b, theme[:theme_len])

	return strings.clone(strings.to_string(b))
}

// _build_fullname returns an allocated "<dir>/<subdir>/<file>" path.
// Empty subdir or file become bare '/' separators (matching C behaviour).
// Caller must delete the result.
@(private)
_build_fullname :: proc(dir, subdir, file: string) -> string {
	if dir == "" do return ""
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	_add_path_elt(&b, dir)
	_add_path_elt(&b, subdir)
	_add_path_elt(&b, file)
	return strings.clone(strings.to_string(b))
}

// _next_path advances past the first ':' in path, returning the remainder,
// or "" if there is no ':'.
@(private)
_next_path :: proc(path: string) -> string {
	i := strings.index(path, ":")
	if i == -1 do return ""
	return path[i + 1:]
}

// _theme_inherits reads the "Inherits=" line from an index.theme file and
// returns a colon-separated list of parent theme names.
// Caller must delete the result (or it may be "").
@(private)
_theme_inherits :: proc(full: string) -> string {
	path_buf: [PATH_MAX]u8
	path_cstr, ok := _to_cstring(full, path_buf[:])
	if !ok do return ""

	fd, err := linux.open(path_cstr, {})
	if err != nil do return ""
	defer linux.close(fd)

	file_buf: [8192]u8
	n, _ := linux.read(fd, file_buf[:])
	if n <= 0 do return ""

	content := string(file_buf[:n])
	pos := 0
	for pos < len(content) {
		end := pos
		for end < len(content) && content[end] != '\n' {
			end += 1
		}
		line := content[pos:end]
		pos = end + 1

		if !strings.has_prefix(line, "Inherits") do continue
		rest := line[len("Inherits"):]
		rest = strings.trim_left(rest, " \t")
		if len(rest) == 0 || rest[0] != '=' do continue
		rest = rest[1:]
		rest = strings.trim_left(rest, " \t")

		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		first := true
		for len(rest) > 0 {
			// skip separators (';', ',') and whitespace
			for len(rest) > 0 &&
			    (rest[0] == ';' ||
					    rest[0] == ',' ||
					    rest[0] == ' ' ||
					    rest[0] == '\t' ||
					    rest[0] == '\r') {
				rest = rest[1:]
			}
			if len(rest) == 0 do break
			if !first do strings.write_byte(&b, ':')
			first = false
			for len(rest) > 0 &&
			    rest[0] != ' ' &&
			    rest[0] != '\t' &&
			    rest[0] != '\r' &&
			    rest[0] != ';' &&
			    rest[0] != ',' {
				strings.write_byte(&b, rest[0])
				rest = rest[1:]
			}
		}
		return strings.clone(strings.to_string(b))
	}
	return ""
}

// _scan_theme searches the theme and its inherited themes for a cursor file
// named `name`. Returns an open fd (caller must close) or -1 on failure.
@(private)
_scan_theme :: proc(theme, name: string) -> linux.Fd {
	if theme == "" || name == "" do return -1

	path := _library_path()
	inherits := ""
	result := linux.Fd(-1)

	p := path
	for p != "" && result < 0 {
		dir := _build_theme_dir(p, theme)
		if dir != "" {
			full := _build_fullname(dir, "cursors", name)
			if full != "" {
				path_buf: [PATH_MAX]u8
				if path_cstr, pok := _to_cstring(full, path_buf[:]); pok {
					fd, ferr := linux.open(path_cstr, {})
					if ferr == nil {
						result = fd
					}
				}
				delete(full)
			}
			if result < 0 && inherits == "" {
				full2 := _build_fullname(dir, "", "index.theme")
				if full2 != "" {
					inherits = _theme_inherits(full2)
					delete(full2)
				}
			}
			delete(dir)
		}
		p = _next_path(p)
	}

	i := inherits
	for i != "" && result < 0 {
		result = _scan_theme(i, name)
		i = _next_path(i)
	}
	if inherits != "" do delete(inherits)
	return result
}

// _load_all_cursors_from_dir opens every regular file in `path` as a cursor
// file and calls load_callback with the resulting Images.
@(private)
_load_all_cursors_from_dir :: proc(
	path: string,
	size: int,
	load_callback: proc(_: ^Images, _: rawptr),
	user_data: rawptr,
) {
	path_buf: [PATH_MAX]u8
	path_cstr, ok := _to_cstring(path, path_buf[:])
	if !ok do return

	dir := posix.opendir(path_cstr)
	if dir == nil do return
	defer posix.closedir(dir)

	for {
		entry := posix.readdir(dir)
		if entry == nil do break

		name_cstr := cstring(rawptr(&entry.d_name[0]))
		name := string(name_cstr)
		if name == "." || name == ".." do continue

		// skip non-regular files when the type is known
		if entry.d_type != .UNKNOWN && entry.d_type != .REG && entry.d_type != .LNK {
			continue
		}

		full := _build_fullname(path, "", name)
		if full == "" do continue

		full_buf: [PATH_MAX]u8
		full_cstr, full_ok := _to_cstring(full, full_buf[:])
		delete(full)
		if !full_ok do continue

		fd, ferr := linux.open(full_cstr, {})
		if ferr != nil do continue

		images := file_load_images(fd, size)
		linux.close(fd)

		if images != nil {
			images_set_name(images, name)
			load_callback(images, user_data)
		}
	}
}
