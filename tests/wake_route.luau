--!nocheck
-- Map/WakeRoute: a transport ship's route with its corners rounded (the wake and the ship follow it).
-- Run: .bin/lune run tests/wake_route.luau
local WakeRoute = require("../src/client/Map/WakeRoute")
local SimNav = require("../src/shared/Core/SimNav")

local fails, total = 0, 0
local function expect(cond: any, what: string)
	total += 1
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end
local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-6)
end

local W = 400
local function tile(x: number, y: number): number
	return y * W + x
end
-- a path of straight lines through the given corners (as SimNav rasterises its legs)
local function path_through(points: { { number } }): { number }
	local out = { tile(points[1][1], points[1][2]) }
	for i = 2, #points do
		SimNav.line_tiles(W, out[#out], tile(points[i][1], points[i][2]), out)
	end
	return out
end
-- the sharpest turn between consecutive pieces of a route (radians), and its longest piece
local function shape(r: any): (number, number)
	local worst, longest = 0, 0
	for i = 2, r.n - 1 do
		local ax, ay = r.xs[i] - r.xs[i - 1], r.ys[i] - r.ys[i - 1]
		local bx, by = r.xs[i + 1] - r.xs[i], r.ys[i + 1] - r.ys[i]
		local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
		if la > 1e-9 and lb > 1e-9 then
			worst = math.max(worst, math.acos(math.clamp((ax * bx + ay * by) / (la * lb), -1, 1)))
		end
		longest = math.max(longest, la, lb)
	end
	return worst, longest
end

print("a straight route")
do
	local p = path_through({ { 10, 10 }, { 150, 10 } })
	local r = WakeRoute.build(p, W, 1, nil)
	local turn = shape(r)
	expect(r.n == 2 and turn < 1e-6, "is one leg")
	expect(near(r.xs[1], 10.5) and near(r.ys[1], 10.5) and near(r.xs[r.n], 150.5), "from the first tile's centre to the last's")
	expect(r.ss[1] == 0 and r.ss[r.n] == #p - 1, "ss runs from 0 to the path's last index")
	local x, y = WakeRoute.at(r, 70)
	expect(near(x, 80.5) and near(y, 10.5), "70 tiles along is 70 tiles along")
end

print("a right angle in open water")
do
	local p = path_through({ { 20, 20 }, { 100, 20 }, { 100, 100 } })
	local sharp = WakeRoute.runs(p, W)
	expect(#sharp == 2 and sharp[1][2] == 81 and sharp[2][1] == 81, "two legs that meet at the corner's tile")
	local r = WakeRoute.build(p, W, 1, nil)
	local turn, longest = shape(r)
	expect(turn <= math.rad(12), ("no piece turns more than 12 degrees (%.1f)"):format(math.deg(turn)))
	expect(r.n == 13, ("the corner is ten pieces (%d points)"):format(r.n))
	local mono = true
	for i = 2, r.n do
		if r.ss[i] < r.ss[i - 1] then
			mono = false
		end
	end
	expect(mono, "ss never goes back")
	-- the curve leaves the first leg CORNER tiles before the corner and joins the second as far after
	local first_off, last_off = nil, nil
	for i = 1, r.n do
		if first_off == nil and r.ys[i] > 20.5 + 1e-6 then
			first_off = r.xs[i - 1]
		end
		if r.xs[i] < 100.5 - 1e-6 then
			last_off = r.ys[i + 1]
		end
	end
	expect(near(first_off, 100.5 - WakeRoute.CORNER, 1e-6), "leaves the leg 16 tiles before the corner")
	expect(near(last_off, 20.5 + WakeRoute.CORNER, 1e-6), "joins the next leg 16 tiles after it")
	-- the corner tile itself is no longer on the route: the curve passes inside it
	local x, y = WakeRoute.at(r, 80)
	expect(x < 100.5 - 2 and y > 20.5 + 2, ("at the corner's tick the ship is inside the turn (%.1f, %.1f)"):format(x, y))
	local x0, y0 = WakeRoute.at(r, 80 - WakeRoute.CORNER)
	local x1, y1 = WakeRoute.at(r, 80 + WakeRoute.CORNER)
	expect(
		near(x0, 100.5 - WakeRoute.CORNER, 1e-6) and near(y0, 20.5) and near(x1, 100.5) and near(y1, 20.5 + WakeRoute.CORNER, 1e-6),
		"and where the curve ends it is where the path says, on time"
	)
	expect(select(3, WakeRoute.at(r, 0)) == 1 and select(3, WakeRoute.at(r, 1e9)) == r.n - 1, "at() clamps to the route's ends")
	-- a bigger map scale (k_lin 2): the curve takes half as many tiles
	local r2 = WakeRoute.build(p, W, 2, nil)
	local off2 = nil
	for i = 1, r2.n do
		if off2 == nil and r2.ys[i] > 20.5 + 1e-6 then
			off2 = r2.xs[i - 1]
		end
	end
	expect(near(off2, 100.5 - WakeRoute.CORNER / 2, 1e-6), "CORNER is in full-size tiles (k_lin 2: 8 tiles)")
end

print("a staircase near a coast")
do
	-- two tiles east, one south, over and over (what a path is where no straight line was free),
	-- then a real turn north
	local pts = { { 20, 20 } }
	for i = 1, 20 do
		table.insert(pts, { 20 + i * 2, 20 + i - 1 })
		table.insert(pts, { 20 + i * 2, 20 + i })
	end
	table.insert(pts, { 60, 0 })
	local p = path_through(pts)
	local runs = WakeRoute.runs(p, W)
	expect(#runs == 2, ("the staircase is one leg, the turn another (%d legs)"):format(#runs))
	local r = WakeRoute.build(p, W, 1, nil)
	local turn = shape(r)
	expect(turn <= math.rad(20), ("and the route has no step left in it (sharpest piece %.1f degrees)"):format(math.deg(turn)))
	-- every tile of the path is within TOL of the route's first leg
	local far = 0
	local ax, ay, bx, by = 20.5, 20.5, 60.5, 40.5
	for i = 1, runs[1][2] do
		local px, py = p[i] % W + 0.5 - ax, p[i] // W + 0.5 - ay
		local dx, dy = bx - ax, by - ay
		far = math.max(far, math.abs(px * dy - py * dx) / math.sqrt(dx * dx + dy * dy))
	end
	expect(far <= WakeRoute.TOL, ("no tile of the path is more than 1.5 tiles off its leg (%.2f)"):format(far))
end

print("short legs")
do
	local p = path_through({ { 20, 20 }, { 30, 20 }, { 30, 26 }, { 60, 26 } })
	local r = WakeRoute.build(p, W, 1, nil)
	local mono = true
	for i = 2, r.n do
		if r.ss[i] < r.ss[i - 1] - 1e-9 then
			mono = false
		end
	end
	expect(mono, "two corners on a 6-tile leg share it (each half), ss still ascending")
	local turn = shape(r)
	expect(turn <= math.rad(31), ("both are rounded (sharpest piece %.1f degrees)"):format(math.deg(turn)))
end

print("a corner at a cape")
do
	local p = path_through({ { 20, 20 }, { 100, 20 }, { 100, 100 } })
	local function leaves_at(r: any): number
		for i = 1, r.n do
			if r.ys[i] > 20.5 + 1e-6 then
				return 100.5 - r.xs[i - 1]
			end
		end
		return 0
	end
	-- no water anywhere for a curve: the corner stays as it is
	local r0 = WakeRoute.build(p, W, 1, function()
		return false
	end)
	expect(near(shape(r0), math.pi / 2, 1e-6) and r0.n == 3, "no curve fits: the corner stays sharp")
	-- land fills the inside of the turn right up to the path (x < 100, y > 20): only the smallest
	-- curve passes, a tile's width over the shore at most
	local function water_tight(t: number): boolean
		local x, y = t % W, t // W
		return not (x < 100 and y > 20)
	end
	local r = WakeRoute.build(p, W, 1, water_tight)
	expect(near(leaves_at(r), WakeRoute.CORNER / 4, 1e-6), "land right inside the turn: a quarter-size curve")
	local deep = 0
	for i = 1, r.n do
		local x, y = math.floor(r.xs[i]), math.floor(r.ys[i])
		if not water_tight(y * W + x) and not water_tight(y * W + x + 1) and not water_tight((y - 1) * W + x) then
			deep += 1
		end
	end
	expect(deep == 0, "and no point of it is more than a tile onto the land")
	-- land 2 tiles inside the turn: the full curve (4 tiles inside each way) doesn't fit, the half
	-- one does
	local function water_near(t: number): boolean
		local x, y = t % W, t // W
		return not (x < 98 and y > 22)
	end
	local r3 = WakeRoute.build(p, W, 1, water_near)
	expect(shape(r3) <= math.rad(12), "land a few tiles inside the turn: still a curve")
	expect(near(leaves_at(r3), WakeRoute.CORNER / 2, 1e-6), ("half the size (%.1f tiles before the corner)"):format(leaves_at(r3)))
end

print(("wake_route: %d/%d passed"):format(total - fails, total))
if fails > 0 then
	error(("wake_route: %d failures"):format(fails))
end
