# FlashTeX — native live-rendering LaTeX editor

A lightning-fast LaTeX editor for macOS, written in **Swift + AppKit**.
**No Electron. No JavaScript. No web views.** Pure native UI with a background
compile pipeline and PDFKit rendering.

Built and tested on **macOS 12.7.6 (Monterey)** / **Xcode 14.2** / **Swift 5.7**.

---

## Highlights

| Requirement        | Implementation |
| ------------------ | -------------- |
| Editor             | `NSTextView` subclass (`EditorTextView`): painted line-number gutter, current-line accent, brace & `$…$` auto-pairing, soft-indent tabs, native find bar. |
| Syntax highlighting| `LatexHighlighter` — regex rules over the live `NSTextStorage`, including a `$$…$$` multi-line state scan; the caret is preserved across re-coloring. |
| PDF preview        | `PreviewView` — PDFKit (`PDFView`, same engine as Preview.app), continuous single-page mode, **manual fit-to-width scaling** recomputed on every layout so the page grows/shrinks smoothly as you drag the splitter, page counter. |
| Compilation        | `Compiler` — background `Process` running system `pdflatex`; discovery falls back across common TeX install paths. Every engine run gets `-shell-escape` plus a synthesized `PATH` (TeX/Brew paths prepended), and stdout/stderr are captured through pipes. |
| Debounce           | Exactly **400 ms**, reset on every text change. |
| Smart multi-pass   | Documents without `\label`/`\ref`/`\tableofcontents`/Asymptote compile in **one pass**. Multi-pass docs run `pdflatex -draftmode` (no PDF written — faster) → Asymptote `asy` **in parallel** → `pdflatex` → a third pass only if reference files changed. Any pass that materialises `.asy` assets or shell-escapes to `asy` forces the extra pass needed to embed figures. |
| Task pre-emption   | A new request `terminate()`s the in-flight engine run immediately; a monotonically increasing generation counter discards stale callbacks. |
| Log parsing        | `document.log` walked for error blocks; `l.<n>` line numbers and `file:line:msg` (from `-file-line-error`) → `LatexIssue{line, message, context, hint}`. |
| Error viewer       | A red **Errors** toolbar button appears **only when a compile fails** (plus **Compile ▸ Show Errors…**) and opens a sheet listing line / message / context with Copy and Jump-to-line. |
| Compiling indicator| A small spinner appears in the toolbar only while an engine is actually running (with a short grace delay so fast compiles never flicker). |
| Export             | **File ▸ Export PDF…** (⇧⌘E) copies the last rendered PDF anywhere you want. |
| Flash Mode         | Floating scratch panel (**Flash ▸ Flash Mode…** / toolbar ⚡) with **Obsidian Live-Preview-style inline math**: `$…$` / `$$…$$` blocks render directly on the editor canvas as images; the block under the caret unfolds to raw LaTeX for editing. Rendered off-thread by `MathRenderer` (TeX → tight-cropped transparent PNG, cached), so typing stays fluid. |
| Preview zoom       | **View ▸ Zoom In/Out Preview** or the 🔍 toolbar buttons; default is slightly enlarged (115 % of fit-width). |
| Isolation          | Fresh `FileManager.temporaryDirectory` sub-dir per compile; last successful build is kept until the next success. |
| Theme              | Appearance-aware dynamic palette in `Theme.swift` — `#1e1e24` editor / `#2a2a30` PDF pane / `#528bff` accent / `#e3e3e6` text. |

## Feature set

- Live rendering while you type (toggleable via toolbar switch or **Compile ▸ Pause Live Compile**).
- **⌘R** forces an immediate compile; the toolbar Compile button does the same.
- Engine selection — **pdflatex / xelatex / lualatex** — from the toolbar pop-up or the Compile menu.
- **Error viewer**: when a compile fails, a red **Errors** button appears in the toolbar; clicking it (or **Compile ▸ Show Errors…**) opens a sheet with every parsed error, a Copy button, and Jump-to-line / double-click navigation straight to the offending line.
- **Flash Mode** (**⌘K** or toolbar ⚡): an Obsidian Live-Preview-style scratch panel. Math blocks (`$…$` / `$$…$$`) render **inline, right on the editor canvas**; the block under the caret unfolds to its raw LaTeX for editing. Click a rendered block to unfold it. Rendering runs off the main thread with an in-memory cache — no full-document compile involved.
- **Export PDF…** (**⇧⌘E**) saves the last rendered PDF anywhere on disk.
- **Compiling indicator**: a toolbar spinner appears only while an engine is genuinely running (after a short grace delay), so quick compiles never flicker.
- **Preview zoom** (**View ▸ Zoom In/Out Preview** or 🔍 toolbar buttons): default 115 % of fit-width, fully adjustable.
- Smart single-vs-multi-pass compilation with Asymptote support, so documents with `\tableofcontents`, cross-references, pgfplots 3D surfaces and `asy` figures render fully.
- Open / Save / Save As (**⌘N/⌘O/⌘S/⇧⌘S**), unsaved-changes confirmation, document window title.
- One-click **Open PDF in Preview** and **Reveal PDF in Finder** (File menu) — no need to hunt in temp dirs.
- Toggleable PDF pane (**⇧⌘P**) and editor font zoom (**⌘= / ⌘- / ⌘0**).
- Dark / light modes follow the system appearance.

## Layout

```
flashtex/
├── Package.swift                 SwiftPM manifest (macOS 12, executable target)
├── Info.plist                    .app bundle metadata (Monterey+)
├── build.sh                      swift build + FlashTeX.app assembly + ad-hoc sign
└── Sources/FlashTeX/
    ├── main.swift                entry: NSApplication, AppDelegate, activation
    ├── AppDelegate.swift         lifecycle + full native menu bar
    ├── MainWindowController.swift  split layout, toolbar, compiler wiring, docs,
    │                             error sheet, Flash Mode orchestration
    ├── EditorTextView.swift      editor surface (gutter, current line, auto-pair)
    ├── MathFoldingTextView.swift Obsidian-style inline math fold/unfold (NSTextView)
    ├── MathRenderer.swift        off-thread LaTeX math → NSImage, NSCache
    ├── LatexHighlighter.swift    syntax coloring on NSTextStorage
    ├── Theme.swift               appearance-aware palette, fonts, welcome doc
    ├── TeXSupport.swift          TeX/Brew PATH synthesis + executable discovery
    ├── PreviewView.swift         PDFKit preview pane + fit-to-width scaling
    ├── Compiler.swift            debounce, multi-pass pdflatex + asy, log parser
    └── FlashWindowController.swift floating Flash Mode scratch panel
```

## Build

Requires **Xcode command line tools** (Swift 5.7+, macOS 12+) and a LaTeX
distribution with `pdflatex` on PATH (e.g. **MacTeX** or **BasicTeX**).

```bash
./build.sh            # release build + FlashTeX.app
open FlashTeX.app
```

Debug build: `./build.sh --debug`. To run the raw binary instead of the bundle:
`swift run -c release`.

## How live rendering works

```
   Typing → reset 400ms debounce
                │
                ▼
   Compiler (background queue)
     · new temp dir under FileManager.temporaryDirectory
     · write document.tex
     · terminate() any in-flight run, bump generation
     · every engine run: -shell-escape -interaction=nonstopmode
       -halt-on-error -file-line-error -synctex=1, plus a synthesized PATH
       (GUI apps never inherit the shell PATH; pdflatex needs it to find asy)
     · single pass if no \label / \ref / \tableofcontents / .asy present,
       else multi-pass:
         pass 1: pdflatex -draftmode (no PDF written — faster);
                 \begin{asy} shell-escapes to `asy` and writes .asy/figure PDFs
                 + explicit `asy` run on each *.asy file in parallel (covers
                 restricted shell-escape configs)
         pass 2: pdflatex → document.pdf
         pass 3: only if \ref/TOC auxiliary files changed since pass 2
       any pass that materialises .asy assets forces the figure-embedding pass
     · parse document.log → LatexReport
                │
                ▼
   Main thread → success: PDFView.load(document.pdf), keep dir alive
                failure: red “Errors” button appears in the toolbar,
                         preview keeps the last good render
```

- Stale results (from a superseded run) are dropped via the generation counter.
- The PDF pane keeps its scroll position and current page across reloads.
- A 25 s watchdog guards against a wedged engine; the process is force-killed
  and reported as an error.

## Layout of the code

- `MainWindowController` is the shell: it owns the `NSSplitViewController`
  (editor left, preview right), the toolbar, and all menu/compiler wiring.
  Editor edits are surfaced through closures, so the controller and worker
  never touch each other's internals.
- `FlashWindowController` is a floating scratch panel hosting a
  `MathFoldingTextView` (Obsidian-style inline math) — no full-document
  compiler involved. `MathRenderer` renders `$…$` / `$$…$$` snippets with TeX
  (article + `preview[tightpage]` for a tight crop), rasterizes at 2x with
  PDFKit, and caches in an NSCache; the fold/unfold state is tracked from
  `textViewDidChangeSelection` and re-applied with layout-manager temporary
  attributes, so undo/redo, copy/paste and the source text are never touched.
- `Compiler` is fully decoupled from AppKit — it talks through closures
  (`onStatusStarted`, `onFinished(LatexReport)`), so it stays unit-testable.

## Legacy C++ implementation

`CMakeLists.txt` and `src/` contain the earlier C++20 / Qt 6 / Poppler
prototype, superseded by this native Swift build. Keep them only for reference.
