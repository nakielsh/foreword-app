# Building and releasing `Foreword`

Two levels. **Local install** is enough to run the app on your own Mac. **Signing & notarizing your own build** covers handing a `.dmg` to anyone else.

## Context

`Foreword` is a SwiftUI macOS app (Xcode project at `Foreword/Foreword.xcodeproj`).

Per Apple's distribution guidance (`developer.apple.com`), any app distributed outside the Mac App Store must be signed with a **Developer ID Application** certificate, built with the **Hardened Runtime** enabled, include a **secure timestamp**, and be **notarized** + **stapled**. The project currently has `ENABLE_HARDENED_RUNTIME = NO` and no entitlements file, so it cannot be notarized as-is.

Sandbox stays **off** — the app shells out to `git`, `gh`, `claude`, `idea` and reads `~/.claude/`, `~/.foreword/`, and your local clones under the Local Repos search roots (see `BinaryResolver`, `WorktreeManager.swift:9-10`, `LocalRepoIndex`, `SessionsReader.swift`). Sandboxing would break all of that. Notarization does not require the sandbox; only Hardened Runtime is mandatory.

### Signing identity

Build identity lives in `Foreword/Config/Base.xcconfig` (bundle id prefix, empty team), applied as the project-level base configuration. With no team the app is signed to run locally (ad hoc), which is all a local install needs.

To sign with your own Apple Developer team, copy `Foreword/Config/Local.xcconfig.example` to `Foreword/Config/Local.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM`. Set `BUNDLE_ID_PREFIX` there too if you distribute your own build, so it doesn't share a bundle id (and UserDefaults domain) with upstream builds.

---

## Local install (no DMG, no notarization)

Goal: run `Foreword.app` from `/Applications` like any other app, no Xcode running.

```sh
make local-install
```

This builds Release into `build/`, copies `Foreword.app` to `/Applications/`, and resets the macOS IconServices cache (`lsregister -f`, `killall Dock`, `killall Finder`). The cache reset matters when the app icon changes between installs: the Dock has its own refresh pipeline and tends to pick up the new icon, but Stage Manager, Mission Control, and the ⌘-Tab app switcher pull from the cached IconServices store and will show a stale or blank icon until the cache is invalidated.

No Gatekeeper prompt — locally built binaries don't get the `com.apple.quarantine` xattr, so Apple's "unidentified developer" block does not fire.

### Verification

1. `make build` exits 0.
2. `/Applications/Foreword.app` launches by double-click. Reviews tab loads PRs, Sessions tab populates from `~/.claude/sessions/`, worktree creation works.
3. `xcodebuild test -project Foreword/Foreword.xcodeproj -scheme Foreword -destination 'platform=macOS' -only-testing:ForewordTests` green.

---

## Signing & notarizing your own build

Required only when handing the `.app` to anyone else. Anything downloaded over a browser, AirDrop or chat, or pushed via MDM, gets the quarantine xattr, and Gatekeeper then refuses to launch unsigned / un-notarized apps.

Outcome:

- `scripts/build-dmg.sh` produces `dist/Foreword-<version>.dmg`, signed + notarized + stapled.
- Drag-install to `/Applications`. First launch passes Gatekeeper without right-click → Open.

None of the files below exist yet; this is the recipe.

### Project changes

- `Foreword/Foreword.xcodeproj/project.pbxproj`
  - Set `ENABLE_HARDENED_RUNTIME = YES` for the app target.
  - Add `CODE_SIGN_ENTITLEMENTS = Foreword/Foreword.entitlements` to both Debug + Release configs.
  - Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` on each release (or move them into `Config/Base.xcconfig`).
- `.gitignore` — add `dist/`, `*.dmg`, `*.zip`.

### New files

- `Foreword/Foreword/Foreword.entitlements` — minimal entitlements file. No sandbox key. Required because Hardened Runtime is on and we spawn third-party binaries:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>com.apple.security.cs.allow-jit</key><false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><false/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
  </dict>
  </plist>
  ```

  `disable-library-validation` is needed because we `Process`-launch JetBrains `idea`, npm-installed `claude`, and Homebrew `git`/`gh` — they're signed by different teams.

- `scripts/ExportOptions.plist` (team id filled in by the script):

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
  </dict>
  </plist>
  ```

- `scripts/build-dmg.sh` — single script that runs the full pipeline:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  : "${TEAM_ID:?set TEAM_ID to your Apple Developer Team ID}"
  SCHEME=Foreword
  CONFIG=Release
  ROOT=$(cd "$(dirname "$0")/.."; pwd)
  DIST="$ROOT/dist"
  BUILD="$ROOT/build/release"
  ARCHIVE="$BUILD/$SCHEME.xcarchive"
  EXPORT="$BUILD/Export"

  rm -rf "$BUILD" "$DIST"; mkdir -p "$BUILD" "$DIST"

  # 1. Archive (Hardened Runtime on, secure timestamp via Xcode default).
  xcodebuild -project "$ROOT/Foreword/Foreword.xcodeproj" \
    -scheme "$SCHEME" -configuration "$CONFIG" \
    -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM_ID" archive

  # 2. Export with Developer ID signing.
  cp "$ROOT/scripts/ExportOptions.plist" "$BUILD/ExportOptions.plist"
  /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$BUILD/ExportOptions.plist"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$EXPORT"

  APP="$EXPORT/$SCHEME.app"
  ZIP="$BUILD/$SCHEME.zip"
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

  # 3. Notarize the .app (notarytool requires zip/pkg/dmg, not .app).
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile notarytool-password --wait
  xcrun stapler staple "$APP"

  # 4. Build the DMG (Homebrew create-dmg formula, NOT the npm package).
  DMG="$DIST/$SCHEME-$VERSION.dmg"
  create-dmg --volname "$SCHEME" --window-size 540 380 \
    --icon "$SCHEME.app" 140 190 --app-drop-link 400 190 \
    "$DMG" "$APP"

  # 5. Sign + notarize + staple the DMG itself.
  codesign --sign "Developer ID Application" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile notarytool-password --wait
  xcrun stapler staple "$DMG"

  echo "Built: $DMG"
  ```

- `Makefile` (optional convenience): `dmg:` target → `./scripts/build-dmg.sh`.

### One-time setup (per developer who builds releases)

1. `brew install create-dmg` — Homebrew formula, the shell-based one (not the JS npm package).
2. In the Apple Developer portal, request a **Developer ID Application** certificate for your team. Download + install into the login keychain. Confirm:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID"
   ```

3. Create an app-specific password at `appleid.apple.com`, then store it for `notarytool`:

   ```sh
   xcrun notarytool store-credentials notarytool-password \
     --apple-id <appleid> \
     --team-id <your-team-id> \
     --password <app-specific-pw>
   ```

4. Xcode 26.4+ with the macOS 26 SDK (the deployment target is macOS 26.4).

### Verification

1. `TEAM_ID=<your-team-id> ./scripts/build-dmg.sh` exits 0; `dist/Foreword-<version>.dmg` produced.
2. `spctl --assess --type open --context context:primary-signature -vv dist/*.dmg` → `accepted, source=Notarized Developer ID`.
3. `codesign -dv --entitlements :- build/release/Export/Foreword.app` → shows the Hardened Runtime flag (`runtime`), your Developer ID team, and the entitlements above.
4. `xcrun stapler validate dist/*.dmg` → `The validate action worked!`.
5. On another Mac (or after re-downloading the DMG, so quarantine is set): mount the DMG, drag `Foreword.app` to `/Applications`, double-click — Gatekeeper opens it without the "unidentified developer" prompt.
6. Smoke test: Reviews tab loads PRs, Sessions tab populates from `~/.claude/sessions/`, worktree creation succeeds (verifies `Process` launches still work under Hardened Runtime + library-validation-disabled).

---

## Out of scope

- Signing in CI (GitHub Actions runner with a signing cert in the keychain). CI only builds and runs unit tests unsigned.
- Sparkle / auto-update.
- Homebrew cask.
- Universal binary — the macOS 26 deployment target is Apple Silicon only.
