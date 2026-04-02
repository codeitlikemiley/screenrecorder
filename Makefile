# ──────────────────────────────────────────────────────────────
#  ScreenRecorder — Makefile
#  Wraps build.sh / release.sh. All secrets live in .env.
# ──────────────────────────────────────────────────────────────

# ── Defaults (overridable via CLI) ───────────────────────────
# All secrets (SIGNING_IDENTITY, APPLE_TEAM_ID, etc.) are read
# from .env by each shell script — no need to parse it here.
APP_NAME    ?= ScreenRecorder
APP_DIR     ?= .build/ScreenRecorder.app
INSTALL_PATH ?= /Applications/$(APP_NAME).app

.PHONY: all build run install release icons clean help

all: build

# ── Build (debug) ─────────────────────────────────────────────
build:
	@bash build.sh

# ── Run (build then open) ────────────────────────────────────
run: build
	@echo "🚀 Launching $(APP_NAME)..."
	@open "$(APP_DIR)"

# ── Install to /Applications ─────────────────────────────────
install: build
	@echo "📲 Installing $(APP_NAME) to $(INSTALL_PATH)..."
	@rm -rf "$(INSTALL_PATH)"
	@cp -R "$(APP_DIR)" "$(INSTALL_PATH)"
	@echo "✅ Installed → $(INSTALL_PATH)"
	@open "$(INSTALL_PATH)"

# ── Release (sign, notarise, DMG, tag & push) ────────────────
release:
	@bash release.sh

# ── Generate app icons from a source PNG ─────────────────────
#    Usage: make icons SRC=path/to/icon-1024.png
icons:
	@bash generate_icons.sh "$(SRC)"

# ── Clean build artefacts ────────────────────────────────────
clean:
	@echo "🧹 Cleaning build artefacts..."
	@rm -rf .build
	@echo "✅ Clean"

# ── Help ─────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  ScreenRecorder — available targets"
	@echo ""
	@echo "  make build        Build debug app + CLI (wraps build.sh)"
	@echo "  make run          Build then open the debug .app"
	@echo "  make install      Build and copy to /Applications"
	@echo "  make release      Sign, notarise, DMG, tag & push (wraps release.sh)"
	@echo "  make icons SRC=…  Regenerate AppIcon.icns from a 1024×1024 PNG"
	@echo "  make clean        Remove .build/"
	@echo ""
	@echo "  All secrets are read from .env (see .env.example)"
	@echo ""
