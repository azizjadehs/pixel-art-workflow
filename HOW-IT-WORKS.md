# How this workflow works

A plain-language tour of what happens between "here is my drawing" and "here is a
multi-frame `.aseprite` you can animate", plus the technology behind each step.

---

## 1. The pipeline at a glance

```
 your art (png/jpg)
        │
        ▼
 [1] Gemini image model  ──►  character sheet (front / 3-4 / side / back)
        │                     ~1 MB PNG, photographic colour depth
        ▼
 [2] Aseprite + Lua       ──►  small pixel-art image
        │                     exact pixel grid, ≤ N colours, real palette
        ▼
 [3] Projection slicer    ──►  uniform cells + JSON + multi-frame .aseprite
        │
        ▼
 [4] Local web app        ──►  upload, run, browse, animate, download
```

Each step has one job. The important design decision is **where** the pixel work
happens: it is *not* in the AI model.

---

## 2. Why the AI does not make the pixels

Image generation models produce *pictures of pixel art*, not pixel art. During
development three different prompt variants were measured on a 1024×1024 result:

| What was measured | Result |
|---|---|
| Colours in the output | 50,000+ unique RGB values |
| Colour transitions landing exactly on a 16 px grid | ≈ 6 % |
| Pixel edges | soft, anti-aliased, irregular |

So the model is excellent at **composition and design** — inventing a character
sheet with four consistent views — and bad at **quantisation**, which is a
different mathematical problem.

The split of responsibilities:

| Step | Tool | Strength |
|---|---|---|
| Design, poses, consistency | Gemini (`gemini-2.5-flash-image`) | semantic understanding |
| Grid, palette, file format | Aseprite + Lua | exact arithmetic |
| Sprite detection | classical image processing | deterministic, pixel-exact |

A vision model was also tried for detection. Its bounding boxes were typically
10–30 px off, which is fatal when a sprite is only 72 px wide. Detection is
therefore done with projection profiles (§6), not with a model.

---

## 3. Step 1 — the character sheet (Gemini)

**File:** `generate.ps1`

* Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent`
* Auth: `x-goog-api-key` header, key read from `GEMINI_API_KEY` or a local
  `.env` / `.env.txt` (both gitignored)
* Request body:

```jsonc
{
  "contents": [{
    "parts": [
      { "text": "<prompt.txt contents>" },
      { "inlineData": { "mimeType": "image/png", "data": "<base64 of your art>" } }
    ]
  }],
  "generationConfig": { "responseModalities": ["TEXT", "IMAGE"] }
}
```

* The prompt (`prompt.txt`) asks for a **character sheet**: the same character in
  front, three-quarter, side and back views, on a flat background, evenly spaced.
* The reply contains base64 image bytes; the script writes
  `<name>-generated.png` and also an `.aseprite` copy of the raw result
  (so the untouched AI output can be opened in Aseprite).
* If the model answers with text only (refusal, safety block), the script stops
  with the model's explanation instead of writing an empty file.

Things worth knowing:

* It is **non-deterministic** — two runs give two different sheets.
* One run = **one API call**.
* The model may return 4 poses, sometimes 6. The slicer adapts; only the frame
  tag names fall back to `view-1 … view-N` when the count isn't 4.

---

## 4. Step 2 — real pixelation (Aseprite + Lua)

**Files:** `run.ps1`, `scripts/pixelate.lua`

Aseprite is driven headlessly (`aseprite -b … --script pixelate.lua`) so the
result is a real `.aseprite` document with layers, frames and a palette — not a
filtered PNG.

### 4.1 Choosing the grid

Two mutually exclusive modes:

| Mode | Formula | Use |
|---|---|---|
| `-Percent 30` | `round(source × 0.30)` per axis | "keep 30 % of my resolution" |
| `-Size 256` | scale to fit inside 256×256, aspect preserved, never upscale | "give me roughly this size" |

`-Percent` wins when both are given. A 768×1344 source at 30 % becomes
230×403; the same source at `-Size 256` becomes 146×256.

### 4.2 Sampling — two filters

For every destination pixel the script reads the corresponding source region:

**Nearest neighbour** (default) — take the colour at the centre of the source
cell:

```
srcX = floor((dstX + 0.5) × srcW / dstW)
```

Crisp, hard edges, preserves the drawn shapes. This is the "real pixel art"
look.

**Box average** (`-Filter average`) — average every source pixel in the cell,
weighted by alpha, then keep it only if average alpha ≥ 128:

```
dest = Σ(rgb × a) / Σa
```

Softer; useful when the AI's internal pixel grid does not line up with ours.

Transparent pixels are handled separately: alpha < 128 becomes fully
transparent, otherwise the colour is kept at full alpha. That produces a clean
cut-out silhouette rather than a halo.

### 4.3 Palette — median cut to N colours

The downscaled image still has thousands of colours. To reach a game-style
palette (26 by default):

1. Count how many pixels use each unique RGB value.
2. Put all colours in one "box".
3. While there are fewer boxes than `-Colors`:
   * find the box with the **widest channel range** (R, G or B),
   * sort that box along that channel,
   * split it at the median.
4. Each final box becomes one palette entry: the **pixel-count-weighted average**
   of its colours.
5. Every pixel is snapped to its **nearest palette colour** by squared RGB
   distance.

The palette is then attached to the `.aseprite` document, so Aseprite shows the
same 26 swatches and the file is effectively an indexed-colour sprite.

> This is classic **colour quantisation** — the same family of algorithm used by
> GIF encoders — not machine learning.

---

## 5. Step 3 — slicing (the part people assume is "AI vision")

**File:** `slice.ps1`

It is **classical computer vision**: thresholding, segmentation, projection
profiles and bounding boxes. No neural network is involved, which is exactly why
the cuts land on exact pixels.

### 5.1 Background detection

Sample every pixel on the 1-pixel border of the image, count exact RGB triples,
take the most frequent one. That is the sheet's background colour.

### 5.2 Foreground mask

A pixel is foreground when its **Manhattan colour distance** from the background
exceeds a tolerance:

```
|ΔR| + |ΔG| + |ΔB| > 28
```

The tolerance absorbs anti-aliasing and near-background shading at the edges.
Result: a boolean bitmap `foreground[x, y]`.

### 5.3 Row projection → bands

For each row, ask "does this row contain any foreground pixel?". Consecutive
`yes` rows form a **band**; a fully empty row ends the band.

This is a **projection profile** — collapsing a 2-D mask onto one axis:

```
row:   0 0 1 1 1 1 0 0 0 1 1 1 1 0
       └─ band 1 ─┘     └─ band 2 ─┘
```

If the AI lays poses out in two rows, this separates them automatically.

### 5.4 Column projection → individual sprites

Inside each band, project onto the X axis and look for runs of **empty columns**.

* An empty run longer than `-Gap` (default **3 px**) ends the current sprite and
  starts a new one.
* An empty run of ≤ 3 px is *tolerated* and does not split — that's how a held
  staff, a gap between an arm and the torso, or a thin tail stays attached to its
  body instead of becoming its own sprite.

### 5.5 Tight bounding boxes

For each detected run, walk the foreground pixels and record
`minX, maxX, minY, maxY`, plus the pixel **area**.

* Boxes smaller than `-MinArea` (default **16 px**) are discarded as noise
  (stray specks, dust, an errant dot).
* The box is the *tight* extent of actual foreground, not the projection span.

### 5.6 Reading order

Sort by `Y`, then `X` → top-left to bottom-right, matching how the prompt lays
out front → three-quarter → side → back.

### 5.7 Uniform cells

Animation needs consistent frames, so every sprite is re-packed onto a shared
cell grid:

```
cellW = widest sprite + 2 × Pad
cellH = tallest sprite + 2 × Pad        (Pad = 1 px)
```

Inside its cell each sprite is:

* **centred horizontally**, and
* **bottom-aligned** on a common baseline.

Bottom alignment is deliberate: feet stay on the ground line, so walking or
idle frames don't bob up and down.

### 5.8 Outputs

| File | What it is |
|---|---|
| `<name>-sheet.png` | one row of uniform cells, transparent background |
| `<name>-sheet.json` | frame rectangles, durations and `frameTags` (TexturePacker/Aseprite JSON) |
| `<name>-sprites.aseprite` | multi-frame document: one frame per sprite, one tag per frame |

`scripts/build_frames.lua` builds the multi-frame file by copying each cell out
of the sheet into a new frame and adding tags — `front`, `three-quarter`, `side`,
`back` when there are exactly 4 sprites, otherwise `view-1 … view-N`.

---

## 6. "Is this computer vision?"

Yes — but the **classical** kind, not the deep-learning kind. The techniques used:

| Term | Where it appears |
|---|---|
| Colour thresholding | foreground mask (`ΔRGB > 28`) |
| Background segmentation | border colour histogram |
| Projection profiles | row/column scans that find bands and gaps |
| Connected regions (by projection) | grouping foreground pixels into sprites |
| Bounding boxes | tight X/Y extents per sprite |
| Colour quantisation | median-cut palette in step 2 |

What is **not** used: object detection models, segmentation networks, OCR, or any
"AI vision" API. That is a feature, not a shortcut — a model returns approximate
boxes, while projection arithmetic returns the exact pixel boundary.

The only learned model in the whole pipeline is Gemini, and it is used for
*drawing*, not for *measuring*.

---

## 7. Step 4 — the local web app

**Files:** `web/server.js`, `web/index.html`, `serve.ps1`

A zero-dependency Node HTTP server (`http`, `fs`, `child_process`), bound to
`127.0.0.1`, so it is reachable only from this machine.

### 7.1 Running a job

`POST /api/run` receives the uploaded image, writes it to `input/`, and starts a
job. Jobs are **serialised** through a promise queue, so two browser tabs cannot
fight over the same output files. The server then spawns the same PowerShell
scripts the CLI uses:

```
generate.ps1  →  run.ps1  →  slice.ps1
```

and streams their stdout into the job log, which the page polls.

| Endpoint | Purpose |
|---|---|
| `POST /api/run` | upload + start a job |
| `GET /api/job?id=` | status, live log, result file list |
| `GET /api/outputs` | everything already in `output/` |
| `GET /api/file?name=` | download (`&dl=1`) or inline PNG/JSON |
| `GET /api/view?name=` | PNG export of an `.aseprite` |
| `GET /api/sprite?name=` | frame rects, durations, tags for the player |
| `POST /api/open?name=` | open the file in the desktop Aseprite |

Security is deliberately simple but not careless: every path is resolved with
`path.basename` inside `output/`, so traversal attempts return 404; uploads are
capped at 25 MB; the socket listens on localhost only.

### 7.2 Viewing `.aseprite` in a browser

Browsers cannot read the format. When you press **View**, the server:

1. runs `aseprite -b file.aseprite --sheet preview.png --data preview.json --format json-hash --sheet-type horizontal`,
2. caches the result in `output/.previews`, keyed by the source file's mtime,
3. serves the PNG plus the frame metadata.

The page then draws each frame onto a `<canvas>` with
`imageSmoothingEnabled = false` and advances frames using the **durations stored
in the file** (100 ms per frame here), with play/pause, frame stepping and 1–8×
zoom. So it is an honest replay of the real file, not a static thumbnail.

**Open in Aseprite** simply launches the desktop binary on the same path.

---

## 8. Failure modes and the knobs that fix them

| Symptom | Cause | Fix |
|---|---|---|
| Background becomes part of the sprite | sheet background isn't flat | make the prompt insist on a plain background |
| Two poses merged into one sprite | they touch, or gap ≤ `-Gap` | ask for more spacing in `prompt.txt`; slicing can't separate touching art |
| Speck becomes a "sprite" | noise above `-MinArea` | raise `-MinArea` |
| Thin prop detached from body | gap > `-Gap` | raise `-Gap` |
| Detail disappears | too aggressive downscale | raise `-Percent`/`-Size` |
| Washed-out colours | too few palette entries | raise `-Colors` (32–48) |
| Frames jitter vertically | source poses at different heights | already mitigated by bottom alignment; adjust the drawing if severe |
| Different result each run | model is stochastic | re-run, or keep the sheet you like and slice it again |

CLI knobs: `-Percent`, `-Size`, `-Colors`, `-Filter`, `-Gap`, `-MinArea`, `-Pad`.

---

## 9. File map

| Path | Role |
|---|---|
| `prompt.txt` | the character-sheet prompt |
| `generate.ps1` | Gemini call → sheet PNG (+ raw `.aseprite`) |
| `run.ps1` | Aseprite batch runner for pixelation |
| `scripts/pixelate.lua` | sampling + median-cut quantisation |
| `slice.ps1` | background mask, projection slicing, uniform sheet |
| `scripts/build_frames.lua` | sheet → multi-frame `.aseprite` with tags |
| `scripts/resolve-aseprite.ps1` | locates the Aseprite binary (env / `.env` / PATH) |
| `pipeline.ps1` | all three steps in one command |
| `web/` | local web app (server + single-page UI) |
| `serve.ps1` | starts the web app and opens the browser |

---

## 10. Glossary

* **Nearest neighbour** — picking the closest source pixel for each destination
  pixel; keeps hard edges.
* **Box average / downsampling** — averaging a block of source pixels; softer.
* **Quantisation** — reducing thousands of colours to a small palette.
* **Median cut** — quantisation by repeatedly splitting the colour space along
  its widest channel.
* **Projection profile** — summing a binary mask along rows or columns to find
  occupied bands and empty gaps.
* **Thresholding / segmentation** — separating foreground from background using
  a rule, here a colour-distance threshold.
* **Bounding box** — the smallest rectangle containing a sprite's pixels.
* **Frame tag** — a named range of frames in Aseprite (`front`, `side`, …).
* **`json-hash`** — Aseprite's JSON export format, keyed by frame name.
