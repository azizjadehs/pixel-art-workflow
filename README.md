# Pixel Art Character Workflow

Turn a piece of your art into a small, editable 2D pixel art character.

## Setup (one time)

Put your Gemini API key in this folder, in `.env` or `.env.txt`:

```
GEMINI_API_KEY=...
```

Get a free key at https://aistudio.google.com/apikey (the free tier
covers image generation, unlike OpenAI's image API).
Both files are gitignored - don't commit the key, don't paste it in chat.

Point the scripts at your Aseprite binary in the same file:

```
ASEPRITE_EXE=C:\path\to\aseprite.exe
```

The scripts also accept the `ASEPRITE_EXE` environment variable, an
`aseprite` on `PATH`, or the default Windows install location. Nothing
is hardcoded, so the repo stays free of machine-specific paths.

## Web app (local)

```powershell
.\serve.ps1
```

Opens `http://127.0.0.1:7788/`. Drop an image, pick the settings, hit
**Run pipeline**. The page shows the live log, previews, Download buttons
for every file, and **Open in Aseprite** (works because the server runs on
your machine).

- `-Port 8080` to use another port
- no `npm install` - the server uses only Node's built-in modules
- binds to `127.0.0.1` only, so it is not reachable from other machines
- needs Node.js and the local Aseprite build
- **View** any `.aseprite` in the browser: the server exports the frames
  with the local Aseprite CLI and an in-page canvas player replays them at
  the file's real frame durations (play/pause, step, zoom). Browsers cannot
  read the `.aseprite` format directly, so Aseprite's own exporter is used.
- the **Saved outputs** gallery lists everything already in `output\`, so
  old runs can be viewed, downloaded or opened without re-running the
  pipeline

Stop it with `Ctrl+C` in the terminal window.

## The whole thing in one go

Drop your art image into `input/`, then:

```powershell
.\pipeline.ps1
```

That runs both steps (Gemini -> Aseprite), auto-picks the newest image in
`input/`, and prints where everything landed. Useful variants:

```powershell
.\pipeline.ps1 input\my-art.png   # name the art explicitly
.\pipeline.ps1 -Open              # also opens the result in Aseprite
.\pipeline.ps1 -Percent 30        # scale to 30% of the source, instead of 32px
.\pipeline.ps1 -Size 48 -Colors 32 -Filter average   # tweak the grid
```

The step-by-step commands below are the same pipeline, just run separately.

## Step 1 - generate with the Gemini image API

```powershell
.\generate.ps1 input\your-art.png
```

Sends your art + `prompt.txt` to `gemini-2.5-flash-image` and saves
**both formats** to `input/`: `your-art-generated.png` (raw image) and
`your-art-generated.aseprite` (same image as an editable Aseprite file).

- `-PromptFile` - different prompt (default `prompt.txt`)
- `-Model` - different Gemini image model (default `gemini-2.5-flash-image`)
- `-Chain` - run the pixelation step automatically on the result

No API key / want to do it by hand? Open ChatGPT yourself, paste
`prompt.txt` with your art, and save the image into `input/`.

## Step 2 - pixelate with Aseprite

```powershell
.\run.ps1 input\your-image.png
```

Options (defaults shown):

```powershell
.\run.ps1 input\your-image.png -Size 32 -Colors 26 -Filter nearest
```

- `-Percent` - downscale to this % of the source size (e.g. 30).
  Overrides `-Size`. 30% of 1024px = 307px, so this is the knob to use
  when a fixed 32px grid is too small.
- `-Size` - max width/height of the grid in px, aspect ratio kept (32)
- `-Colors` — hard palette cap via median-cut quantization (26)
- `-Filter` — `nearest` (hard pixel grid) or `average` (softer downscale)

Results land in `output/`:
- `name.aseprite` — editable document (open this in Aseprite)
- `name.png` — flat preview of the same result

## Step 3 — Clean up in Aseprite

Open `output\name.aseprite`, fix artifacts, refine the palette, draw the
animation frames.

## Step 3 - slice the character sheet into sprites

`pipeline.ps1` does this automatically as step 3. To run it alone:

```powershell
.\slice.ps1 output\my-art-generated.png
```

It detects each sprite on the sheet by background-colour segmentation
and row/column projection, then writes:

- `output\<name>-generated-sheet.png` - uniform cells, transparent
  background, sprites bottom-aligned on a shared baseline
- `output\<name>-generated-sheet.json` - Aseprite JSON with frame rects
  and tags (`front`, `three-quarter`, `side`, `back`)
- `output\<name>-generated-sprites.aseprite` - multi-frame file, one
  frame per view, tags in the timeline

Use the sheet PNG + JSON with Aseprite's *File > Import > Import Sprite
Sheet* if you prefer to import manually.

Why not a vision model for the boxes: a vision model returns approximate
coordinates (often 10-30px off), which breaks pixel alignment. This
sheet has a flat background, so segmentation gives exact pixel bounds.
The only thing a vision model would add is naming the views - the frames
are named in reading order instead.

## How it works

`generate.ps1` (step 1) posts your art + `prompt.txt` to Gemini's
`generateContent` endpoint via .NET `HttpClient` (no Python or extra
modules needed) and decodes the returned image from base64 -> PNG.

`run.ps1` (step 2) calls the local Aseprite build in batch mode and runs
`scripts/pixelate.lua`, which:

1. downscales the image onto the target grid (nearest-neighbour by default),
2. counts unique colors after downscaling,
3. if over the limit, quantizes with median cut and snaps every pixel to the
   reduced palette,
4. writes an `.aseprite` with the palette attached, plus a PNG preview.

`slice.ps1` (step 3) finds the background colour, builds a foreground
mask, splits it into rows and columns by projection, and packs the tight
bounding boxes into uniform cells. `scripts/build_frames.lua` then builds
the multi-frame `.aseprite`.

The CLI usage follows the usual Aseprite batch rules (full binary path,
`cmd` output redirection, `--script-param` before `--script`).
