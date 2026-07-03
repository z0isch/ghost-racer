local dim = {}

function dim.draw(width, height, color)
  gfx.rect_fill(0, 0, width, height, color or gfx.COLOR_BLACK, .3)
end

return dim
