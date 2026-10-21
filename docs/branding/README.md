# Tsubame branding

The supplied **block-T** is Tsubame's primary logo. Its geometry and monochrome
palette are shared by the app, startup screens, and repository. Keep the name
**Tsubame** and publisher **Kakushin.dev**; the bundle ID is `dev.kakushin.tsubame`.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="mark-white.svg">
  <img src="mark.svg" width="128" height="128" alt="Tsubame block-T logo">
</picture>

## Supplied masters

These four SVGs are the unchanged source artwork. The two supplied PNG previews
are reference images, not the app's compiled icons.

| Asset | Use |
| --- | --- |
| [mark.svg](mark.svg) | Black standalone mark on a light background |
| [mark-white.svg](mark-white.svg) | White standalone mark on a dark background |
| [icon-ios.svg](icon-ios.svg) | Opaque 1024 × 1024 iPhone/iPad icon; the OS applies its corner mask |
| [icon-macos.svg](icon-macos.svg) | Mac icon with the supplied rounded black plate and transparent outer margin |
| [preview-ios.png](preview-ios.png) | Supplied iOS reference preview |
| [preview-macos.png](preview-macos.png) | Supplied macOS reference preview |

Use the appropriate master instead of redrawing the mark, adding a background to
the standalone artwork, or applying a second corner mask. Preserve its aspect
ratio, proportions, and internal cutouts. Use the black or white version for
contrast with its background. The Latin name remains the wordmark; 燕 may appear
as the Japanese name, rather than replacing the block-T logo.

## App integration

- `AppIcon.appiconset` contains an opaque iOS 1024 px icon and the complete Mac
  16–1024 px set, including Retina sizes. The macOS icon retains transparency.
  The system uses these for the Home Screen, Dock, Finder, and native About panel.
- `BrandMark.imageset` preserves the supplied vectors, with the black mark for
  light appearance and white mark for dark appearance.
- SwiftUI startup and the iPhone/iPad launch storyboard use the same centered
  128 pt mark on the system background. Startup has no artificial delay.
- App controls, typography, tint, and status colors keep their native semantic
  appearance. Branding does not replace resource symbols or status meanings.

## Regeneration

Generated assets are committed so normal builds need no extra graphics tools.
To regenerate after editing a master, install Python 3 and ImageMagick 7, then run
from the repository root:

```sh
python3 scripts/generate-brand-assets.py
xcodegen generate
```

The generator copies both mark variants into the asset catalog and rasterizes
the platform icons at 4× before downsampling to their required sizes. It writes
8-bit RGB iOS PNGs without alpha and RGBA Mac PNGs with transparency. Do not edit
the generated catalog artwork directly.
