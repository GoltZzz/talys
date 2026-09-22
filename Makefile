.PHONY: all build zig swift app run clean install-agent uninstall-agent

APP_NAME = Talys
APP_BUNDLE = $(APP_NAME).app
BIN_PATH = $(APP_BUNDLE)/Contents/MacOS/talys
LAUNCH_AGENT = ~/Library/LaunchAgents/com.talys.wm.plist

all: build

zig:
	@echo "==> Building Zig tiling engine..."
	@cd zig-engine && zig build -Doptimize=ReleaseFast
	@echo "==> Re-packing archive for Apple linker alignment..."
	@mkdir -p /tmp/talys_align && \
		cd /tmp/talys_align && \
		cp $(CURDIR)/zig-engine/zig-out/lib/libtalys_engine.a . && \
		ar -x libtalys_engine.a && \
		chmod 644 *.o && \
		libtool -static -o libtalys_engine.a *.o && \
		ranlib libtalys_engine.a && \
		cp libtalys_engine.a $(CURDIR)/Sources/CTalysEngine/libtalys_engine.a && \
		rm -rf /tmp/talys_align
	@echo "==> libtalys_engine.a ready in Sources/CTalysEngine/"

swift: zig
	@echo "==> Building Swift executable..."
	@swift build -c release

app: swift
	@echo "==> Assembling $(APP_BUNDLE)..."
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp .build/release/talys $(APP_BUNDLE)/Contents/MacOS/talys
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@echo "==> Ad-hoc signing $(APP_BUNDLE)..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "==> Built $(APP_BUNDLE) successfully."

build: app

run: build
	@echo "==> Starting $(APP_NAME)..."
	@./$(BIN_PATH)

clean:
	@echo "==> Cleaning build artifacts..."
	@rm -rf .build
	@rm -rf $(APP_BUNDLE)
	@rm -rf zig-engine/zig-out zig-engine/.zig-cache
	@rm -f Sources/CTalysEngine/libtalys_engine.a
	@echo "==> Clean complete."

install-agent: app
	@echo "==> Installing LaunchAgent..."
	@mkdir -p ~/Library/LaunchAgents
	@cp Resources/com.talys.wm.plist $(LAUNCH_AGENT)
	@launchctl bootstrap gui/$$(id -u) $(LAUNCH_AGENT)
	@echo "==> LaunchAgent loaded."

uninstall-agent:
	@echo "==> Unloading LaunchAgent..."
	@launchctl bootout gui/$$(id -u)/com.talys.wm 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT)
	@echo "==> LaunchAgent removed."
