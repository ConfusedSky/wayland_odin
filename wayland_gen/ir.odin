package wayland_gen

Arg :: struct {
	name:      string,
	type:      string,
	interface: string,
	enum_ref:  string,
	summary:   string,
}

Description :: struct {
	summary: string,
	body:    string,
}

Request :: struct {
	name:        string,
	opcode:      int,
	args:        [dynamic]Arg,
	description: Maybe(Description),
}

Event :: struct {
	name:        string,
	opcode:      int,
	args:        [dynamic]Arg,
	description: Maybe(Description),
}

EnumEntry :: struct {
	name:    string,
	value:   string,
	summary: string,
}

Enum :: struct {
	name:        string,
	bitfield:    bool,
	entries:     [dynamic]EnumEntry,
	description: Maybe(Description),
}

Interface :: struct {
	name:        string,
	version:     string,
	requests:    [dynamic]Request,
	events:      [dynamic]Event,
	enums:       [dynamic]Enum,
	description: Maybe(Description),
}

Protocol :: struct {
	name:       string,
	interfaces: [dynamic]Interface,
}

