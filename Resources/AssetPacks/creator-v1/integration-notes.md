# Framecast Asset Pack Integration Notes (`framecast-creator-assets-v1`)

This document explains how `framecast-creator-assets-v1` works with Framecast today and outlines the engineering steps required for deeper native integration.

##Important Baseline Constraints

1. **Current Framecast Wallpaper & Image Architecture**:
   - Framecast currently imports local image files as `SourceKind.image(path: String)` loaded via `CIImage(contentsOf:)`.
   - Its built-in wallpaper picker (`Sources/FramecastEngine/Compositor/Wallpapers.swift`) renders eight procedural backgrounds defined in Swift code rather than scanning an external asset directory.
   - Dropping this folder into the repository does **not** automatically populate Framecast's wallpaper picker, nor does the existing application parse `manifest.json` yet.
2. **Path Stability Requirement for `SourceKind.image(path: String)`**:
   - When a user imports PNG/JPEG files from this pack through Framecast's existing Image source workflow (`Sources/Framecast/Sheets.swift` and `Sources/Framecast/EditPanel.swift`), Framecast stores the file's filesystem path in the scene model.
   - **Moving, renaming, or deleting the unzipped `framecast-creator-assets-v1` folder after importing assets into a project will break path-based image references.** Users should place the unzipped pack in a permanent directory (for example, `~/Library/Application Support/Framecast/AssetPacks/framecast-creator-assets-v1/` or `~/Pictures/FramecastAssets/`) before building scenes.

## Tier A — Immediately Usable via Framecast's Existing Image Source Workflow (`integrationStatus: "image-source-ready"`)

All **108 primary runtime PNG files** (and the **24 light/dark annotation variants**) can be imported today as standard image layers via `SourceKind.image(path: String)`:

- **20 Background Families (`assets/backgrounds/<asset-id>/horizontal.png` & `vertical.png`)**:
  - Import as the bottom-most image layer (`recommendedLayer: "background"`, `suggestedFitMode: "fill"`).
  - Bind `horizontal.png` (`3840×2160`) to the 16:9 canvas and `vertical.png` (`2160×3840`) to the 9:16 canvas.
- **12 Stream Scene Plates (`assets/stream-scenes/<asset-id>/horizontal.png` & `vertical.png`)**:
  - Import as a full-canvas backdrop on Starting Soon, Be Right Back, or Ending scenes, then place Framecast's existing native editable title/subtitle/QR overlay elements on top using the suggested normalized coordinates in `manifest.json`.
- **8 Camera / Guest Frames (`assets/frames/<asset-id>/horizontal.png` & `vertical.png`)**:
  - Import as a foreground RGBA image layer positioned **above** the camera/screen sources (`layerOrder: ["background", "camera-or-screen-sources", "frame-decoration", "editable-text"]`).
  - Because the apertures in `assets/frames/` have genuine `alpha == 0` transparency, positioning camera and screen sources behind the frame apertures works immediately in the Core Image compositor.
- **8 Editable Card Backplates (`assets/cards/<asset-id>/horizontal.png` & `vertical.png`)**:
  - Import as a full-canvas transparent RGBA overlay layer behind native text or QR elements.
- **12 Universal Annotations (`assets/annotations/<asset-id>/asset.png`, `variant-light.png`, `variant-dark.png`)**:
  - Import as a floating image source layer (`suggestedFitMode: "fit"`) and position/scale over shared screens or code windows.

## Tier B — Small Loader, Picker & Packaging Changes Needed to Bundle and Browse the Pack

To expose `framecast-creator-assets-v1` directly inside Framecast's UI without manual file-picker imports, make the following targeted updates across the existing codebase:

1. **`Package.swift` & `scripts/build_app.sh` (Resource Packaging)**:
   - In `Package.swift`, register the asset pack directory or copy it during app bundle assembly in `scripts/build_app.sh` into `Framecast.app/Contents/Resources/AssetPacks/framecast-creator-assets-v1/`.
   - Prefer resolving bundled assets via pack-relative paths (`<packId>/<variant.path>`) resolved against `Bundle.main.resourceURL` so projects remain portable across machines.
2. **`Sources/FramecastEngine/Compositor/Wallpapers.swift` (Wallpaper Catalog Expansion)**:
   - Extend the wallpaper model to support both `.procedural(ProceduralWallpaper)` and `.bundledAsset(id: String, horizontalPath: URL, verticalPath: URL)` loaded lazily via `CIImage(contentsOf:)` and cached by asset ID + orientation.
3. **`Sources/Framecast/EditPanel.swift` & `Sources/Framecast/Sheets.swift` (Asset Browser UI)**:
   - Decode `manifest.json` using `Codable` structs matching `manifest.schema.json`.
   - Display the lightweight `previews/<category>/<asset-id>-<variant>.jpg` thumbnails (`≤480px`) in the picker grid, grouped by `styleFamily` (`obsidian-mint`, `paper-ink`, `warm-studio`, `deep-blue`) and `category`.
   - When the user selects an asset, load `variants.horizontal.path` for the 16:9 canvas and `variants.vertical.path` for the 9:16 canvas simultaneously.

## Tier C — Features Requiring Native Template & Overlay Renderer Integration (`integrationStatus: "requires-native-template-integration"`)

While every image file can be loaded as an Image source today, full template automation requires updates to `SceneModel.swift`, `Templates.swift`, and `OverlayRenderer.swift`:

1. **Coordinate System Conversion (`normalized-top-left` → Core Image Bottom-Left)**:
   - All `rect` definitions in `manifest.json` (`contentRegions`, `textRegions`, `transparentApertures`) use top-left origin `[0, 1]`.
   - When mapping `transparentApertures` or `textRegions` into Core Image (`CIImage` / `OverlayRenderer.swift`), convert the Y coordinate via:
     ```swift
     let ciX = rect.x * canvasWidth
     let ciY = (1.0 - rect.y - rect.height) * canvasHeight
     let ciW = rect.width * canvasWidth
     let ciH = rect.height * canvasHeight
     ```
2. **Automatic Camera/Screen Cropping to `transparentApertures` (`Sources/FramecastEngine/Model/Templates.swift`)**:
   - Each frame entry in `manifest.json` specifies `transparentApertures` with `maskShape` (`"rounded-rect"` or `"circle"`), `rect`, and `cornerRadiusNormalized`.
   - To make a 1-click layout template in `Templates.swift`, bind each camera/screen source transform to the aperture's `rect`, apply Framecast's existing circular or rounded-rectangle mask matching `cornerRadiusNormalized`, and place the frame PNG on the layer immediately above.
3. **Native Editable Typography, Live Countdowns & QR Code Generation (`Sources/FramecastEngine/Compositor/OverlayRenderer.swift` & `SceneModel.swift`)**:
   - Runtime stream scene plates (`assets/stream-scenes/`), card backplates (`assets/cards/`), and step markers (`fc-v1-annot-step-*`) are intentionally **text-free** and **QR-free**.
   - `manifest.json` provides `textRegions` (`rect`, `alignment`, `hierarchy`, `maxLines`, `relativeFontSize`, `suggestedFont`, `suggestedColor`, `exampleText`) and `contentRegions` (including `qr-quiet-zone` and `countdown-slot`).
   - Integrating these as smart overlays requires `OverlayRenderer.swift` to composite the PNG backplate first and then draw native Core Text / `NSAttributedString` strings (or a `CIQRCodeGenerator` output inside the `qr-quiet-zone` rectangle) on top, driven by Framecast's native overlay motion curves (`slide`, `rise`, `pop`, `fade`).
