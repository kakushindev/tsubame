#!/usr/bin/env python3
"""Generate the app's asset catalog from docs/branding's supplied SVG masters.

Requires Python 3 and ImageMagick 7 (`magick`). Run from any directory.
"""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "docs/branding"
CATALOG = ROOT / "App/Resources/Assets.xcassets"
INFO = {"author": "xcode", "version": 1}


def write_contents(directory, contents):
    (directory / "Contents.json").write_text(
        json.dumps({**contents, "info": INFO}, indent=2) + "\n"
    )


def main():
    if not shutil.which("magick"):
        raise SystemExit("ImageMagick 7 is required: install it to provide `magick`.")

    icons = CATALOG / "AppIcon.appiconset"
    icons.mkdir(parents=True, exist_ok=True)
    images = []
    # Rasterize once at 4×, then downsample for smooth edges at every icon size.
    with tempfile.TemporaryDirectory(prefix="tsubame-brand-") as temporary:
        for platform in ("ios", "macos"):
            master = Path(temporary) / f"{platform}.png"
            subprocess.run([
                "magick", "-background", "none", "-density", "384",
                str(BRAND / f"icon-{platform}.svg"), str(master),
            ], check=True)
            sizes = (1024,) if platform == "ios" else (16, 32, 64, 128, 256, 512, 1024)
            for pixels in sizes:
                command = ["magick", str(master), "-resize", f"{pixels}x{pixels}"]
                if platform == "ios":
                    # iOS applies its own corner mask; its source must be opaque.
                    command += ["-background", "black", "-alpha", "remove", "-alpha", "off"]
                encoding = "PNG24" if platform == "ios" else "PNG32"
                command += [
                    "-colorspace", "sRGB", "-depth", "8", "-strip",
                    f"{encoding}:{icons / f'{platform}-{pixels}.png'}",
                ]
                subprocess.run(command, check=True)

    images.append({
        "filename": "ios-1024.png", "idiom": "universal",
        "platform": "ios", "size": "1024x1024",
    })
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            images.append({
                "filename": f"macos-{points * scale}.png", "idiom": "mac",
                "scale": f"{scale}x", "size": f"{points}x{points}",
            })
    write_contents(icons, {"images": images})

    mark = CATALOG / "BrandMark.imageset"
    mark.mkdir(parents=True, exist_ok=True)
    for filename in ("mark.svg", "mark-white.svg"):
        shutil.copyfile(BRAND / filename, mark / filename)
    write_contents(mark, {
        "images": [
            {"filename": "mark.svg", "idiom": "universal"},
            {
                "filename": "mark-white.svg", "idiom": "universal",
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
            },
        ],
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "original",
        },
    })
    print("Generated AppIcon and adaptive BrandMark from docs/branding SVG masters.")


if __name__ == "__main__":
    main()
