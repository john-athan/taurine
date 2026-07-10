# Taurine — build & install. Depends only on swiftc (Xcode command line tools).
APP     := Taurine.app
PREFIX  ?= /Applications
BINDIR  ?= /usr/local/bin

.PHONY: build install uninstall clean

build:
	./build.sh

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

uninstall:
	-pkill -f "$(PREFIX)/$(APP)" 2>/dev/null || true
	rm -rf "$(PREFIX)/$(APP)"
	rm -f "$(BINDIR)/taurine"
	@echo "▸ removed Taurine"

clean:
	rm -rf "$(APP)"
