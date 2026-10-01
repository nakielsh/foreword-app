# Contributing

Thanks for taking a look. Bug reports, fixes and small features are welcome. For anything bigger, open an issue first so we can agree on the shape.

## Setup

- macOS 26.4+ on Apple Silicon, Xcode 26.4+.
- `gh` and `claude` installed if you want to run real reviews.

```sh
make build        # Release build into build/, signed to run locally
make local-install
```

No Apple Developer account is needed. To sign with your own team, copy `Foreword/Config/Local.xcconfig.example` to `Foreword/Config/Local.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM`.

The Xcode project uses synchronized folders: new files under `Foreword/Foreword/`, `Foreword/ForewordTests/` or `Foreword/ForewordUITests/` are picked up without touching the project file.

## Tests

```sh
xcodebuild test -project Foreword/Foreword.xcodeproj -scheme Foreword \
  -destination 'platform=macOS' -only-testing:ForewordTests
```

The UI tests (`ForewordUITests`) drive the real app and take over the screen; run them on purpose, not by default.

- Write the test first when fixing a bug or adding behaviour.
- Prefer the fluent helpers in `ForewordTests/Helpers/Assertions.swift` (`assertThat(x).isEqualTo(y)`, `.contains(...)`, `.hasSize(...)`).
- Tests must not touch your real data. Use a `UserDefaults(suiteName:)`, a temp directory, or a unique Keychain service. When the unit tests run, the app itself starts with an in-memory store and skips data migration.

## Conventions

- No wildcard imports.
- Anything that comes from GitHub or Jira and ends up in a prompt goes through `UntrustedContent.fence` / `.sanitise`.
- Foreword never writes to GitHub. Keep it that way.
- Review behaviour belongs in the bundled skill (`skills/reviewing-pr-final-state/`), not hard-coded into the prompt builder.
- `CLAUDE.md` describes the architecture for people (and agents) working in the code; update it when you move things around.

## Before you open a PR

```sh
./scripts/check-no-org-leaks.sh
```

CI runs the same check plus the unit tests.
