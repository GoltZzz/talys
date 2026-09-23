.PHONY: all build zig swift app icon run clean install-agent uninstall-agent

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
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "==> Ad-hoc signing $(APP_BUNDLE)..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@# Make Finder/Spotlight pick up icon changes instead of a cached copy.
	@touch $(APP_BUNDLE)
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(APP_BUNDLE)
	@echo "==> Built $(APP_BUNDLE) successfully."

# Regenerates Resources/AppIcon.icns and Resources/logo.svg from Sources/Talys/TalysLogo.swift.
icon:
	@echo "==> Rendering app icon..."
	@mkdir -p .build/icon/AppIcon.iconset
	@swiftc -O scripts/make-icon/main.swift Sources/Talys/TalysLogo.swift -o .build/icon/make-icon
	@.build/icon/make-icon .build/icon/icon-1024.png Resources/logo.svg
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s .build/icon/icon-1024.png --out .build/icon/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) .build/icon/icon-1024.png --out .build/icon/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	@iconutil -c icns .build/icon/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "==> Resources/AppIcon.icns ready."

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
	@# A crashed or force-quit run never gave the Spotlight/Mission Control shortcuts back; do it now.
	@if [ -x /Applications/$(BIN_PATH) ]; then /Applications/$(BIN_PATH) --restore-shortcuts; \
	elif [ -x $(BIN_PATH) ]; then ./$(BIN_PATH) --restore-shortcuts; fi
	@rm -f $(LAUNCH_AGENT)
	@echo "==> LaunchAgent removed."
