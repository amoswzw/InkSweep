# InkSweep — handoff (2026-10-25, night 5)

Resume point for a fresh session. Read this first, then `report/REPORT.md`
and `report/feature-parity.md` (the feature ledger) one dir up.

## Goal

**Full UI feature parity with the reference
commercial cleaner plus the surpass features.** The ledger
`../report/feature-parity.md` is the contract
for what exists / is locked / is next. Standing rules underneath it:

- R1 Coverage is measured (differential VM pass), not claimed.
- R2 Safety invariants are tested. Default flow reversible (Trash); the
  Shredder is the only irreversible surface (explicit destructive confirm).
- R3 Every rule carries provenance; dataset grows without code changes.
- R4 Sizing verified against `du`.
- R6 Original only — no third-party code/assets/DBs/servers.
- Privileged helper is BACK IN SCOPE as its own phase: unlocks the 3
  locked Maintenance tasks + lipo + root-half junk. Blueprint is in
  `../report/REPORT.md` (XPC + SMAuthorizedClients + symlink guard).

## STATUS 2026-10-26: ink UI redesign + real Updater, 137/137 tests

- UI rebuilt on InkKit (the family kit, github.com/amoswzw/InkKit 0.1.0;
  macOS 14+): `InkDesign.swift` holds tokens (InkKit palettes, light/dark),
  bilingual sidebar (grouped Care/Apps/Tools, live badges, last-clean note,
  disk gauge), headers, SealButton, InkChoice/InkCheck/InkSearchField,
  EnsoLoop, CenteredStage. App accent = vermilion via
  `Scripts/Assets.xcassets` compiled by make-app.sh (focus rings, menus).
- Every tool is a staged, centred composition (the reference cleaner's
  grammar in ink): ensō + one seal. Smart Care is now the hub (opens first).
- Updater works: `Updates.swift` (VersionCompare, Appcast, UpdateChecker,
  AppUpdater) + `inksweep updates`. Real check here: 9 updates in 3.6 s.
  Real install verified on a copy (AppCleaner 3.6.8 → 3.7.0, codesign +
  Gatekeeper OK).
- Maintenance is one-click (`MaintenanceCatalog.swift`, sequential
  `runMaintenanceBatch`). Space Lens hit-test bug (90° off) fixed.
- Menu bar: AppKit status item (`StatusItem.swift`), NOT SwiftUI
  MenuBarExtra — MenuBarExtra ignores the accessibility press InkBar uses
  to open hidden items. When the button is off-screen (InkBar presses
  non-notarized apps in place, concealed) the panel floats under the
  pointer instead of a popover. Icon: the app icon's sumi sweep stroke, because the ensō
  is InkBar's mark. `MenuBarPanel.swift` — ink panel
  (state, Clean-to-Trash, updates, last clean, disk, Open InkSweep / Check
  now). Screenshot it by clicking the menu bar icon by hand (status-item clicks
  cannot be automated; a preview-window scene was tried and removed because
  macOS window restoration kept reopening it on the desktop).
- Open: impeccable finish review + DESIGN.md not done; Homebrew casks as an
  update source; thinned/updated apps not launch-tested.

## Night 5: open-source-cleaner comparison folded in, 129/129 tests

Compared against an open-source cleaner (checklist only, nothing copied);
full write-up in `../report/` (external to this repo). Summary:
- Safety: cleanup-target firewall (Apple caches only via curated
  contents rules; stateful "cache" names; password managers / EDR by ID
  and folder name; DiagnosticReports folder kept); owner guards
  (libproc process names + bundle IDs) on rules; nested findings deduped.
- Coverage: pattern roots; ChromiumCacheScanner (structural `Local State`
  detection); ContainerCachesScanner; 31 dev-cache + 14 app-cache + 21
  Apple-cache rules (KB v4, 79 rules); DeviceFirmwareScanner;
  InstallerFilesScanner + ProjectArtifactsScanner (new opt-in categories
  installerFiles / projectArtifacts); StaleSavedState + BrokenPreferences.
- Maintenance (user space, `MaintenanceActions`): Quick Look refresh, disk
  verify (no root needed, ~5 s), .DS_Store prevention, legacy overrides,
  quarantine history, unavailable simulators. Locked list corrected.
- Thinning moved out of the helper phase: `AppThinner` (seal-aware,
  verified APFS clone, own slice extraction, original to Trash, rollback);
  scanner measures exactly the plan (3.41 GB here, not 5.28). CLI
  `inksweep thin [--apply]`, Maintenance sheet. Bug found on the way:
  `skipDescendants` on a framework's `Resources` symlink skipped the whole
  framework — fixed, locked by a realistic fixture.
- Real copies of Claude.app/KeyCastr.app thinned and verified (codesign
  deep/strict + Gatekeeper); not launched. Scan 5.4 s.

## Night 4: audit of the ChatGPT-written work, 89/89 tests

Nights 2–3 (everything after the 7-test engine skeleton) were written by
ChatGPT. Audited against R1–R6; every defect below was fixed test-first
(each fix has a regression test that fails without it), `swift build`
clean, `swift test` 89/89, `python3 -I tools/test_diffcov.py` 8/8,
`Scripts/make-app.sh` builds + verifies. UI dialogs compiled, not
visually checked.

Safety (R2):
- `Cleaner` now refuses analysis-only findings itself (they point at whole
  app bundles; `cleanCategory` handed them through unfiltered) and items
  already in the Trash (trashing Trash reclaimed nothing but reported success).
- "Empty Trash" never emptied anything. New `TrashEmptier`: deletes only
  direct children of ~/.Trash, symlinks unlinked; Maintenance + Smart Clean
  confirm explicitly; Trash is opt-in (deselected) in Smart Clean; CLI needs
  `--empty-trash`. `CleanReceipt.Outcome.deleted` is its only producer.
- Uninstaller swept whole vendor dirs: a word-prefix name ("Google" ←
  "Google Chrome", "Adobe" ← "Adobe Photoshop") claimed
  Application Support/Google and Caches/Google — contradicting its own
  doc. Prefix claims now take a dir whole only if it has no subdirs.
  Running-app check was case-sensitive (never warned for com.google.Chrome).
- Planner/bundle scanners read the host's /Applications in tests →
  `ScanContext.applicationRoots` (injectable; fixtures use their own).
- Leftovers: Apple data outside com.apple.* was flagged in the fresh VM —
  CallHistoryDB, Categories, group.is.workflow.* (= Shortcuts). Protected.
- Leftovers: the same-vendor rule hid real orphans (VM: com.fixture.gone
  beside com.fixture.live). Now applied only where data is vendor-shared
  (Preferences, Group Containers, Application Scripts), not per-bundle roots
  (Containers, Saved State, Cookies, HTTPStorages, WebKit). Embedded bundle
  IDs (PlugIns/XPCServices/LoginItems/…, Team-ID prefix stripped) and every
  .app inside Application Support (not just the first, and also inside
  name-claimed trees — found via a disabled GoogleUpdater on the dev machine) count
  as installed.
- Shredder refuses hard-linked files (overwrite destroyed the other path)
  and "/", $HOME and its ancestors.
- Browser privacy: SQLite -journal/-wal/-shm travel with their database.
- Broken login items: /Volumes programs (unmounted ≠ gone) and
  BundleProgram agents are not flagged.
- CLI: unknown `--category` used to mean "all categories"; now an error.

Honesty (R4/R1):
- Lipo waste was an equal-slices estimate; now exact from the fat arch
  table (file − host slices). Verified against real `lipo -thin arm64` on
  UTM.app: 496,369,664 bytes both. Machine total 5.28 GB (not 5.14).
- Legacy `English.lproj`-style names were counted as removable.
- Duplicates counted hard links (deleting one frees nothing).
- Smart Care agent wrote text but the app decoded JSON (never displayed);
  the agent was also never loaded until next login (now `launchctl bootstrap`).
- Maintenance listed "Repair disk permissions" (removed in OS X 10.11) and
  described lipo backwards. Mail reason text overstated re-downloadability.
- **The VM coverage result (78.9%) was invalid** — see
  `diffcov-results/system-junk/INVALID.md`. The capture never recorded the
  clean; the parser counted failed syscalls and broke paths at spaces;
  findings' percent-encoded URLs could never match. diffcov.py rewritten
  (+ tests), vm-capture.sh now uses a before/after root listing diff (no
  process filter), a TCC preflight, the current build, and the fixture
  manifest (refuses to report a number when the oracle removed no fixture).
  vm-handoff.sh no longer exposes the guest password in argv.

## STATUS 2026-10-25 (night 3): deep scans + honest progress, 67/67 tests

- **Why the sweep was "instant" vs the original's slow scan** —
  answer: we scanned less. Fixed by adding the original's real scan work
  (user-space half):
  - `UniversalBinaryScanner` — walks every app bundle's executables and
    frameworks, parses Mach-O fat headers, reports lipo-thin-able bytes.
    Real machine: 5.14 GB thin-able (ESTIMATE, superseded: 5.28 GB measured; UTM 489 MB, Edge 343 MB, Chrome
    297 MB…). Analysis-only (`reversible: false`).
  - `LanguageFilesScanner` — non-preferred .lproj sizes per app
    (dialect-prefix matching, Base always kept). Analysis-only.
  - KnowledgeBase v3: /Library/Caches + /Library/Logs rules (analysis-only,
    admin needed to clean).
  - New category `systemJunk` (9 total). `ScanReport.cleanableFindings` /
    `analysisOnlyBytes`; clean paths (UI + CLI) exclude analysis-only items.
  - **Progress pipeline**: `engine.scan(context:progress:)` fires per scanner
    phase; HeroGauge shows live phase title + found count (numericText).
- Real-machine timing after deep scans: ~0.9 s wall (header reads are cheap,
  page-cached). The original's remaining slowness = per-item encrypted-rule-
  DB evaluation, Mail SQLite parsing, malware pass, root-half surfaces, and
  deliberate UI pacing — documented here, not faked.
- First real end-to-end clean via the app: ~/Library/Caches 1.5 GB and large old
  files trashed (verified on disk).
- UTM.app now installed on the machine — VM differential pass (R1) is next.

## Night-2 recap (still current unless overridden above)

- `swift build` clean; `swift test` was 61/61 at that point (now 67/67).
- **App is now tool-shaped** (`build/InkSweep.app`, running): sidebar with
  Smart Clean / Uninstaller / Duplicates / Space Lens / Maintenance /
  Shredder / Updater / Smart Care + MenuBarExtra. Ink theme throughout.
- New engine pieces (all tested):
  - `MailAttachmentsScanner` — ≥1 MB blobs under ~/Library/Mail Attachments
    subtrees; Mail-closed gating; FDA warning. (JunkCategory v8: mailAttachments.)
  - `UninstallPlanner` + `InstalledApp` — full uninstall plans: bundle,
    containers/prefs/saved-state/cookies (id-family claims only — sibling
    vendor data deliberately stays out), AS name claims with vendor split,
    caches/logs, matching LaunchAgents; refuses system apps; Trash-executed.
  - `DuplicateFileScanner` — size → 64-KB SHA-256 prefix → full SHA-256;
    keeper = oldest by mtime; wasted-bytes accounting. (Surpass feature.)
  - `Shredder` — 3-pass random overwrite + fsync, post-order dirs, symlinks
    unlinked without touching targets; APFS honesty in the doc comment.
  - `SpaceLensScanner` — pruned sized tree (depth 3, top-12 children).
- CLI: `apps`, `uninstall --bundle-id [--apply]`, `duplicates
  [--min-size-mb] [--json]`, `shred [--apply]`, `scan --output` (Smart Care
  data). Fixed an ArraySlice index bug in option parsing (`idx+1 < count`
  → `endIndex`).
- Real-machine validation: uninstall plan for Inkshot = exactly its own
  4-target family (team rule removed from planner after it swept InkSweep's
  own prefs — protection belongs in orphan detection, not deletion);
  duplicates 0 groups at 10 MB+ (no real dupes — machinery verified by
  tests); shred dry-run clean.
- make-app.sh now embeds the CLI (`Resources/inksweep`) for Smart Care's
  daily LaunchAgent scan.
- **Differential tooling (R1 prep, awaiting VM):** since removed from the
  repo together with the rest of `tools/`; write-ups live outside it.
  NOT DONE: the VM pass itself (a VM must be provided to run the real app
  under capture).

## Evidence log (real machine, macOS 27, 2026-10-25)

Each false-positive class found by eyeballing `scan --list` output, fixed, and
locked with a regression test:

1. macOS 26+: `/Applications/Safari.app` is a **hidden symlink** into the OS
   cryptex — `.skipsHiddenFiles` made Safari look uninstalled. Fix: snapshot
   enumerator uses only `.skipsPackageDescendants`.
2. Bundle-ID matching must be **case-insensitive** (cx.c3.TheUnarchiver).
3. Helper-process IDs ("…browser-helper") never appear as app-bundle IDs →
   claimed defensively.
4. Input-method apps live in `/Library/Input Methods` (Squirrel) → added root.
5. "Hopper" vs app name "Hopper Disassembler" → word-boundary **prefix** name
   matching (also conservatively claims vendor dirs like "Google").
6. Self-contained apps inside Application Support (BitBrowser ships itself in
   its own AS tree): subtree containing an `.app` is untouchable, and its
   bundle ID is collected so its prefs/containers elsewhere are claimed too.
7. UUID-stamped preference plists ("HushloomTests.<UUID>.plist", 300+) are
   XCTest per-run debris → new `TestDebrisScanner` (developerJunk), excluded
   from appLeftovers.
8. Unclaimed AS trees with subdirs are flagged **whole** (Vivaldi/Arc/
   "Microsoft Edge Dev"), not just one subdir; vendor dirs with a live app
   beside orphans flag only unclaimed, unprotected subdirs.
9. Protected names observed in the wild: NativeMessagingHosts (browser↔
   extension bridges), networkserviceproxy / DiskImages / icdd (Apple daemon
   data), systemgroup.com.apple.* namespace, Animoji (Messages data).
10. **du cross-check (R4)**: 8 largest findings vs `du -sk` — 7 exact to the
    byte, worst deviation 5.6% (an actively-written cache). JSON export works
    (`scan --json`).
11. **Empty LaunchAgent stubs**: Google's Keystone→GoogleUpdater migration
    leaves `<dict/>` plists that launchd loads to no effect — caught 3 on the
    dev machine (rule: no Program, no ProgramArguments, no MachServices →
    debris; MachServices-only XPC agents are functional and skipped).
    Bug found & fixed during this: a refactor inverted the program-existence
    check (flagging alive agents, passing dead ones) — caught by the fixture
    tests, which also crashed on `findings[0]` after a failed count assert
    (now `XCTUnwrap(findings.first)`).

Known accepted gaps (conservative by design): team-rule over-protection
(vendor with any app installed shields that vendor's orphans); CLI tools
without .app bundles (brew go/lazygit) can be flagged — user reviews in UI;
Xcode Archives deliberately NOT junk (precious dSYMs);
CoreSimulator/Devices untouched; Firefox history excluded (places.sqlite also
holds bookmarks); Safari/Trash need Full Disk Access (warnings emitted).

## Code state

Swift package at `InkSweep/`. Swift 6.4 toolchain, language mode v5, macOS 13+.
Everything resolves through `ScanContext.homeDirectory` (tests use fixtures).

- `Models.swift` — JunkCategory (7), Finding, ScanReport (both Codable — JSON
  export), CleanReceipt.
- `Rule.swift` — RuleRoot/ScanStrategy/Provenance/Rule/KnowledgeBase/ScanContext.
- `FileTree.swift` — allocated-size sizer, never follows symlinks.
- `Scanner.swift` — Scanner protocol + RuleBasedScanner.
- `Scanners/LargeOldFilesScanner.swift` — ≥100 MB & ≥90 days under
  Downloads/Documents/Desktop.
- `Scanners/AppLeftoversScanner.swift` — leftover heuristic + claim logic +
  `InstalledAppsSnapshot`/`DiskInstalledAppsSnapshot` (+ portable-app ID
  collection). Scan order matters: AS first (collects portable IDs), then
  Containers/HTTPStorages/WebKit/AppScripts/GroupContainers, then
  Preferences/SavedState/Cookies.
- `Scanners/BrowserDataScanner.swift` — Safari/Chrome/Edge/Brave/Arc/Firefox;
  running browsers skipped with a warning; uninstalled browsers are
  appLeftovers' business; Safari TCC probe emits an FDA warning.
- `Scanners/TestDebrisScanner.swift` — UUID-stamped plists → developerJunk.
- `Protections.swift` — Apple namespaces + protected-name list (each entry has
  a reason; this list is the false-positive firewall and will keep growing).
- `Rules/DefaultRules.swift` — KnowledgeBase v2 (11 rules, each with
  provenance).
- `Engine.swift` — merge + dedupe by path; `standard(installed:runningBundleIDs:)`
  injectable for tests.
- `Cleaner.swift` — Trasher protocol; dry-run default; Trash-only removal.
- `Sources/inksweep/main.swift` — `scan [--list|--json]`, `clean [--category x]
  [--apply]`.
- `Tests/` — 33 tests across 4 suites, all fixture-based, including one
  regression test per real-machine false-positive class.

## Immediate next steps (in order)

1. **VM differential pass (the big one, R1) — still not done.** VM
   `InkSweep-VM` + snapshot `populated-base` + SSH key exist. In the guest:
   enable Remote Login → "Allow full disk access for remote users" and
   grant the reference app FDA before the next capture. Also record a
   fresh-VM ~/Library inventory: anything there is Apple's — the systematic
   source for the protect-list. (The capture/analysis scripts this used
   lived in `tools/` and were removed from the repo; rebuild from the
   external write-ups if the pass resumes.)
2. **Privileged helper phase:** SMAppService daemon +
   code-signing-pinned XPC + symlink guard (blueprint in REPORT.md). Unlocks
   the 3 locked Maintenance tasks + lipo thinning + root-half junk. Do it
   with the same discipline: blueprint first, then vertical slice.
3. Updater increment: fetch SUFeedURL appcasts, compare versions, "update
   available" states.
4. Regeneration experiments in the VM; provenance upgrades.
5. Polish: align ink design tokens with InkBar/InkStats/InkShot; scan
   progress + cancellation; Developer ID signing + notarization for
   distribution.

## Guardrails

- Original code/rules only. No third-party assets, brand, encrypted DBs, endpoints.
- Deletions reversible (Trash) unless the user explicitly removes that.
- Report build/test outcomes honestly; never claim green without running it.
