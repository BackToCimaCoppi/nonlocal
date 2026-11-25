# Nonlocal UI Tests Guide

## Scope
iOS Simulator UI automation tests (`ios/AgmenteUITests/`) driven against isolated local Nonlocal Bridge processes (`packages/bridge` / `nonlocal-bridge`) and loopback non-bridge test stubs.

## Coverage Goals
- Single-bridge add-server form, required Bearer token, real-time `/` root directory warning, non-bridge rejection, direct save without summary modal, and simplified 2-section Settings (`AgmenteUITests.testSingleBridgeFormAndRejectionFlow`).
- Single-row composer toolbar, inline slash-command autocomplete, background disconnect/buffer recovery, clean transcript, and rename (`AgmenteUITests.testACPBridgeToolbarAndReconnectFlow`).
- 3-state activity dots and sorting (`AgmenteUITests.testSessionListDotsAndSortFlow`).
- Antigravity quota card, remote file browser/preview, session info sheet, and offline Mermaid rendering (`AgmenteUITests.testFiveFeaturesEndToEndFlow`).
- Wave 2 multi-server UI, Touch Bar, project aliases, native swipe/remote delete, failed-delivery retry restore, German localization & Japanese fallback, two-stage cold launch zero-`4001` preemption, and non-bridge top red banner + manual edit unlock (`Wave2UITests`, 7 tests).

## UI Automation Rules
- Prefer stable `accessibilityIdentifier` lookups over coordinate taps.
- Critical accessibility ID contracts:
  - Server form & home: `"emptyStateAddServerButton"`, `"ServerNameField"`, `"ProtocolPicker"`, `"HostField"`, `"TokenField"`, `"WorkingDirectoryField"`, `"rootWorkingDirectoryWarning"`, `"saveToolbarButton"`, `"SaveServerButton"`, `"antigravityCardTitle"`, `"serverCardFilesButton"`, `"serverTouchBar"`, `"nonBridgeLockoutBanner"`, `"nonBridgeEditButton_<uuid>"`, `"preemptedReconnectBanner"`, `"moreMenuButton"`, `"addACPServerMenuAction"`, `"settingsMenuAction"`, `"settings-language-button"`.
  - Sessions & composer: `"newSessionButton"`, `"NewSessionCreateButton"`, `"newSessionServerPicker"`, `"newSessionProjectPicker"`, `"acp-composer-toolbar"`, `"acp-prompt-editor"`, `"acp-send-button"`, `"acp-slash-suggestions"`, `"acp-slash-suggestion-<name>"`, `"acp-slash-dismiss-button"`, `"acp-command-menu-<name>"`, `"acp-session-more-button"`, `"acp-session-rename-button"`, `"acp-session-delete-button"`, `"acp-session-files-button"`, `"retry-failed-message-<uuid>"`, `"file-browser-chip-<kind>"`.
- Keep UI tests language-decoupled (never rely on hardcoded localized strings when stable accessibility IDs exist; handle multilingual system alert buttons).
- When a test opens `com.apple.Preferences` (e.g. via `settings-language-button`), immediately call `app.activate()` to return the tested app to foreground.
- Run all `xcodebuild` invocations serially against the same Simulator with `-onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates`.

## Cleanup Expectations
Stop any isolated `nonlocal-bridge` / stub processes started for UI test runs and remove temporary `/tmp/nonlocal-*` artifacts after test execution.
