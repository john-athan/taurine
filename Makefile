# Taurine, build & install. Depends only on swiftc (Xcode command line tools).
APP     := Taurine.app
PREFIX  ?= /Applications
BINDIR  ?= /usr/local/bin

# The charge daemon older versions installed (ADR 11). Only uninstall knows it.
DAEMON  := io.github.john-athan.taurine.charge
SUPPORT := /Library/Application Support/Taurine
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
	open "$(PREFIX)/$(APP)"

# The old charge daemon holds a bit in the SMC, not in a file, so its helper is
# told to let go before it is deleted.
uninstall:
	@if [ -f "/Library/LaunchDaemons/$(DAEMON).plist" ]; then \
		echo "▸ releasing the charge limit (needs sudo)…"; \
		sudo "$(HELPER)" --charge-unlock || true; \
		sudo launchctl bootout system/$(DAEMON) 2>/dev/null || true; \
		sudo rm -f "/Library/LaunchDaemons/$(DAEMON).plist"; \
		sudo rm -f "$(HELPER)"; \
		sudo rm -rf "$(SUPPORT)"; \
		echo "▸ removed the old charge daemon"; \
	fi
	-pkill -f "$(PREFIX)/$(APP)" 2>/dev/null || true
	rm -rf "$(PREFIX)/$(APP)"
	rm -f "$(BINDIR)/taurine"
	@echo "▸ removed Taurine"

clean:
	rm -rf "$(APP)" .build
