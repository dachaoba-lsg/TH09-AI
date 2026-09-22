-- Independent test double for ka_ai_duka v1.7 inject/hitTest.cpp.
-- Rect dimensions are full sizes. A laser starts at (x,y), extends width
-- along its angle, and spans +/- height/2 across that line. The upstream
-- function intentionally has no circle/rect mixed-pair implementation.
return function(a, b)
  if a.type == HitType.Rect and b.type == HitType.Rect then
    return math.abs(a.x - b.x) <= (a.width + b.width) * 0.5
      and math.abs(a.y - b.y) <= (a.height + b.height) * 0.5
  end
  if a.type == HitType.Circle and b.type == HitType.Circle then
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy <= (a.radius + b.radius)^2
  end
  if a.type == HitType.RotatableRect then a, b = b, a end
  if a.type == HitType.Rect and b.type == HitType.RotatableRect then
    local dx, dy = a.x - b.x, a.y - b.y
    local c, s = math.cos(b.angle), math.sin(b.angle)
    local x, y = c * dx + s * dy, -s * dx + c * dy
    return x >= -a.width * 0.5 and x <= b.width + a.width * 0.5
      and math.abs(y) <= (a.height + b.height) * 0.5
  end
  return false
end
