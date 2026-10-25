--!native
-- A transport ship's route as a smooth line (UnitLayer draws the ship and its wake along it).
--
-- The Sim's water paths are string-pulled (SimNav._smooth): long straight legs that meet at sharp
-- corners in open water, and near a coast, where no straight line is free, a staircase of two-tile
-- steps. Drawn as they are, a wake was a few straight bars and some jitter (2026-10-07: boat
-- trails looked like straight lines; they should curve smoothly). Here:
--   1. the path is cut into straight legs that stay within TOL tiles of its tiles (a staircase is
--      one leg; measured on 200 World routes, 8 of 10 legs were under 8 tiles before);
--   2. every corner is rounded: the route leaves a leg up to CORNER full-size tiles before the corner
--      (never more than half the leg) and joins the next one as far after it, along a quadratic
--      Bezier whose control point is the corner, cut into short straight pieces (one per ARC_STEP
--      of turn).
--   * The curve passes inside the corner. Where that would put it on land (a corner at a cape; a
--     tile's width of shore is let pass, as a leg may) it is tried at half and at a quarter the
--     size, and the corner stays sharp if none fits.
--   * Each point carries how many path tiles along the route it is (`ss`), so the ship is placed by
--     the Sim's own timing (tiles sailed) and reaches both ends of every curve when it would have
--     reached them on the legs.
--
-- Pure Luau (no Roblox types): tests/wake_route.luau.

local WakeRoute = {}

--- A straight leg may stray this far (tiles) from the path's tiles.
WakeRoute.TOL = 1.5
--- Full-size tiles of each leg a corner's curve may take (a ship is drawn 13 wide).
WakeRoute.CORNER = 16.0
--- Legs that turn less than this meet as they are.
WakeRoute.MIN_TURN = math.rad(2.0)
--- One straight piece per this much turn, at least ARC_MIN and at most ARC_MAX a corner.
WakeRoute.ARC_STEP = math.rad(9.0)
WakeRoute.ARC_MIN = 3
WakeRoute.ARC_MAX = 12
--- The smallest curve worth drawing (tiles of leg).
WakeRoute.MIN_CUT = 1.0

export type Route = { xs: { number }, ys: { number }, ss: { number }, n: number }

--- A path as straight runs: path index pairs {a, b} (consecutive, a < b), each staying within TOL
--- tiles of every tile it passes. A run ends where the path is farthest from the straight line
--- (Ramer-Douglas-Peucker), so a corner of the path is a corner of the runs.
function WakeRoute.runs(path: { number }, W: number): { { number } }
	local n = #path
	if n < 2 then
		return {}
	end
	local tol2 = WakeRoute.TOL * WakeRoute.TOL
	-- keep[i]: path index i ends a run. Spans still to split wait on a stack (a, b pairs).
	local keep = table.create(n, false)
	keep[1], keep[n] = true, true
	local stack = { 1, n }
	local top = 2
	while top > 0 do
		local b, a = stack[top], stack[top - 1]
		top -= 2
		if b - a < 2 then
			continue
		end
		local ax, ay = path[a] % W, path[a] // W
		local dx, dy = path[b] % W - ax, path[b] // W - ay
		local len2 = dx * dx + dy * dy
		local worst, at = tol2, -1
		for m = a + 1, b - 1 do
			local px, py = path[m] % W - ax, path[m] // W - ay
			-- squared distance to the segment a-b
			local t = if len2 > 0 then math.clamp((px * dx + py * dy) / len2, 0, 1) else 0
			local ex, ey = px - dx * t, py - dy * t
			local d2 = ex * ex + ey * ey
			if d2 > worst then
				worst, at = d2, m
			end
		end
		if at > 0 then
			keep[at] = true
			stack[top + 1], stack[top + 2], stack[top + 3], stack[top + 4] = a, at, at, b
			top += 4
		end
	end
	local runs = {}
	local from = 1
	for i = 2, n do
		if keep[i] then
			table.insert(runs, { from, i })
			from = i
		end
	end
	return runs
end

--- The route of `path` (1-based tiles on a grid `W` wide; `k` = the map's k_lin, full-size tiles per
--- tile). `is_water(tile)`: nil skips the land check. Points are tile centres (x + 0.5, y + 0.5).
function WakeRoute.build(path: { number }, W: number, k: number, is_water: ((number) -> boolean)?): Route
	local np = #path
	if np == 0 then
		return { xs = {}, ys = {}, ss = {}, n = 0 }
	end
	if np == 1 then
		return { xs = { path[1] % W + 0.5 }, ys = { path[1] // W + 0.5 }, ss = { 0 }, n = 1 }
	end
	local runs = WakeRoute.runs(path, W)
	local m = #runs
	-- the legs' ends
	local vx, vy, vs = table.create(m + 1), table.create(m + 1), table.create(m + 1)
	for i, run in runs do
		local t = path[run[1]]
		vx[i], vy[i], vs[i] = t % W + 0.5, t // W + 0.5, run[1] - 1
	end
	local last = path[runs[m][2]]
	vx[m + 1], vy[m + 1], vs[m + 1] = last % W + 0.5, last // W + 0.5, runs[m][2] - 1

	local xs, ys, ss = { vx[1] }, { vy[1] }, { vs[1] }
	local n = 1
	local corner = WakeRoute.CORNER / math.max(k, 1e-6)
	for i = 2, m do
		local cx, cy = vx[i], vy[i]
		local ax, ay = cx - vx[i - 1], cy - vy[i - 1]
		local bx, by = vx[i + 1] - cx, vy[i + 1] - cy
		local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
		local rounded = false
		if la > 0 and lb > 0 then
			local turn = math.acos(math.clamp((ax * bx + ay * by) / (la * lb), -1, 1))
			if turn >= WakeRoute.MIN_TURN then
				local steps = math.clamp(math.ceil(turn / WakeRoute.ARC_STEP), WakeRoute.ARC_MIN, WakeRoute.ARC_MAX)
				local d = math.min(corner, la * 0.5, lb * 0.5)
				for _ = 1, 3 do
					if d < WakeRoute.MIN_CUT then
						break
					end
					local x0, y0 = cx - ax / la * d, cy - ay / la * d
					local x1, y1 = cx + bx / lb * d, cy + by / lb * d
					local ok = true
					if is_water ~= nil then
						for j = 1, steps - 1 do
							local t = j / steps
							local u = 1 - t
							local px = math.floor(u * u * x0 + 2 * u * t * cx + t * t * x1)
							local py = math.floor(u * u * y0 + 2 * u * t * cy + t * t * y1)
							-- on water, or on the shore beside it
							if
								not (
									is_water(py * W + px)
									or (px > 0 and is_water(py * W + px - 1))
									or (px < W - 1 and is_water(py * W + px + 1))
									or is_water((py - 1) * W + px)
									or is_water((py + 1) * W + px)
								)
							then
								ok = false
								break
							end
						end
					end
					if ok then
						local s0 = vs[i] - d * (vs[i] - vs[i - 1]) / la
						local s1 = vs[i] + d * (vs[i + 1] - vs[i]) / lb
						for j = 0, steps do
							local t = j / steps
							local u = 1 - t
							n += 1
							xs[n] = u * u * x0 + 2 * u * t * cx + t * t * x1
							ys[n] = u * u * y0 + 2 * u * t * cy + t * t * y1
							ss[n] = s0 + (s1 - s0) * t
						end
						rounded = true
						break
					end
					d *= 0.5
				end
			end
		end
		if not rounded then
			n += 1
			xs[n], ys[n], ss[n] = cx, cy, vs[i]
		end
	end
	n += 1
	xs[n], ys[n], ss[n] = vx[m + 1], vy[m + 1], vs[m + 1]
	return { xs = xs, ys = ys, ss = ss, n = n }
end

--- Where a ship `done` path tiles along the route is: its position and the index of the last
--- route point at or before it (1 .. n - 1; the wake is the points up to it, then the ship).
function WakeRoute.at(route: Route, done: number): (number, number, number)
	local n = route.n
	local xs, ys, ss = route.xs, route.ys, route.ss
	if n == 0 then
		return 0.5, 0.5, 0
	end
	if n == 1 or done <= ss[1] then
		return xs[1], ys[1], 1
	end
	if done >= ss[n] then
		return xs[n], ys[n], n - 1
	end
	-- the last point with ss <= done
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if ss[mid] <= done then
			lo = mid
		else
			hi = mid
		end
	end
	local span = ss[lo + 1] - ss[lo]
	local f = if span > 0 then (done - ss[lo]) / span else 0
	return xs[lo] + (xs[lo + 1] - xs[lo]) * f, ys[lo] + (ys[lo + 1] - ys[lo]) * f, lo
end

return WakeRoute
