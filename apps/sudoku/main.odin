package demo

import "core:fmt"
import "core:os"
import "src:runner"

main :: proc() {
	state: State
	if err := runner.run(
		runner.AppConfig {
			title = "odin",
			min_w = 50,
			min_h = 50,
			log_blacklist = log_blacklist,
			user_data = &state,
			on_init = on_init,
			on_frame = on_frame,
			on_shutdown = on_shutdown,
		},
	); err != nil {
		fmt.eprintfln("Fatal error: %v", err)
		os.exit(int(err))
	}
}
