# Framecast Creator Assets v1 (`framecast-creator-assets-v1`)

A cohesive, production-ready library of **60 original broadcast design families** (**108 primary runtime exports**, plus **24 light/dark annotation variants**, **76 editable SVG vector sources**, **108 variant preview thumbnails**, **8 composed demonstration scenes**, and **3 contact sheets**) designed specifically for **Framecast** on macOS.

Every multi-aspect family includes deliberately composed **Horizontal (`3840 × 2160`, 16:9)** and **Vertical (`2160 × 3840`, 9:16)** runtime exports to support Framecast's signature simultaneous landscape + portrait recording and live-streaming workflow.

## Visual Families

1. **Obsidian Mint (`obsidian-mint`)**: Deep charcoal and navy surfaces (`#0D131A`, `#141E28`) with restrained teal-mint highlights (`#2DD4BF`, `#5EEAD4`) for technical presentations, coding sessions, and architecture reviews.
2. **Paper & Ink (`paper-ink`)**: Warm ivory and stone-gray tactile paper surfaces (`#FAF7F2`, `#F3EFE6`) with dark ink accents (`#1C1917`, `#8C6D53`) for high-readability editorial tutorials and design walkthroughs.
3. **Warm Studio (`warm-studio`)**: Terracotta, peach, warm sand, and espresso-amber tones (`#241510`, `#C86D51`, `#E59872`, `#F4C095`) for welcoming creator streams, interviews, and conversational podcasts.
4. **Deep Blue (`deep-blue`)**: Midnight blue canvases (`#080D1E`, `#0F1734`) with soft cyan (`#38BDF8`) and restrained indigo-violet (`#818CF8`) accents for product demonstrations, keynotes, and evening streams.

## Inventory Summary (60 Design Families / 108 Primary Runtime Exports)

| Category | Families | Primary Runtime Exports | Resolution / Format | Editable SVG Sources | Preview Thumbnails |
| :--- | :---: | :---: | :--- | :---: | :---: |
| **A. Backgrounds** (`assets/backgrounds/`) | 20 | 40 (20 × 16:9, 20 × 9:16) | `3840×2160` & `2160×3840` Opaque sRGB PNG | 8 (4 abstract families × 2) | 40 |
| **B. Stream Scene Plates** (`assets/stream-scenes/`) | 12 | 24 (12 × 16:9, 12 × 9:16) | `3840×2160` & `2160×3840` Opaque sRGB PNG (Text-Free) | 24 (12 families × 2) | 24 (with sample text) |
| **C. Camera / Guest Frames** (`assets/frames/`) | 8 | 16 (8 × 16:9, 8 × 9:16) | `3840×2160` & `2160×3840` RGBA Transparent PNG | 16 (8 families × 2) | 16 (on checkerboard) |
| **D. Editable Card Backplates** (`assets/cards/`) | 8 | 16 (8 × 16:9, 8 × 9:16) | `3840×2160` & `2160×3840` RGBA Transparent PNG (Text/QR-Free) | 16 (8 families × 2) | 16 (with sample text) |
| **E. Universal Annotations** (`assets/annotations/`) | 12 | 12 primary (+ 24 light/dark variants) | Up to `1400×840` (`≤2048px`) RGBA Transparent PNG | 12 (self-contained SVGs) | 12 (on checkerboard) |
| **Total** | **60** | **108 primary (+ 24 variants)** | **sRGB PNG** | **76 SVGs** | **108 + 8 demos + 3 sheets** |

## Package Structure

```text
framecast-creator-assets-v1/
  README.md
  manifest.json
  manifest.schema.json
  design-tokens.json
  provenance.json
  integration-notes.md
  validation-report.json
  gallery.html
  assets/
    backgrounds/<asset-id>/horizontal.png
    backgrounds/<asset-id>/vertical.png
    stream-scenes/<asset-id>/horizontal.png
    stream-scenes/<asset-id>/vertical.png
    frames/<asset-id>/horizontal.png
    frames/<asset-id>/vertical.png
    cards/<asset-id>/horizontal.png
    cards/<asset-id>/vertical.png
    annotations/<asset-id>/asset.png
    annotations/<asset-id>/variant-light.png
    annotations/<asset-id>/variant-dark.png
  editable/
    backgrounds/<asset-id>-horizontal.svg
    backgrounds/<asset-id>-vertical.svg
    stream-scenes/<asset-id>-horizontal.svg
    stream-scenes/<asset-id>-vertical.svg
    frames/<asset-id>-horizontal.svg
    frames/<asset-id>-vertical.svg
    cards/<asset-id>-horizontal.svg
    cards/<asset-id>-vertical.svg
    annotations/<asset-id>.svg
  previews/
    backgrounds/<asset-id>-horizontal.jpg
    backgrounds/<asset-id>-vertical.jpg
    stream-scenes/<asset-id>-horizontal.jpg
    stream-scenes/<asset-id>-vertical.jpg
    frames/<asset-id>-horizontal.jpg
    frames/<asset-id>-vertical.jpg
    cards/<asset-id>-horizontal.jpg
    cards/<asset-id>-vertical.jpg
    annotations/<asset-id>-universal.jpg
    demo-<style-family>-horizontal.jpg
    demo-<style-family>-vertical.jpg
  contact-sheets/
    backgrounds.jpg
    scenes.jpg
    overlays.jpg
```

## Coordinate System & Safe Insets Convention

- **Normalized Top-Left Coordinates (`normalized-top-left`)**: All `rect` fields (`x`, `y`, `width`, `height`) in `manifest.json` and `design-tokens.json` are normalized to `[0.0, 1.0]` with `(0.0, 0.0)` at the **top-left** of the displayed canvas.
- **Core Image (`CIImage`) Conversion**: Because Core Image uses a bottom-left Cartesian origin, convert any normalized top-left rectangle `(x, y, w, h)` to pixel coordinates `(px, py_ci, pw, ph)` via:
  - `px = x * canvasWidth`
  - `py_ci = (1.0 - y - h) * canvasHeight`
  - `pw = w * canvasWidth`
  - `ph = h * canvasHeight`
- **Quiet Zone & Safe Insets**:
  - Backgrounds maintain a calm central content target (~`70%` wide × `65%` high) so shared screens, code editors, and presenter cameras remain legible.
  - Portrait (`9:16`) layouts apply larger right (`14%`) and bottom (`18%`) recommended safe insets to avoid common vertical live-stream and short-form platform UI chrome. Platform overlays vary by service and device; these insets are practical guidance rather than universal guarantees.

## Browsing the Library Locally

Open `gallery.html` directly in Safari, Chrome, or Firefox (no web server, internet connection, or external dependencies required) to inspect all 60 families, toggle between 16:9 and 9:16 previews, filter by style family or category, and view composed demonstration scenes and contact sheets.
