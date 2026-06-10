local dim = {}

---Draw a dithered scanline overlay over the full screen to darken it.
---@param width number game render width
---@param height number game render height
---@param step number? pixels between lines (default 2 = 50% coverage)
---@param color number? palette color (default gfx.COLOR_BLACK)
function dim.draw(width, height, step, color)
  step = step or 2
  color = color or gfx.COLOR_BLACK
  for y = 0, height - 1, step do
    gfx.line(0, y, width - 1, y, color)
  end
end

return dim
