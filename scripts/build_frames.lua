-- build_frames.lua
-- Turn a uniform sprite-sheet PNG (cells laid out in one row) into an
-- editable multi-frame .aseprite, one frame per detected sprite.
--
-- script params:
--   cellW / cellH  size of one cell on the sheet
--   count          number of cells
--   names          optional "front;side;back" tag names
--   out            output .aseprite path

local P = app.params or {}

local sheet = app.activeSprite
if not sheet then error("build_frames.lua: no sheet sprite open") end

local src = sheet.cels[1].image
local cw = tonumber(P.cellW)
local ch = tonumber(P.cellH)
local n = tonumber(P.count)
if not (cw and ch and n) then
  error("build_frames.lua: missing cellW / cellH / count")
end

local out = Sprite(cw, ch)
local layer = out.layers[1]

for i = 1, n do
  if i > 1 then out:newEmptyFrame(i) end
  local img = Image(src, Rectangle((i - 1) * cw, 0, cw, ch))
  local ok, err = pcall(function()
    out:newCel(layer, i, img, Point(0, 0))
  end)
  if not ok then error("build_frames.lua: newCel failed at frame " .. i .. ": " .. tostring(err)) end
end

-- one tag per view, so the frames are named in the timeline
if P.names and P.names ~= "" then
  local idx = 1
  for name in string.gmatch(P.names, "([^;]+)") do
    if idx > n then break end
    local ok = pcall(function()
      local tag = out:newTag(idx, idx)
      tag.name = name
    end)
    idx = idx + 1
  end
end

if P.out then out:saveAs(P.out) end
print(("built %d frames of %dx%d"):format(n, cw, ch))
