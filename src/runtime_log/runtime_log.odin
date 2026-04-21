package runtime_log

Logger :: struct {
	blacklist: map[string]bool,
}

initialize :: proc(logger: ^Logger, blacklist: []string) {
	if logger.blacklist != nil {
		delete(logger.blacklist)
	}
	if len(blacklist) == 0 {
		logger.blacklist = nil
		return
	}
	logger.blacklist = make(map[string]bool, len(blacklist))
	for key in blacklist {
		logger.blacklist[key] = true
	}
}

cleanup :: proc(logger: ^Logger) {
	if logger.blacklist != nil {
		delete(logger.blacklist)
	}
	logger.blacklist = nil
}

should_log :: proc(logger: ^Logger, key: string) -> bool {
	if logger == nil || logger.blacklist == nil {
		return true
	}
	_, blocked := logger.blacklist[key]
	return !blocked
}
