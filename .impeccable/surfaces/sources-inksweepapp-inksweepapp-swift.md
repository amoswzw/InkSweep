---
version: 1
slug: "sources-inksweepapp-inksweepapp-swift"
primary_target: "Sources/InkSweepApp/InkSweepApp.swift"
related_targets: ["Sources/InkSweepApp/Views/SmartCleanView.swift"]
---

Scope: the whole InkSweep app (8 tools + menu bar). Mode: Operate. Build path: code-led (native app).
Audience/task: Mac power users; occasional sessions — open, scan, review, clean, done. Must stay legible in light and dark.
Constraints: InkKit ink-wash world (paper, palette light/dark, brush rules, seals, brush lettering); bilingual Chinese brush + English serif; no third-party assets/copy; every number honest.

## Direction contract
THESIS: Each tool is a sheet of rice paper and the scan is an ensō being brushed — the circle closing is the progress. Refuses the card-grid dashboard and neon gradients while keeping the staged arc: scan → live progress → big result → clean → done.
OWN-WORLD: InkKit paper (F1EBDF / 1C1B18) with tiled grain, sumi ink and sub-ink greys, one vermilion (B8322A / E0574B) reserved for seals, selection and the primary act. Brush-lettered Chinese titles beside English serif; serif numerals; tapered brush rules instead of hairlines; ruled lists, no white cards, no dark bands.
STORY: The user sees one seal to press, watches the Mac being read category by category, sees one number they can trust, chooses what goes, presses 清, and gets a stamped 净 receipt saying everything is in the Trash.
FIRST VIEWPORT: Sidebar left (seal 掃 + 墨扫 InkSweep, eight bilingual tool rows). Main: bilingual page title top-left with brush rule; centred 300pt ensō with the vermilion scan seal at its heart; one line of copy beneath; after scan the centre holds the reclaimable total and the 清 Clean seal, category ledger below.
FORM: The staged single-action arc translated into ink (position 1). seed: none (world and structure pinned by the product brief; no roll run)
SIGNATURE: the ensō brush stroke grows with real scanner progress; each category's character inks in on the rim when its scanner runs; cleaning redraws it in vermilion; completion stamps a 净 seal.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
