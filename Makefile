.PHONY: build test local-install reset-icon-cache clean-derived-data

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

# Wipe per-workspace Xcode DerivedData folders for this project. Each git
# worktree (and each Claude agent worktree) creates a fresh
# ~/Library/Developer/Xcode/DerivedData/WorkHomepage-<hash> directory
# containing a Debug WorkHomepage.app bundle, which Spotlight / Launchpad /
# Raycast then surface as a separate "WorkHomepage" entry. Running this
# leaves the canonical /Applications/WorkHomepage.app alone and forces Xcode
# / xcodebuild to rebuild any worktree on next invocation. lsregister kicks
# Launch Services so the stale entries disappear from app pickers without a
# logout.
clean-derived-data:
	@count=$$(/bin/ls -1d ~/Library/Developer/Xcode/DerivedData/WorkHomepage-* 2>/dev/null | wc -l | tr -d ' '); \
	  if [ "$$count" -eq 0 ]; then \
	    echo "No WorkHomepage-* DerivedData folders found."; \
	  else \
	    echo "Removing $$count WorkHomepage-* DerivedData folder(s)…"; \
	    rm -rf ~/Library/Developer/Xcode/DerivedData/WorkHomepage-*; \
	    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
	      -kill -r -domain local -domain system -domain user || true; \
	    killall Dock || true; \
	  fi
