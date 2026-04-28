# Release plan: shipping `WorkHomepage`

Two phases. Phase 1 is enough for installing on your own laptop. Phase 2 covers handing the app to colleagues or uploading to Rippling Barto.

## Context

`WorkHomepage` is a SwiftUI macOS app (Xcode project at `WorkHomepage/WorkHomepage.xcodeproj`). Today it only runs from Xcode — no Release artifact, no signed bundle, no installer.

Per Apple's distribution guidance (`developer.apple.com`), any app distributed outside the Mac App Store must be signed with a **Developer ID Application** certificate, built with the **Hardened Runtime** enabled, include a **secure timestamp**, and be **notarized** + **stapled**. The current project has `ENABLE_HARDENED_RUNTIME = NO` and no entitlements file, so it cannot be notarized as-is.

Sandbox stays **off** — the app shells out to `git`, `gh`, `claude`, `idea`, `/usr/bin/python3` and reads `~/.claude/`, `~/.work-homepage/` (see `BinaryResolver`, `WorktreeManager.swift:9-10`, `SessionsReader.swift`). Sandboxing would break all of that. Notarization does not require the sandbox; only Hardened Runtime is mandatory.

---

## Phase 1 — this laptop only (no DMG, no signing, no notarization)

Goal: run `WorkHomepage.app` from `/Applications` like any other app, no Xcode running.

### Steps

```sh
# from repo root
xcodebuild \
  -project WorkHomepage/WorkHomepage.xcodeproj \
  -scheme WorkHomepage \
  -configuration Release \
  -derivedDataPath build

cp -R build/Build/Products/Release/WorkHomepage.app /Applications/
```

Double-click from Launchpad / Spotlight. No Gatekeeper prompt — locally-built binaries don't get the `com.apple.quarantine` xattr, so Apple's "unidentified developer" block does not fire.

Use `make local-install` for the convenience flow. It runs the build + copy and then resets the macOS IconServices cache (`lsregister -f`, `killall Dock`, `killall Finder`). The cache reset matters when the app icon changes between installs: the Dock has its own refresh pipeline and tends to pick up the new icon, but Stage Manager, Mission Control, and the ⌘-Tab app switcher pull from the cached IconServices store and will show a stale or blank icon until the cache is invalidated.

### Why no DMG / signing / notarization

- Hardened Runtime, entitlements, Developer ID cert, `notarytool` — all skipped.
- Existing `ENABLE_HARDENED_RUNTIME = NO` and missing entitlements are fine for local use.
- Files copied via `cp` from a local build never carry the quarantine attribute that Gatekeeper checks.

### Phase 1 verification

1. `xcodebuild ... -configuration Release` exits 0.
2. `/Applications/WorkHomepage.app` launches by double-click. Reviews tab loads PRs, Claude Code tab populates from `~/.claude/sessions/`, worktree creation works.
3. `xcodebuild test -project WorkHomepage/WorkHomepage.xcodeproj -scheme WorkHomepage` green.

---

## Phase 2 — distribute to colleagues / Rippling Barto

Required only when handing the `.app` to anyone else. Anything downloaded over a browser, AirDrop, Slack, or pushed via MDM gets the quarantine xattr applied by macOS, and Gatekeeper then refuses to launch unsigned/un-notarized apps. Barto adds its own requirement that managed apps be notarized.

Outcome:

- `scripts/build-dmg.sh` produces `dist/WorkHomepage-<version>.dmg`, signed + notarized + stapled.
- Drag-install to `/Applications`. First launch passes Gatekeeper without right-click → Open.
- `.dmg` uploadable to Rippling Barto.

### Critical files

#### Modify
- `WorkHomepage/WorkHomepage.xcodeproj/project.pbxproj`
  - Set `ENABLE_HARDENED_RUNTIME = YES` (lines 403, 448).
  - Add `CODE_SIGN_ENTITLEMENTS = WorkHomepage/WorkHomepage.entitlements` to both Debug + Release configs.
  - Bump `MARKETING_VERSION` (lines 400, 445) and `CURRENT_PROJECT_VERSION` (lines 418, 463) on each release. Consider replacing the hardcoded values with an `xcconfig` (`Config/Version.xcconfig`) sourced by both configs so a single edit updates both.
  - Confirm `CODE_SIGN_STYLE = Automatic` and `DEVELOPMENT_TEAM = 7Y7HCMY4K5` stay as-is for local archive; the export step below switches signing to manual using `Developer ID Application`.
- `README.md` — add "Building a release `.dmg`" and "Installing from the `.dmg`" sections.
- `.gitignore` — add `dist/`, `build/`, `*.dmg`, `*.zip`.

#### Create
- `WorkHomepage/WorkHomepage/WorkHomepage.entitlements` — minimal entitlements file. No sandbox key. Required because Hardened Runtime is on and we spawn signed third-party binaries:

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

  `disable-library-validation` is needed because we `Process`-launch JetBrains `idea`, npm-installed `claude`, and Homebrew `git`/`gh` — they're signed by different teams and Hardened Runtime would otherwise reject loading their dylibs into our process tree's child invocations. (No entitlement is needed for plain `Process` exec of an Apple-signed binary like `/usr/bin/python3`, but the JIT/library entitlements are the standard pattern for tool-shell apps.)

- `scripts/ExportOptions.plist`:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>7Y7HCMY4K5</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
  </dict>
  </plist>
  ```

- `scripts/build-dmg.sh` — single script that runs the full pipeline. Outline (bash, `set -euo pipefail`):

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  SCHEME=WorkHomepage
  CONFIG=Release
  TEAM_ID=7Y7HCMY4K5
  ROOT=$(cd "$(dirname "$0")/.."; pwd)
  DIST="$ROOT/dist"
  BUILD="$ROOT/build"
  ARCHIVE="$BUILD/$SCHEME.xcarchive"
  EXPORT="$BUILD/Export"

  rm -rf "$BUILD" "$DIST"; mkdir -p "$BUILD" "$DIST"

  # 1. Archive (Hardened Runtime on, secure timestamp via Xcode default).
  xcodebuild -project "$ROOT/WorkHomepage/WorkHomepage.xcodeproj" \
    -scheme "$SCHEME" -configuration "$CONFIG" \
    -archivePath "$ARCHIVE" archive

  # 2. Export with Developer ID signing.
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" \
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
  codesign --sign "Developer ID Application: <Team Name> ($TEAM_ID)" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile notarytool-password --wait
  xcrun stapler staple "$DMG"

  echo "Built: $DMG"
  ```

- `Makefile` (optional convenience): `dmg:` target → `./scripts/build-dmg.sh`.

### One-time setup (per developer who builds releases)

1. `brew install create-dmg` — Homebrew formula, the shell-based one (not the JS npm package).
2. In Apple Developer portal under team `7Y7HCMY4K5`, request a **Developer ID Application** certificate (and matching **Developer ID Installer** if we ever ship `.pkg`). Download + install into login keychain. Confirm:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID"
   ```

3. Create an app-specific password at `appleid.apple.com`, then store it for `notarytool`:

   ```sh
   xcrun notarytool store-credentials notarytool-password \
     --apple-id <appleid> \
     --team-id 7Y7HCMY4K5 \
     --password <app-specific-pw>
   ```

4. Verify Xcode 26.4.1 + macOS SDK present (already configured per `project.pbxproj`).

### Rippling Barto upload

Barto is Rippling's internal "App Catalog" / app distribution surface.

1. Open Rippling → App Shop / Software → request a new managed app (confirm exact entry point with IT/Helpdesk).
2. Upload `dist/WorkHomepage-<version>.dmg`. Barto requires a notarized, stapled artifact (Apple's Gatekeeper requirement on managed Macs).
3. Set bundle id `com.floc.WorkHomepage` and the marketing version so Barto can detect updates.
4. For each future release: bump version → `make dmg` → upload new artifact → publish.

If Barto requires `.pkg` instead of `.dmg`, swap step 4 of the script for `productbuild --component "$APP" /Applications "$BUILD/$SCHEME.pkg"`, then sign with `Developer ID Installer` and notarize the `.pkg` the same way. Confirm format with Rippling IT before first submission.

### Phase 2 verification

End-to-end check before publishing:

1. `./scripts/build-dmg.sh` exits 0; `dist/WorkHomepage-<version>.dmg` produced.
2. `spctl --assess --type open --context context:primary-signature -vv dist/*.dmg` → `accepted, source=Notarized Developer ID`.
3. `codesign -dv --entitlements :- build/Export/WorkHomepage.app` → shows Hardened Runtime flag (`runtime`), Developer ID team, and the entitlements above.
4. `xcrun stapler validate dist/*.dmg` → `The validate action worked!`.
5. On a clean Mac (or another machine where you re-download the DMG, so quarantine is set): mount the DMG, drag `WorkHomepage.app` to `/Applications`, double-click — Gatekeeper opens it without the "unidentified developer" prompt.
6. Smoke test: Reviews tab loads PRs, Claude Code tab populates from `~/.claude/sessions/`, worktree creation succeeds (verifies `Process` launches still work under Hardened Runtime + library-validation-disabled).
7. `xcodebuild test -project WorkHomepage/WorkHomepage.xcodeproj -scheme WorkHomepage` — all green.
8. Pilot install on one teammate's Mac via Barto before broad rollout.

---

## Out of scope

- CI automation (GitHub Actions runner with signing cert in keychain) — defer; first release is hand-built.
- Sparkle / auto-update — Barto handles distribution of new versions.
- Universal binary — macOS 26 deployment target is Apple Silicon only.
