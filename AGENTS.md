# TypeFlow repository guidance

These instructions apply to the whole repository. Keep implementation work in a
dedicated branch and use a pull request for changes intended for `main`.

## Product and compatibility

- The user-facing product name is `TypeFlow`.
- Keep `LocalSwitcher` only where the updater compatibility contract requires it:
  the bundle identifier, signing identity, legacy defaults and paths, and the
  versioned compatibility app or DMG described in `docs/UPDATE_SECURITY.md`.
- Support macOS 13 or newer. Public releases currently target Apple Silicon.
- Do not publish a release, change update manifests, or overwrite release assets
  unless the user explicitly asks for a release.

## Required verification

Before considering a code change ready for review, run:

```bash
swift test --package-path macos
python3 scripts/audit_short.py
bash -n macos/build_app.sh
bash -n macos/create_dmg.sh
git diff --check
```

For packaging, resource, entitlement, icon, `Info.plist`, or updater changes,
also build an app bundle outside the repository:

```bash
RS_OUTPUT_DIR="$(mktemp -d)" macos/build_app.sh
```

Never install the result or modify the user's Accessibility or Input Monitoring
permissions unless the user explicitly asks for those actions.

## Code Review Rules

### Privacy and keyboard-event safety

- Flag any path that logs, persists, or transmits typed text, weakens Secure Input
  handling, processes password-manager fields, or reprocesses synthesized events.
  The safe path is local-only processing, no raw keystroke logging, fail-closed
  exclusions for sensitive fields, and explicit regression tests.

### Conversion correctness

- Flag dictionary or scoring changes that let broad corpora override reviewed
  lexicons, current-language evidence, punctuation safety, or user rejection
  learning. The safe path is conservative precedence plus focused regression
  tests and a zero-risk result from `scripts/audit_short.py`.

### Update and release integrity

- Flag changes that weaken signed-manifest verification, URL restrictions, size
  bounds, hash or certificate checks, bundle/version validation, rollback, or the
  temporary `LocalSwitcher` compatibility contract. The safe path is to preserve
  the trust chain in `docs/UPDATE_SECURITY.md` and extend its tests when behavior
  changes.
