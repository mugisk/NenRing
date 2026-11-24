# NenRing icon assets

`AppIcon-light.iconset` and `AppIcon-dark.iconset` contain the supplied,
pre-rendered PNG artwork. They are the authoritative app and in-window icons.
`scripts/build-app.sh` validates every size and packages them with `iconutil`,
without rendering the SVG or modifying the source PNG pixels.

ICNS packaging uses the system's legacy encoding at 16/32 pixels, which can
alter translucent edge pixels. Other supplied representations round-trip
without pixel changes. In-window icons use the original PNGs directly.

In-window SSD icons use the small-size PNG artwork for compact views and the
larger PNG artwork for the dashboard. Existing automatic/light/dark selection
is preserved. Finder uses the light ICNS; the running app may select either.

The monochrome menu bar still uses `nenring-menubar.svg` as an NSImage template.
The supplied `nenring-menubar-12.svg` remains available as a smaller variant.
The same artwork set is used throughout the app, and the menu bar SVGs keep the
stable filenames above. The 64-point dashboard icon uses the 128-pixel artwork,
while the popup and sidebar use the 64-pixel artwork.

Color SVGs and the older SVG conversion script are retained as source/reference
material, but are not used to generate the app icon or in-window SSD icons.
