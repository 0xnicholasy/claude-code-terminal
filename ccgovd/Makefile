PREFIX_BIN := $(HOME)/.local/bin
AGENTS_DIR := $(HOME)/Library/LaunchAgents
PLIST := com.hotingyuen.ccgovd.plist

.PHONY: build test install-daemon

build:
	swift build

test:
	swift test

# Copies the release binary and the plist. Does NOT run launchctl; the bootstrap command is printed for you to run.
install-daemon:
	swift build -c release
	mkdir -p "$(PREFIX_BIN)" "$(AGENTS_DIR)" "$(HOME)/Library/Logs"
	cp "$$(swift build -c release --show-bin-path)/ccgovd" "$(PREFIX_BIN)/ccgovd"
	sed "s|__HOME__|$(HOME)|g" launchd/$(PLIST) > "$(AGENTS_DIR)/$(PLIST)"
	@echo "Installed $(PREFIX_BIN)/ccgovd and $(AGENTS_DIR)/$(PLIST)."
	@echo "Start it with:"
	@echo "  launchctl bootstrap gui/$$(id -u) $(AGENTS_DIR)/$(PLIST)"
	@echo "Stop it with:"
	@echo "  launchctl bootout gui/$$(id -u) $(AGENTS_DIR)/$(PLIST)"
