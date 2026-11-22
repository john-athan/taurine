# What Taurine needs beyond the shared Makefile (oss-kit, templates/shared/swift).
CLI := yes

install::
	open "$(PREFIX)/$(NAME).app"

# The charge daemon older versions installed (ADR 11). It holds a bit in the
# SMC, not in a file, so its helper is told to let go before it is deleted.
DAEMON  := io.github.john-athan.taurine.charge
SUPPORT := /Library/Application Support/Taurine
HELPER  := /Library/PrivilegedHelperTools/$(DAEMON)

uninstall::
	@if [ -f "/Library/LaunchDaemons/$(DAEMON).plist" ]; then \
		echo "▸ releasing the charge limit (needs sudo)…"; \
		sudo "$(HELPER)" --charge-unlock || true; \
		sudo launchctl bootout system/$(DAEMON) 2>/dev/null || true; \
		sudo rm -f "/Library/LaunchDaemons/$(DAEMON).plist"; \
		sudo rm -f "$(HELPER)"; \
		sudo rm -rf "$(SUPPORT)"; \
		echo "▸ removed the old charge daemon"; \
	fi
