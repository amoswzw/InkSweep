# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI app, macOS 14+; not one of web/ios/android/adaptive)

## Users
Mac power users and developers who want their disk cleaned the way a good commercial cleaner does it, without handing a closed tool root access to everything. Sessions are occasional and short: open, scan, review, clean.

## Product Purpose
InkSweep covers the full capability set of a modern Mac cleaner (Smart Clean, Uninstaller, Space Lens, Maintenance, Shredder, Updater, Smart Care, plus duplicates) as an original app and aims to surpass it. Success: the user trusts what a clean will do before pressing it, and every clean is recoverable.

## Positioning
Measured, not claimed: every rule carries provenance, coverage is checked against the real app, sizes are verified against du/lipo. Everything goes to the Trash; emptying the Trash and the Shredder are the only irreversible surfaces, each behind an explicit confirmation.

## Capabilities and Constraints
- Engine and CLI in `Sources/InkSweepCore` and `Sources/inksweep`; the app in `Sources/InkSweepApp`.
- Opt-in categories (Trash, Installers, Build Artifacts) start deselected.
- Analysis-only findings (universal binaries, language files, root locations) are shown but never cleaned; thinning has its own confirmed action.
- Root-only maintenance is locked until a privileged-helper phase exists.

## Brand Commitments
- Member of the ink app family (InkBar, InkStats, InkShot), built on their shared kit, InkKit (github.com/amoswzw/InkKit): 水墨 ink-wash style, rice paper, brush lettering, vermilion seals.
- Bilingual brush lettering like the siblings (Chinese brush title + English serif); ink-wash theme only, following system light/dark with InkKit's palettes.
- Direction: a full Mac cleaner's staged scan → result → clean → done arc, rendered in the ink world.
- Original only: no third-party assets, artwork, names or copy.

## Evidence on Hand
Real scan data from the dev machine (e.g. 11.2 GB build artifacts, 3.41 GB thinnable). No testimonials, users or benchmarks exist; none may be invented.

## Product Principles
1. Show before acting: a clean is previewed and explained, never opaque.
2. Reversible by default; irreversible only behind a named confirmation.
3. Honest numbers: what is shown is what will happen.
4. One family: InkSweep should be recognisable as a sibling of InkBar and InkStats.
