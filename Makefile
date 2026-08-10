# Taurine — build & install. Depends only on swiftc (Xcode command line tools).
APP     := Taurine.app
PREFIX  ?= /Applications
BINDIR  ?= /usr/local/bin

DAEMON  := io.github.john-athan.taurine.charge
SUPPORT := /Library/Application Support/Taurine
# launchd runs a root-owned copy, not the bundle in /Applications (which is
# group-writable by admin and so must never be a root LaunchDaemon target).
HELPER  := /Library/PrivilegedHelperTools/$(DAEMON)

.PHONY: build test install uninstall clean

build:
	./build.sh

test:
	./Tests/run.sh

install: build
	rm -rf "$(PREFIX)/$(APP)"
	cp -R "$(APP)" "$(PREFIX)/"
	@echo "▸ installed $(PREFIX)/$(APP)"
	@if [ -w "$(BINDIR)" ]; then \
		ln -sf "$(PREFIX)/$(APP)/Contents/MacOS/taurine" "$(BINDIR)/taurine"; \
		echo "▸ linked CLI → $(BINDIR)/taurine"; \
	else \
		echo "▸ CLI needs one manual step:"; \
		echo "    sudo ln -sf $(PREFIX)/$(APP)/Contents/MacOS/taurine $(BINDIR)/taurine"; \
	fi
	@if [ -f "$(HELPER)" ]; then \
		echo "▸ refreshing the charge daemon copy (needs sudo)…"; \
		sudo install -p -o root -g wheel -m 755 "$(PREFIX)/$(APP)/Contents/MacOS/taurine" "$(HELPER)"; \
		sudo launchctl kickstart -k system/$(DAEMON) 2>/dev/null || true; \
	fi
	open "$(PREFIX)/$(APP)"

# Order matters. The charge daemon holds a bit in the SMC, not in a file, so it
# has to be told to let go *before* its binary disappears. Removing the app
# first would leave a Mac that refuses to charge and nothing left to fix it with.
uninstall:
	@if [ -f "/Library/LaunchDaemons/$(DAEMON).plist" ]; then \
		echo "▸ releasing the charge limit (needs sudo)…"; \
		sudo "$(HELPER)" --charge-unlock || true; \
		sudo launchctl bootout system/$(DAEMON) 2>/dev/null || true; \
		sudo rm -f "/Library/LaunchDaemons/$(DAEMON).plist"; \
		sudo rm -f "$(HELPER)"; \
		sudo rm -rf "$(SUPPORT)"; \
		echo "▸ removed the charge daemon"; \
	fi
	-pkill -f "$(PREFIX)/$(APP)" 2>/dev/null || true
	rm -rf "$(PREFIX)/$(APP)"
	rm -f "$(BINDIR)/taurine"
	@echo "▸ removed Taurine"

clean:
	rm -rf "$(APP)" .build
