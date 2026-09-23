# Dotto app icon

Concept D, variant D2 "Overlap": a lowercase d where the bowl is Dotto's dot and the stem's top is cut like a
pointer tip. Klein blue `#3B2BF0` on the light background. All numbers below are on the 1024 × 1024 canvas.

## Files

| File | What it is |
|------|------------|
| `icon-1024.svg` | The flattened icon: squircle, background, d, top sheen and hairline edge. Matches `Dotto/Assets.xcassets/AppIcon.appiconset/1024-mac.png`. |
| `background.svg` | Full-bleed background, no squircle (Icon Composer applies the shape). Linear gradient `#FFFDFB` at the top to `#EEE9F1` at the bottom. |
| `glyph.svg` | The d alone on transparent, in Klein blue, at the same size and position as in `icon-1024.svg`. Fill-only paths, no strokes. |
| `glyph-mono.svg` | The same d in black, for tinted and clear appearances or anywhere a single color is needed. |
| `Dotto.icon/` | An Icon Composer document built from the files above (see "Adopting Dotto.icon"). |

The PNGs in the app's asset catalog and these SVGs are all produced by one CoreGraphics script,
`scripts/icon/DottoIconBuild.swift`. It draws with CoreGraphics directly and needs no SVG rasterizer:

```bash
swiftc -O scripts/icon/DottoIconBuild.swift -o /tmp/DottoIconBuild && /tmp/DottoIconBuild Dotto/Assets.xcassets/AppIcon.appiconset design/icon
```

## Geometry

**Canvas and body.** 1024 canvas, 824 body. The body is a superellipse with exponent n = 5 and semi-axis 412,
centered at (512, 512), so it spans 100 to 924 on both axes.

**Background (light).** A vertical linear gradient across the body from `#FFFDFB` to `#EEE9F1`. On top of the d
comes a sheen: white at 35% opacity at the top of the body, fading to 0 at 45% of the body's height. Last comes
a hairline edge: the squircle stroked 4 units wide in black at 8% opacity.

**The d, in glyph units.** The bowl is centered on the origin with y growing downward. The reference bowl
diameter is 330.

| Part | Value |
|------|-------|
| Bowl radius | 165 |
| Stem width | 0.42 × 330 = 138.6 |
| Ascender above the bowl | 0.62 × 330 = 204.6, so the stem top is at y −369.6 |
| Overlap of bowl into stem | 0.14 × 330 = 46.2, so the stem spans x 118.8 to 257.4 |
| Stem baseline | y 160.05. The bowl dips 3% of its radius (4.95) below it, as round shapes overshoot flat ones. |
| Tip cut | 35° below horizontal, falling right from the high top-left point. Drop is 138.6 × tan 35° = 97.05. |
| Stem corner rounding | 18 (the lab's weight 4: 6 + 4 × 3), which gives an arc radius of 9 at every stem corner |
| Bounding box | x −165 to 257.4, y −369.6 to 165 (422.4 × 534.6) |

**Placement on the canvas.** The glyph scale is 1, so the larger side of the bounding box becomes 520 units.
That makes the fit 520 / 534.6 = 0.97269. The box is centered on (512, 512):

| Part | 1024 canvas |
|------|-------------|
| Bowl | center (467.06, 611.51), radius 160.49 |
| Stem | x 582.62 to 717.43 (134.81 wide). Top-left corner at y 252.00. The cut ends at (717.43, 346.40). Baseline at y 767.19. |
| Bowl bottom | y 772.00 |
| Overlap | 44.94 |
| Stem corner radius | 8.75 |
| Glyph bounds | x 306.57 to 717.43, y 252.00 to 772.00 |

**Small-size master (16 and 32 px files).** These files use a hinted d, matching the lab's rules below 32 pt:

- The d is drawn 8% larger (×1.08).
- The stem is at least 2.4 px wide.
- A near-kiss (0.35 px or less) merges into a 1 px overlap, and a gap under 1.5 px opens to 1.5 px. D2 already
  overlaps, so neither case applies to it.
- The tip keeps at least 1.5 px of drop.

After hinting, the whole d is shifted so the stem's left edge and baseline sit on whole pixels. The stem's width
and top are then rounded to whole pixels. The 64 px file gets the same snapping without the hinted master.
Results: at 16 px the stem is 3 px wide with a 1.68 px tip drop and a 0.76 px overlap; at 32 px the stem is 5 px
wide with a 3.19 px tip drop. The 32 px file is used for both 16 pt @2x and 32 pt @1x.

**Menu bar glyph.** `Dotto/UI/MenuBar/MenuBarGlyph.swift` draws the same d as an 18 × 18 pt template image. The
d fits a 16 pt box and is rendered separately at 1x and 2x, with the same hinting and snapping, so both scales
stay crisp.

## Assembling in Icon Composer by hand

1. Open Icon Composer (Xcode 26: Xcode › Open Developer Tool › Icon Composer) and create a new document with the
   macOS platform only.
2. **Document fill:** choose Gradient, `#FFFDFB` at the top and `#EEE9F1` at the bottom. You can drag in
   `background.svg` as a bottom layer instead, but a document fill is better. It lets the system swap in its dark
   and tinted backgrounds, while an image layer would stay light in Dark mode.
3. **Group "d":** drag in `glyph.svg` as its only layer. Icon Composer's canvas is full-bleed, while the 824 body
   in `glyph.svg` sits inside a 1024 canvas. Set the layer's scale to **124%** (1024 / 824 = 1.2427) so the d
   has the same proportion to the shape as in the flattened icon.
4. **Glass and lighting on the group:**
   - Liquid Glass: on.
   - Specular: on.
   - Shadow: Neutral at 50%.
   - Translucency: on at about 30%. Higher values wash the Klein blue out on the light fill.
   - Blur: off.
   - Leave the layer's own fill as "none" so the SVG's blue shows through in the Default appearance.
5. **Mono and tinted:** Icon Composer derives these from luminance, which already reads well (checked with
   `ictool` renders). If the tinted d looks too dim, add a fill specialization for the Mono appearance on the
   glyph layer with a solid white. Alternatively, swap in `glyph-mono.svg` and let the system tint it.
6. Leave the dark appearance on its automatic background. The Klein d holds up on it without a specialization.
   The lab's dark-mode glyph color, if you want one, is `#4B3CF1`.

## Adopting Dotto.icon

`Dotto.icon` follows the steps above. It is a gradient document fill, plus one group containing `glyph.svg` at
scale 1.2427 with glass, specular, a neutral 50% shadow and 30% translucency. It was checked with Icon
Composer's command-line renderer in the Default, Dark, ClearLight and TintedLight renditions:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  design/icon/Dotto.icon --export-image --output-file /tmp/dotto.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

It is **not** part of the Xcode target yet. To adopt it (Xcode 26, macOS 26 SDK):

1. Copy `design/icon/Dotto.icon` to `Dotto/AppIcon.icon`. It sits next to `Assets.xcassets`, not inside it. The
   `Dotto` folder is a synchronized group, so Xcode picks it up without editing the project file.
2. In the Dotto target's Build Settings, make sure **App Icon Set Name** (`ASSETCATALOG_COMPILER_APPICON_NAME`) is
   `AppIcon`. Xcode 26 builds the macOS 26 icon from the `.icon` and also generates flattened images for older
   systems (the deployment target is macOS 14.2). If Xcode reports a duplicate `AppIcon`, rename or remove
   `Assets.xcassets/AppIcon.appiconset`. Its PNGs are still here in `icon-1024.svg` and the build script.
3. Build in Xcode (not `xcodebuild` from the terminal, because it invalidates TCC grants) and check the Dock icon.
