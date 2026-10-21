-- pixelate.lua
-- Downscale the active sprite onto a small pixel grid (nearest-neighbour)
-- and limit its palette to a fixed number of colors (median cut).
--
-- script params (passed with --script-param):
--   input    source image path (fallback if no sprite is open)
--   percent  downscale to this % of the source size (overrides size)
--   size     max width/height of the result in px   (default 32)
--   colors   max number of colors in the palette    (default 26)
--   filter   "nearest" (default) or "average"
--   outAse   where to save the editable .aseprite
--   outPng   where to save the preview .png

local P = app.params or {}

local function numParam(name, default)
  local v = tonumber(P[name])
  if v == nil then return default end
  return v
end

local percent = tonumber(P.percent)
local size = numParam("size", 32)
local maxColors = numParam("colors", 26)
local filter = P.filter or "nearest"

assert(size > 0, "size must be > 0")
if percent then assert(percent > 0, "percent must be > 0") end
assert(maxColors >= 1, "colors must be >= 1")

-- ---------------------------------------------------------------- open
local spr = app.activeSprite
if not spr and P.input then
  spr = Sprite{ fromFile = P.input }
end
assert(spr, "no sprite: pass the image as a CLI file or via --script-param input=")

if spr.colorMode ~= ColorMode.RGB then
  spr:convertToColorMode(ColorMode.RGB)
end

local cel = spr.layers[1]:cel(1)
assert(cel and cel.image, "frame 1 of the first layer is empty")

local src = cel.image
local ox, oy = cel.position.x, cel.position.y
local sw, sh = spr.width, spr.height

-- ----------------------------------------------------------- grid size
-- percent mode: exactly N% of the source size (e.g. 30 -> 1024x1024
-- becomes 307x307). size mode: fit inside size x size, keep aspect
-- ratio, never upscale.
local dw, dh
local mode
if percent then
  dw = math.max(1, math.floor(sw * percent / 100 + 0.5))
  dh = math.max(1, math.floor(sh * percent / 100 + 0.5))
  mode = ("%d%% of source"):format(percent)
else
  local scale = math.min(size / sw, size / sh)
  if scale > 1 then scale = 1 end
  dw = math.max(1, math.floor(sw * scale + 0.5))
  dh = math.max(1, math.floor(sh * scale + 0.5))
  mode = ("fit in %dpx"):format(size)
end

-- ----------------------------------------------------------- sampling
-- returns r,g,b,a in sprite coordinates, or nil outside the cel
local function srcPixel(x, y)
  local px, py = x - ox, y - oy
  if px < 0 or py < 0 or px >= src.width or py >= src.height then
    return nil
  end
  local v = src:getPixel(px, py)
  return app.pixelColor.rgbaR(v), app.pixelColor.rgbaG(v),
         app.pixelColor.rgbaB(v), app.pixelColor.rgbaA(v)
end

local total = dw * dh
local dst = {}        -- {r,g,b} per pixel, false = transparent
local colorCount = {} -- packed rgb -> pixel count
local unique = 0

local function put(i, r, g, b)
  dst[i] = { r, g, b }
  local key = r * 65536 + g * 256 + b
  if not colorCount[key] then
    colorCount[key] = 1
    unique = unique + 1
  else
    colorCount[key] = colorCount[key] + 1
  end
end

if filter == "average" then
  -- box average (softer, good when the source pixel grid is not aligned)
  for dy = 0, dh - 1 do
    local y0 = math.floor(dy * sh / dh)
    local y1 = math.max(y0 + 1, math.floor((dy + 1) * sh / dh))
    for dx = 0, dw - 1 do
      local x0 = math.floor(dx * sw / dw)
      local x1 = math.max(x0 + 1, math.floor((dx + 1) * sw / dw))
      local rs, gs, bs, as, n = 0, 0, 0, 0, 0
      for y = y0, y1 - 1 do
        for x = x0, x1 - 1 do
          local r, g, b, a = srcPixel(x, y)
          if r and a > 0 then
            rs = rs + r * a
            gs = gs + g * a
            bs = bs + b * a
            as = as + a
            n = n + 1
          end
        end
      end
      local i = dy * dw + dx + 1
      if n > 0 and as / n >= 128 and as > 0 then
        put(i, math.floor(rs / as + 0.5),
                math.floor(gs / as + 0.5),
                math.floor(bs / as + 0.5))
      else
        dst[i] = false
      end
    end
  end
else
  -- nearest neighbour (hard pixel grid, as requested)
  for dy = 0, dh - 1 do
    local y = math.floor((dy + 0.5) * sh / dh)
    for dx = 0, dw - 1 do
      local x = math.floor((dx + 0.5) * sw / dw)
      local i = dy * dw + dx + 1
      local r, g, b, a = srcPixel(x, y)
      if r and a >= 128 then
        put(i, r, g, b)
      else
        dst[i] = false
      end
    end
  end
end

-- ------------------------------------------------------- quantize
local palette = {}

if unique <= maxColors then
  for key in pairs(colorCount) do
    palette[#palette + 1] = {
      math.floor(key / 65536),
      math.floor(key / 256) % 256,
      key % 256,
    }
  end
else
  -- median cut: build the list of unique colors, then keep splitting the
  -- box with the widest channel range until we have maxColors boxes
  local entries = {}
  for key, n in pairs(colorCount) do
    entries[#entries + 1] = {
      r = math.floor(key / 65536),
      g = math.floor(key / 256) % 256,
      b = key % 256,
      n = n,
    }
  end

  local function widestChannel(box)
    local minR, maxR, minG, maxG, minB, maxB = 255, 0, 255, 0, 255, 0
    for _, e in ipairs(box) do
      if e.r < minR then minR = e.r end
      if e.r > maxR then maxR = e.r end
      if e.g < minG then minG = e.g end
      if e.g > maxG then maxG = e.g end
      if e.b < minB then minB = e.b end
      if e.b > maxB then maxB = e.b end
    end
    local best, width = "r", maxR - minR
    if maxG - minG > width then best, width = "g", maxG - minG end
    if maxB - minB > width then best, width = "b", maxB - minB end
    return best, width
  end

  local boxes = { entries }
  while #boxes < maxColors do
    local target, targetWidth = nil, -1
    for _, box in ipairs(boxes) do
      if #box > 1 then
        local _, w = widestChannel(box)
        if w > targetWidth then target, targetWidth = box, w end
      end
    end
    if not target then break end -- every box is a single color

    local ch = widestChannel(target)
    table.sort(target, function(a, b) return a[ch] < b[ch] end)
    local mid = math.floor(#target / 2)
    if mid < 1 then break end
    local left, right = {}, {}
    for i = 1, #target do
      if i <= mid then left[#left + 1] = target[i]
      else right[#right + 1] = target[i] end
    end
    for i, b in ipairs(boxes) do
      if b == target then boxes[i] = left break end
    end
    boxes[#boxes + 1] = right
  end

  for _, box in ipairs(boxes) do
    local rs, gs, bs, ns = 0, 0, 0, 0
    for _, e in ipairs(box) do
      rs = rs + e.r * e.n
      gs = gs + e.g * e.n
      bs = bs + e.b * e.n
      ns = ns + e.n
    end
    palette[#palette + 1] = {
      math.floor(rs / ns + 0.5),
      math.floor(gs / ns + 0.5),
      math.floor(bs / ns + 0.5),
    }
  end
end

if #palette == 0 then
  palette[1] = { 0, 0, 0 }
end

-- snap every pixel to its nearest palette color
for i = 1, total do
  local p = dst[i]
  if p then
    local br, bg, bb, bd = p[1], p[2], p[3], math.huge
    for _, c in ipairs(palette) do
      local dr, dg, db = p[1] - c[1], p[2] - c[2], p[3] - c[3]
      local d = dr * dr + dg * dg + db * db
      if d < bd then bd, br, bg, bb = d, c[1], c[2], c[3] end
    end
    dst[i] = { br, bg, bb }
  end
end

-- ----------------------------------------------------------- output
local out = Sprite(dw, dh)
local img = Image(out)
img:clear()
for i = 1, total do
  local p = dst[i]
  if p then
    local x = (i - 1) % dw
    local y = math.floor((i - 1) / dw)
    img:drawPixel(x, y, app.pixelColor.rgba(p[1], p[2], p[3], 255))
  end
end
out.layers[1]:cel(1).image = img

local pal = Palette(#palette)
for i, c in ipairs(palette) do
  pal:setColor(i - 1, app.pixelColor.rgba(c[1], c[2], c[3], 255))
end
out:setPalette(pal)

if P.outAse then out:saveAs(P.outAse) end
if P.outPng then out:saveAs(P.outPng) end

print(("source : %dx%d, %d unique colors"):format(sw, sh, unique))
print(("output : %dx%d, %d colors (mode=%s, filter=%s)"):format(dw, dh, #palette, mode, filter))
print("saved  : " .. tostring(P.outAse) .. " / " .. tostring(P.outPng))
