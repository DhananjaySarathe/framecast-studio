# Backgrounds

## How they work

Every scene has a background layer at the bottom; the camera, screen, guests and text sit on top of it. Most scenes
share one background, so changing it changes them all (the picker asks when it's shared).

There are two kinds:

- **Pictures** from the asset packs in `Resources/AssetPacks/`: the creator pack's 20, plus 32 in the background
  library (`Resources/AssetPacks/backgrounds/`, built with `scripts/add_backgrounds.swift`). Each picture has its own
  16:9 and 9:16 version, and each canvas shows its own. They ship as 10-bit HEIC (fine grain is added back when they
  load, so gradients don't band), are decoded at the canvas size off the render thread, and are released when no
  scene uses them.
- **Basic**: eight backgrounds Framecast draws itself (`Wallpapers.swift`), sharp at any size.

## Choosing one

- Layer tab: select the Background layer, then **Change background…**
- Right-click the Background layer › Change Background…, or **Show › Change Background… (⇧⌘B)**
- Add to scene › Pictures (or Creator pack) › **Backgrounds…**

The picker groups backgrounds (Gradients, Aurora, Abstract, Textures, Rooms, any new groups, Basic), filters Dark
or Light, and previews the 16:9 or 9:16 version in the grid. On the right, **On your scene** shows the selected
background behind your scene as it is right now (camera, screens, text), on both canvases, updated five times a
second; **Picture only** shows the picture alone. The preview uses the scene you're editing, or, if a camera or
screen fills that one, another scene with the same background; pick any of them from the menu above the preview.
Double-click or **Use background** applies it.

## Adding backgrounds

1. Put the pictures in a folder, one sub-folder per group, each background as a pair:

   ```
   new-backgrounds/
     gradients/Violet Haze 16x9.png
     gradients/Violet Haze 9x16.png
     rooms/Lamp-lit Desk 16x9.png
     rooms/Lamp-lit Desk 9x16.png
   ```

   Groups: `gradients`, `aurora`, `abstract`, `textures`, `rooms`, or a new folder name (it becomes a new group).
   PNG, JPEG, WebP or HEIC. Without "16x9"/"9x16" in the name the picture's shape decides. A `<Name>.txt` next to
   the pair holds the one-line description the picker shows.

2. Import them, then rebuild:

   ```
   swiftc -O scripts/add_backgrounds.swift -o build/add_backgrounds
   build/add_backgrounds --deband new-backgrounds
   scripts/build_app.sh
   ```

   Pictures are cropped to exactly 16:9 or 9:16 around the centre (the script says how much), scaled down to 4K at
   most, and refused below 1280×720. Each is marked Dark or Light from its brightness. Importing a background with
   the same group and name again replaces it. `--deband` (needs ffmpeg) smooths the steps 8-bit pictures show in
   dark gradients before they're stored at 10 bits; lines and edges stay sharp.

## What's in the library

The first batch had 50 generated pairs. 32 went in; 18 were left out because they repeated another one in the same
colours and layout, or looked like a background Framecast already had:

- Gradients: Velvet Indigo (same as Obsidian Pulse and Violet Haze)
- Aurora: Cyber Dusk (same as Violet Aurora), Solar Mist (same as Pastel Drift)
- Abstract: Frosted Layers (same glass cards as Glass Prism), Silk Fold (same as Soft Ribbons)
- Textures: Carbon Matte (same as Basic › Midnight), Smoked Acrylic (same as Graphite Violet), Soft Linen (same as
  the creator pack's ivory paper)
- Rooms: Podcast Booth and Bookshelf Blur (same as Lamp-lit Desk), Vinyl Lounge (same as Neon Studio), Midnight
  Loft (between City Window and Lamp-lit Desk), Plant Corner (between Bright Loft and Morning Leaves), Sunlit
  Studio (same as the creator pack's daylight workspace)
- Nature: Dune Light (flat, with plastic-looking streaks), Twilight Pines (a dark smudge that reads as a dirty lens)
- Neon: Laser Mist (same as Magenta Fog), Violet Cyber (same as Violet Aurora)

## Prompt for generating them

Give this to an image generator. It matches what the importer expects.

```text
You're making background images for Framecast, a Mac app for recording videos and live streaming to YouTube,
Twitch, Shorts and Reels. In Framecast the background sits behind the presenter's camera, a shared screen and
on-screen text. Most of the time the middle of the background is covered, so the background sets the mood. It is
not the subject.

Every background is a matching pair of the same design:
- 16:9 landscape, 3840×2160 (at least 1920×1080), for YouTube and recordings
- 9:16 portrait, 2160×3840 (at least 1080×1920), for Shorts, Reels and TikTok
Recompose the design for each shape. Don't just crop or stretch the landscape one.

Rules for every image
- Keep the centre calm: low contrast and no busy detail in the middle (about 70% wide × 65% tall in landscape,
  72% × 62% in portrait). Put the colour, light and shapes toward the edges and corners.
- Portrait version: also keep the top 10%, the bottom 20% and the right 14% plain. Phone apps put captions and
  buttons there.
- No text, letters, numbers, logos, watermarks, signatures, app screens, people, faces, hands or animals. Nothing
  recognisable: no brands, characters or landmarks.
- No fine noise, glitter or dense tiny patterns. They turn to mush in a live stream. Smooth gradients are fine.
- No hard line (horizon, table edge, shelf) running across the middle.
- Rooms and places: defocused, like a shallow-depth-of-field photo behind a speaker. Nothing sharp, and no
  readable book spines or posters.
- Flat and opaque (no transparency), sRGB, PNG, at the highest resolution your tool allows. If the tool can't make
  exactly 16:9 or 9:16, make the closest shape and keep anything important away from the edges that will be
  cropped.

Groups (one folder each, named exactly like this)
- gradients: smooth two- or three-colour gradients with a soft glow
- aurora: soft mesh and aurora colour clouds
- abstract: large simple shapes such as ribbons, waves, glass panels and paper planes
- textures: subtle surfaces such as paper, linen, concrete, brushed metal and frosted acrylic
- rooms: defocused real spaces such as a studio, desk, bookshelf, plants or a city window
- A new folder name becomes a new group, for example neon, nature or seasonal.

Already in the app, so don't repeat these looks: mint on charcoal, ivory paper, terracotta and peach, deep blue
with cyan. Most of those are dark.
Wanted:
- Framecast violet: a #7D6BFF glow on near-black #0B0D11
- Light, bright, creator-friendly colours: lilac, sky, mint, butter, blush
- About half light and half dark overall
- Soft neon for gaming: magenta, cyan and purple on black
- Daylight nature, defocused: leaves, sand, sky
- Cosy spaces: a home office, a podcast booth with warm lamps, a city at night through a window (bokeh)
- A few almost plain ones: nearly solid colour with a gentle vignette

File names
"<Name> 16x9.png" and "<Name> 9x16.png", with the same name for both. The name is what people see in the picker,
so use 2–3 plain words. No numbers, and don't put "background" in the name.

framecast-backgrounds/
  gradients/Violet Haze 16x9.png
  gradients/Violet Haze 9x16.png
  rooms/Lamp-lit Desk 16x9.png
  rooms/Lamp-lit Desk 9x16.png

First batch, one pair each:
gradients/Violet Haze: near-black with a soft violet glow rising from the lower right
gradients/Lilac Morning: light lilac to white, faint warm light top left
gradients/Sky Wash: pale sky blue to soft white, airy
gradients/Peach Sorbet: light peach to cream with a blush corner glow
gradients/Graphite Violet: dark graphite with a thin violet edge light
aurora/Violet Aurora: violet and indigo clouds drifting around the edges of a dark frame
aurora/Pastel Drift: light pastel lilac, mint and butter clouds, very soft
aurora/Northern Teal: dark navy with teal and green aurora along the top edge
abstract/Soft Ribbons: two wide violet ribbons curving through the corners, dark
abstract/Paper Waves: light layered paper waves in off-white and lilac along the bottom
abstract/Glass Prism: dark frosted glass panels with a faint rainbow edge light
textures/Warm Concrete: light warm-grey concrete, very subtle
textures/Brushed Steel: dark brushed metal, soft horizontal sheen at the top
textures/Lilac Paper: light lilac cotton paper
rooms/Lamp-lit Desk: defocused home desk at night, warm lamp bokeh at the sides
rooms/Podcast Booth: defocused acoustic foam and warm practical lights
rooms/City Window: defocused night city lights through a large window
rooms/Bright Loft: defocused daylight loft with white walls and plants at the edges
rooms/Plant Corner: defocused green plants in soft daylight, light
neon/Magenta Fog: soft magenta and cyan glow on black, hazy
nature/Morning Leaves: defocused green leaves in morning light, light
nature/Dune Light: soft sand dunes at golden hour, very defocused

Make the 16:9 version first, then the 9:16 version of the same design. Follow every rule above for both.
```
