local M = {}

function M.normalize(angle)
  return angle - 2 * math.pi * math.floor(angle / (2 * math.pi))
end

function M.lerp(a, b, t)
  local diff = b - a
  diff = diff - 2 * math.pi * math.floor((diff + math.pi) / (2 * math.pi))
  return a + diff * math.min(t, 1)
end

return M
