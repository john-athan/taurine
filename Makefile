# Build, test and install a Swift app. Depends only on swiftc (Xcode command
# line tools). The same file for every Swift app in the fleet, owned by oss-kit
# (templates/shared/swift): change it there, then `oss sync-tooling`.
#
# Name and executable come from Info.plist. What one app needs beyond this
# lives in its app.mk, read last, so it can:
#   set PREFIX         where the app is installed (default /Applications)
#   set CLI := yes     link the executable onto the PATH as a command
#   add install::      steps after the copy (double-colon rules run in order)
#   add uninstall::    steps after the app is removed

NAME   := $(shell plutil -extract CFBundleName raw -o - Info.plist)
EXE    := $(shell plutil -extract CFBundleExecutable raw -o - Info.plist)
APP    := build/$(NAME).app
PREFIX ?= /Applications
BINDIR ?= /usr/local/bin
CLI    ?=

.PHONY: build test check install uninstall clean

build:
	tools/build-app.sh

test:
	tools/test.sh

check:
	tools/validate.sh

install:: build
	tools/install-app.sh "$(APP)" "$(PREFIX)"
	@if [ "$(CLI)" != yes ]; then :; \
	elif [ -w "$(BINDIR)" ]; then \
		ln -sf "$(PREFIX)/$(NAME).app/Contents/MacOS/$(EXE)" "$(BINDIR)/$(EXE)"; \
		echo "▸ linked CLI → $(BINDIR)/$(EXE)"; \
	else \
		echo "▸ CLI needs one manual step:"; \
		echo "    sudo ln -sf $(PREFIX)/$(NAME).app/Contents/MacOS/$(EXE) $(BINDIR)/$(EXE)"; \
	fi

uninstall::
	-pkill -f "$(PREFIX)/$(NAME).app" 2>/dev/null || true
	rm -rf "$(PREFIX)/$(NAME).app"
	@if [ "$(CLI)" = yes ] && [ -L "$(BINDIR)/$(EXE)" ]; then \
		rm -f "$(BINDIR)/$(EXE)" 2>/dev/null || echo "▸ remove the CLI link with: sudo rm $(BINDIR)/$(EXE)"; \
	fi
	@echo "▸ removed $(NAME)"

clean:
	rm -rf build .build

-include app.mk
