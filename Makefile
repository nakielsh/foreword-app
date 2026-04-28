.PHONY: build test local-install reset-icon-cache

XCODEPROJ := WorkHomepage/WorkHomepage.xcodeproj
SCHEME    := WorkHomepage
CONFIG    := Release
BUILD_DIR := build
APP_NAME  := WorkHomepage.app
SRC_APP   := $(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)
DEST_APP  := /Applications/$(APP_NAME)

build:
	xcodebuild \
	  -project $(XCODEPROJ) \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD_DIR)

test:
	xcodebuild test \
	  -project $(XCODEPROJ) \
	  -scheme $(SCHEME)

# Build, copy to /Applications, and invalidate the macOS IconServices cache
# so Stage Manager / Mission Control / app-switcher pick up a fresh icon. The
# Dock has its own pipeline and usually refreshes without the cache reset,
# which is why the icon can look correct in the Dock but blank in Stage Manager.
local-install: build
	rm -rf "$(DEST_APP)"
	cp -R "$(SRC_APP)" /Applications/
	$(MAKE) reset-icon-cache

reset-icon-cache:
	touch "$(DEST_APP)"
	/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
	  -f "$(DEST_APP)" || true
	killall Dock || true
	killall Finder || true
