PREFIX_BIN := $(HOME)/.local/bin
AGENTS_DIR := $(HOME)/Library/LaunchAgents
PLIST := com.hotingyuen.ccgovd.plist
# GOVERN=1 lets the installed daemon demote and hibernate every interactive Claude session on this Mac.
# Default is read-only (index + metrics only).
GOVERN ?= 0
GOVERN_ARG := $(if $(filter 1,$(GOVERN)),<string>--govern</string>,)

.PHONY: build test install-daemon

build:
	swift build

test:
	swift test

# Copies the release binary and the plist. Does NOT run launchctl; the bootstrap command is printed for you to run.
install-daemon:
	swift build -c release
	mkdir -p "$(PREFIX_BIN)" "$(AGENTS_DIR)" "$(HOME)/Library/Logs"
	install -m 755 "$$(swift build -c release --show-bin-path)/ccgovd" "$(PREFIX_BIN)/ccgovd"
	sed -e "s|__HOME__|$(HOME)|g" -e "s|__GOVERN_ARG__|$(GOVERN_ARG)|" launchd/$(PLIST) > "$(AGENTS_DIR)/$(PLIST)"
	plutil -lint "$(AGENTS_DIR)/$(PLIST)"
	@echo "Installed $(PREFIX_BIN)/ccgovd and $(AGENTS_DIR)/$(PLIST) (govern=$(GOVERN))."
	@echo "Start it with:"
	@echo "  launchctl bootstrap gui/$$(id -u) $(AGENTS_DIR)/$(PLIST)"
	@echo "Stop it with:"
	@echo "  launchctl bootout gui/$$(id -u) $(AGENTS_DIR)/$(PLIST)"
