# The Shotts website

One page about Shotts, written in [Rip](https://github.com/shreeve/rip) and styled with Rip's
Tailwind runtime, in light and dark.

```
app/
  index.html          the page's shell: meta tags, the theme before first paint, the loading icon,
                      a no-JavaScript fallback, and the boot
  index.css           Tailwind, and the light and dark tokens in the icon's colors
  routes/index.rip    the page
  components/         icons, small parts (keys, the copyable command, headings, the theme
                      switch), and the pictures of Shotts at work, drawn in HTML and SVG
build.sh              makes dist/
```

## Build and preview

```bash
website/build.sh
python3 -m http.server 8411 --directory website/dist
```

Then open http://localhost:8411. `build.sh` copies the shell and styles, the icon (SVG, and a
512-pixel PNG for link previews), Rip's browser runtime and Tailwind runtime from a Rip checkout
(`RIP`, default `~/Data/Code/rip`), and writes `bundle.json`: every `.rip` module under `app/`
plus `version.rip`, the release the page offers (`VERSION`, default the latest `v*` tag). Rip
compiles the modules in the browser and keeps them in IndexedDB, so a visit after the first
compiles nothing.

`dist/` is static files and nothing else, so any static host serves it. On GitHub Pages it is
served from `/shotts/`, which the shell passes to the router as its base; locally, from `/`. It
carries `.nojekyll`, since Jekyll would hide the `@rip` folder.

## Changing it

The release on offer comes from the tags, so after a release a rebuild is all the page needs.
Words and sections are in `routes/index.rip`; the pictures in `components/mockups.rip` scale as
one through container units (`cqw`), so a change there keeps its proportions at every width.
Check both themes (the moon and sun in the bar) and a phone width before publishing.
