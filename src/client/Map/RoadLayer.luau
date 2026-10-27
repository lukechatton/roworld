--!native
-- Railroads on the 2D map: every railroad follows its tile path
-- (GameState.roads: rid -> {a, b, tiles}) and fades in over FADE_RANGE up to zoom MIN_ZOOM.
-- Zoomed out it is a line a full-size tile wide along the path's centre (THICKNESS 1: the path's straight
-- runs, pooled GUI bars); zoomed in, a detailed track (from DETAIL_ZOOM): each tile a
-- 3 x 3 grid, two rails along its sides and a tie between them, a turn's tile its own piece (the two
-- sides it joins, rail_kinds). The track is a tiled image (assets/rails, RailArt)
-- along each straight stretch and one per turn.
-- Coloured by the land under them: grey on unclaimed land, a light rail on the
-- local player's land (dark over light territory) and the owner's border colour elsewhere; runs are
-- cut every RUN_MAX tiles so the colour follows the borders they cross. Redrawn when the camera or
-- the network changes, and now and then for the colours.
--
-- (2026-10-12: in the trailer's rail shot the train tracks looked poor; they
-- were bars 0.4 of a tile wide, 2 px at a continent's zoom, and never the track.)
-- (2026-10-27, "Script - Roads" was phones' second slow-frame cause: a pan moved every rail on the
-- screen, one Position each, and a rail coming on or going off the screen handed every rail after it
-- in the pool another run: six writes each. Now the rails sit in a frame placed at the map's origin
-- (`_pan`), each where it is at this zoom, so a pan writes the frame alone; until the view has moved
-- PAN_SLACK px no rail is even looked at (the rails that far off the screen are kept). A run or piece
-- keeps its GUI object while it is drawn.)
local RS = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Airfront = RS:WaitForChild("Airfront")
local Rules = require(Airfront:WaitForChild("Core"):WaitForChild("Rules")) :: any
local RailArt = require(Airfront:WaitForChild("Assets"):WaitForChild("RailArt")) :: any
local MapSurface = require(script.Parent:WaitForChild("MapSurface")) :: any

local RoadLayer = {}
RoadLayer.__index = RoadLayer

--- Rail zoom levels: device px per full-size tile (the GUI scale x
--- the device ratio, capped at 2). Rails are drawn from MIN_ZOOM - FADE_RANGE (invisible)
--- to MIN_ZOOM (opaque), a line THICKNESS full-size tiles wide, and the detailed track from
--- DETAIL_ZOOM on.
RoadLayer.MIN_ZOOM = 3.0
RoadLayer.FADE_RANGE = 2.0
RoadLayer.DETAIL_ZOOM = 6.0
RoadLayer.THICKNESS = 1.0
--- Device px per GUI px: Roblox's GUI px are points on a
--- phone or tablet, pixels on a desktop at 100%, and nothing tells the real ratio, so 2 on a touch
--- screen (every phone's is 2 or more, capped at 2) and 1 on a desktop. (It used to be 2
--- everywhere, and faded the rails in from MIN_ZOOM to MIN_ZOOM + FADE_RANGE, not up to MIN_ZOOM;
--- 2026-10-13: always seeing these railroads when zoomed out may have made the game worse, so
--- zoomed out they now fade away.)
--- (read when drawn: at the client's start the keyboard may not be known yet; nil = by the device)
RoadLayer.DEVICE_RATIO = nil :: number?
function RoadLayer.device_ratio(): number
	return RoadLayer.DEVICE_RATIO
		or if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then 2.0 else 1.0
end
RoadLayer.RUN_MAX = 12 -- tiles per bar at most
--- A line thinner than a device pixel is drawn one device pixel wide and as transparent as it is
--- thinner (the coverage of an anti-aliased line).
RoadLayer.RECOLOR_S = 0.5
RoadLayer.UNOWNED = Color3.new(0.75, 0.75, 0.75)
--- The local player's rails: LIGHT, or DARK when the
--- player's territory colour is brighter than LIGHT_ABOVE (perceived brightness). Others' are their
--- border colour (the palette's border row: HSL lightness - BORDER_DARKEN, as MapSurface's borders).
RoadLayer.LIGHT = Color3.fromRGB(0xE6, 0xE6, 0xE6)
RoadLayer.DARK = Color3.new(0, 0, 0)
RoadLayer.LIGHT_ABOVE = 0.8
RoadLayer.BORDER_DARKEN = 0.125
RoadLayer.Z = 6
--- Hidden bars kept for reuse.
RoadLayer.POOL_SPARE = 64
--- A pan this far (px) from where the rails were last laid out moves their frame and nothing else:
--- the rails within PAN_SLACK of the screen's edges are drawn (not while zooming).
RoadLayer.PAN_SLACK = 64

--- A tile's rail kind, an index into KIND_ART
local H, V, TL, TR, BL, BR = 1, 2, 3, 4, 5, 6
local KIND_ART = { "h", "v", "tl", "tr", "bl", "br" }

type Run = {
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	mid: number,
	mu: number?,
	mv: number?,
	lm: number?,
	rot: number?,
	col: Color3?,
	slot: number?,
}

--- A piece of the detailed track: the tiles x0..x1 x y0..y1 (one tile, or a straight stretch of one
--- kind), their kind (H .. BR), a tile for the colour (mid) and the centre in map units (mu, mv).
type Piece = {
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	kind: number,
	mid: number,
	mu: number,
	mv: number,
	col: Color3?,
	slot: number?,
}

--- A pool of GUI objects: what each was last given (written again only when it changes: a pan moves
--- them and nothing else, a zoom sizes them; on a phone a late game's camera move rewrote six
--- properties of every rail on screen each frame, 2026-10-12): its run or piece (and so its rotation
--- or image), colour, transparency, size, and position (2026-10-26: the recolouring every RECOLOR_S
--- moved every rail on screen to where it already was). A slot keeps its run or piece while that is
--- drawn (item.slot; 2026-10-27): `seen` the pass that last drew it, `free` the hidden slots, `holes`
--- the slots whose object went, `top` the highest slot.
local function new_pool()
	return {
		items = {},
		run = {},
		col = {},
		a = {},
		w = {},
		h = {},
		x = {},
		y = {},
		seen = {},
		free = {},
		holes = {},
		top = 0,
	}
end

function RoadLayer.new(parent: Instance, view: any)
	local self = setmetatable({}, RoadLayer) :: any
	local root = Instance.new("Frame")
	root.Name = "Roads"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = RoadLayer.Z
	root.Parent = parent
	self.root = root
	--- the rails' frame: at the map's origin on the screen (whole px), the rails in it where they are
	--- at this zoom
	local pan = Instance.new("Frame")
	pan.Name = "Pan"
	pan.BackgroundTransparency = 1
	pan.BorderSizePixel = 0
	pan.Size = UDim2.fromOffset(0, 0)
	pan.ZIndex = RoadLayer.Z
	pan.Parent = root
	self._pan = pan
	self._px, self._py = 0, 0
	self.view = view
	self._state = nil :: any
	--- the lines (Frames) and the detailed track (ImageLabels)
	self._bars = new_pool()
	self._track = new_pool()
	--- rid -> the railroad's runs / track pieces (built once per railroad, when first drawn)
	self._runs = {} :: { [number]: { Run } }
	self._pieces = {} :: { [number]: { Piece } }
	self._dirty = true
	self._cam_version = -1
	self._recolor = 0.0
	--- the rails' last layout: its pass, zoom, viewport, the map's origin on the screen and how far
	--- past the screen's edges it drew (PAN_SLACK, or 0 while zooming)
	self._pass = 0
	self._lay_s, self._lay_vp = -1.0, nil :: Vector2?
	self._lay_x, self._lay_y, self._lay_slack = 0.0, 0.0, 0.0
	--- runs and pieces the last layout drew
	self._drawn = 0
	--- owner -> rail colour, for one pass (see colour())
	self._border = {} :: { [number]: Color3 }
	return self
end

function RoadLayer.bind(self: any, state: any)
	self._state = state
	table.clear(self._runs)
	table.clear(self._pieces)
	self._dirty = true
end

--- After a pass: the slots it did not draw (seen ~= pass) are hidden and free; the spares past
--- POOL_SPARE go (a map zoomed out shows no rails, yet a late game's 1,300 bars were laid out again
--- with the plates on every camera move).
local function sweep(pool: any, pass: number)
	local run, seen, free = pool.run, pool.seen, pool.free
	for j = 1, pool.top do
		-- (an object is shown exactly while it has a run: no need to ask Roblox)
		if run[j] ~= nil and seen[j] ~= pass then
			run[j] = nil
			pool.items[j].Visible = false
			table.insert(free, j)
		end
	end
	while #free > RoadLayer.POOL_SPARE do
		local j = table.remove(free) :: number
		pool.items[j]:Destroy()
		pool.items[j] = nil
		pool.col[j], pool.a[j], pool.w[j], pool.h[j] = nil, nil, nil, nil
		pool.x[j], pool.y[j], pool.seen[j] = nil, nil, nil
		table.insert(pool.holes, j)
	end
end

--- The slot of `pool` drawing `item` (a run or piece) this pass: its own while it stays drawn, else
--- a free one, else a new slot (`items[j]` nil: the caller makes its object). `fresh`: the slot's
--- object shows something else (or nothing) until this item is written into it.
local function acquire(pool: any, item: any, pass: number): (number, boolean)
	local j = item.slot
	local fresh = j == nil or pool.run[j] ~= item
	if fresh then
		j = table.remove(pool.free)
		if j == nil then
			j = table.remove(pool.holes)
			if j == nil then
				pool.top += 1
				j = pool.top
			end
		end
		item.slot = j
		pool.run[j] = item
		pool.col[j] = nil
		pool.a[j] = -1
		pool.w[j] = -1
		pool.x[j] = nil
	end
	pool.seen[j] = pass
	return j :: number, fresh
end

function RoadLayer.unbind(self: any)
	self._state = nil
	table.clear(self._runs)
	table.clear(self._pieces)
	for _, pool in { self._bars, self._track } do
		sweep(pool, -1)
	end
end

--- The rails' frame at the map's origin on the screen, in whole px (written when that moved).
function RoadLayer._place(self: any, ox: number, oy: number)
	local x, y = math.round(ox), math.round(oy)
	if x ~= self._px or y ~= self._py then
		self._px, self._py = x, y
		self._pan.Position = UDim2.fromOffset(x, y)
	end
end

function RoadLayer.destroy(self: any)
	self:unbind()
	self.root:Destroy()
end

function RoadLayer.mark_road_dirty(self: any, rid: number?)
	if rid ~= nil then
		self._runs[rid] = nil
		self._pieces[rid] = nil
	end
	self._dirty = true
end

--- A run's drawing in map space, from its end tiles: its midpoint (mu, mv: tile centres), its length
--- (lm) and its rotation (degrees: the camera scales both axes alike, so it is the screen's too).
local function with_geometry(run: any): any
	local u0, v0, u1, v1 = run.x0 + 0.5, run.y0 + 0.5, run.x1 + 0.5, run.y1 + 0.5
	local du, dv = u1 - u0, v1 - v0
	run.mu, run.mv = (u0 + u1) * 0.5, (v0 + v1) * 0.5
	run.lm = math.sqrt(du * du + dv * dv)
	run.rot = if run.lm > 0 then math.deg(math.atan2(dv, du)) else 0
	return run
end

--- The straight runs of a tile path (at most RUN_MAX tiles each), in tile coordinates, with their
--- geometry; `.bbox` = { u0, v0, u1, v1 } of the whole railroad (map units).
function RoadLayer.build_runs(tiles: { number }, W: number, run_max: number): { Run }
	local runs = RoadLayer._build_runs(tiles, W, run_max)
	local u0, v0, u1, v1 = math.huge, math.huge, -math.huge, -math.huge
	for _, run in runs do
		with_geometry(run)
		u0 = math.min(u0, run.x0, run.x1)
		v0 = math.min(v0, run.y0, run.y1)
		u1 = math.max(u1, run.x0 + 1, run.x1 + 1)
		v1 = math.max(v1, run.y0 + 1, run.y1 + 1)
	end
	if #runs > 0 then
		(runs :: any).bbox = { u0, v0, u1, v1 }
	end
	return runs
end

function RoadLayer._build_runs(tiles: { number }, W: number, run_max: number): { Run }
	local runs = {}
	local n = #tiles
	if n == 0 then
		return runs
	end
	if n == 1 then
		local t = tiles[1]
		table.insert(runs, { x0 = t % W, y0 = t // W, x1 = t % W, y1 = t // W, mid = t })
		return runs
	end
	local i0 = 1
	while i0 < n do
		local a, b = tiles[i0], tiles[i0 + 1]
		local dx, dy = b % W - a % W, b // W - a // W
		local j = i0 + 1
		while j < n and j - i0 < run_max do
			local c, d = tiles[j], tiles[j + 1]
			if d % W - c % W ~= dx or d // W - c // W ~= dy then
				break
			end
			j += 1
		end
		local s, e = tiles[i0], tiles[j]
		table.insert(runs, { x0 = s % W, y0 = s // W, x1 = e % W, y1 = e // W, mid = tiles[(i0 + j) // 2] })
		i0 = j
	end
	return runs
end

--- An end tile's kind, from the tile next to it.
local function extremity(t: number, n: number, W: number): number
	local dx, dy = n % W - t % W, n // W - t // W
	if dx == 0 then
		return V
	elseif dy == 0 then
		return H
	end
	return V
end

--- A tile's kind, from the tiles before and after it.
local function direction(p: number, c: number, n: number, W: number): number
	local dx1, dy1 = c % W - p % W, c // W - p // W
	local dx2, dy2 = n % W - c % W, n // W - c // W
	if dx1 == dx2 and dy1 == dy2 then
		return if dx1 ~= 0 then H else V
	end
	if (dx1 == 0 and dx2 ~= 0) or (dx1 ~= 0 and dx2 == 0) then
		if dx1 == 0 and dx2 == 1 and dy1 == -1 then
			return BR
		elseif dx1 == 0 and dx2 == -1 and dy1 == -1 then
			return BL
		elseif dx1 == 0 and dx2 == 1 and dy1 == 1 then
			return TR
		elseif dx1 == 0 and dx2 == -1 and dy1 == 1 then
			return TL
		elseif dx1 == 1 and dx2 == 0 and dy2 == -1 then
			return TL
		elseif dx1 == -1 and dx2 == 0 and dy2 == -1 then
			return TR
		elseif dx1 == 1 and dx2 == 0 and dy2 == 1 then
			return BL
		elseif dx1 == -1 and dx2 == 0 and dy2 == 1 then
			return BR
		end
	end
	return V
end

--- The kind of every tile of a path.
function RoadLayer.rail_kinds(tiles: { number }, W: number): { number }
	local n = #tiles
	local kinds = table.create(n, V)
	if n >= 2 then
		kinds[1] = extremity(tiles[1], tiles[2], W)
		for i = 2, n - 1 do
			kinds[i] = direction(tiles[i - 1], tiles[i], tiles[i + 1], W)
		end
		kinds[n] = extremity(tiles[n], tiles[n - 1], W)
	end
	return kinds
end

--- The detailed track of a path: its tiles' kinds (rail_kinds), a straight stretch of tiles of one
--- kind side by side one piece (at most run_max tiles), each turn a piece of its own; `.bbox` as
--- build_runs'.
function RoadLayer.build_pieces(tiles: { number }, W: number, run_max: number): { Piece }
	local kinds = RoadLayer.rail_kinds(tiles, W)
	local pieces = {}
	local cur: any = nil
	local lx, ly = 0, 0
	for i, t in tiles do
		local x, y, k = t % W, t // W, kinds[i]
		if
			cur ~= nil
			and cur.kind == k
			and cur.n < run_max
			and ((k == H and y == ly and math.abs(x - lx) == 1) or (k == V and x == lx and math.abs(y - ly) == 1))
		then
			cur.x0, cur.x1 = math.min(cur.x0, x), math.max(cur.x1, x)
			cur.y0, cur.y1 = math.min(cur.y0, y), math.max(cur.y1, y)
			cur.n += 1
		else
			cur = { x0 = x, y0 = y, x1 = x, y1 = y, kind = k, n = 1 }
			table.insert(pieces, cur)
		end
		lx, ly = x, y
	end
	local u0, v0, u1, v1 = math.huge, math.huge, -math.huge, -math.huge
	for _, pc in pieces do
		-- the colour's tile: the middle one (a stretch is a row or a column)
		pc.mid = ((pc.y0 + pc.y1) // 2) * W + (pc.x0 + pc.x1) // 2
		pc.n = nil
		pc.mu, pc.mv = (pc.x0 + pc.x1 + 1) * 0.5, (pc.y0 + pc.y1 + 1) * 0.5
		u0, v0 = math.min(u0, pc.x0), math.min(v0, pc.y0)
		u1, v1 = math.max(u1, pc.x1 + 1), math.max(v1, pc.y1 + 1)
	end
	if #pieces > 0 then
		(pieces :: any).bbox = { u0, v0, u1, v1 }
	end
	return pieces
end

local function luminance(c: Color3): number
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
end

--- A railroad's bbox off the screen (with margin m)?
local function off_screen(
	bb: any,
	ax: number,
	ay: number,
	s: number,
	cu: number,
	cv: number,
	vw: number,
	vh: number,
	m: number
): boolean
	return bb ~= nil
		and (
			ax + (bb[3] - cu) * s < -m
			or ay + (bb[4] - cv) * s < -m
			or ax + (bb[1] - cu) * s > vw + m
			or ay + (bb[2] - cv) * s > vh + m
		)
end

--- A run's or piece's colour: the land under its middle tile, looked up again when `recolor` (else
--- kept), the border colours of the pass in `border` (owner -> colour).
local function colour(
	st: any,
	item: any,
	recolor: boolean,
	me: number,
	mine: Color3,
	border: { [number]: Color3 }
): Color3
	local col = item.col
	if col == nil or recolor then
		local own = st:tile_owner(item.mid)
		if own == 0 then
			col = RoadLayer.UNOWNED
		elseif own == me then
			col = mine
		else
			col = border[own]
			if col == nil then
				local c = st:owner_color(own)
				col = Color3.new(MapSurface.darken(c.R, c.G, c.B, RoadLayer.BORDER_DARKEN))
				border[own] = col
			end
		end
		item.col = col
	end
	return col
end

function RoadLayer.tick(self: any, dt: number)
	local st = self._state
	if st == nil then
		return
	end
	local cam = self.view.rig
	self._recolor -= dt
	if not self._dirty and cam.version == self._cam_version and self._recolor > 0 then
		return
	end
	self._cam_version = cam.version
	local ax, ay = cam:anchor()
	local s, cu, cv = cam.scale, cam.cu, cam.cv
	local vp = cam._vp
	-- the map's origin on the screen: the rails' frame goes there; a pan that keeps within the last
	-- layout's slack (same zoom, same viewport) moves it and nothing else
	local ox, oy = ax - cu * s, ay - cv * s
	local lay_slack = self._lay_slack
	if
		not self._dirty
		and self._recolor > 0
		and s == self._lay_s
		and vp == self._lay_vp
		and math.abs(ox - self._lay_x) <= lay_slack
		and math.abs(oy - self._lay_y) <= lay_slack
	then
		-- (no rail shown, zoomed out: not even the frame)
		if self._drawn > 0 then
			self:_place(ox, oy)
		end
		return
	end
	self:_place(ox, oy)
	-- (while the zoom changes every rail is written again each frame: none past the screen then)
	local slack = if s == self._lay_s then RoadLayer.PAN_SLACK else 0
	local recolor_due = self._recolor <= 0 or self._dirty
	if recolor_due then
		self._recolor = RoadLayer.RECOLOR_S
	end
	self._dirty = false
	self._lay_s, self._lay_vp, self._lay_x, self._lay_y, self._lay_slack = s, vp, ox, oy, slack
	self._pass += 1
	local pass = self._pass
	local drawn = 0
	local k = tonumber(st.map and st.map.k_lin) or Rules.K_LIN
	local dpr = RoadLayer.device_ratio()
	local zoom = cam.scale / k * dpr
	local a = math.clamp((zoom - (RoadLayer.MIN_ZOOM - RoadLayer.FADE_RANGE)) / RoadLayer.FADE_RANGE, 0, 1)
	local bars, track = self._bars, self._track
	if a > 0.01 then
		local W = st.map.W
		local detail = zoom >= RoadLayer.DETAIL_ZOOM
		-- the line: THICKNESS full-size tiles, at least a device pixel (thinner: fainter instead)
		local thick = RoadLayer.THICKNESS * cam.scale / k
		local line_a = a
		if thick < 1 / dpr then
			line_a = a * thick * dpr
			thick = 1 / dpr
		end
		local me = st.local_owner or 0
		local mine = RoadLayer.LIGHT
		if me ~= 0 then
			mine = if luminance(st:owner_color(me)) > RoadLayer.LIGHT_ABOVE then RoadLayer.DARK else RoadLayer.LIGHT
		end
		-- (colours follow the land under the rails: looked up again every RECOLOR_S, not on every
		-- camera move; the projection is done here, once per run, from the camera's anchor; the
		-- border colours are worked out again each pass, in a table kept for it)
		local recolor = recolor_due
		local border = self._border
		table.clear(border)
		local vw, vh = vp.X, vp.Y
		local pan = self._pan
		for rid, r in st.roads do
			if detail then
				local pieces = self._pieces[rid]
				if pieces == nil then
					pieces = RoadLayer.build_pieces(r.tiles or {}, W, RoadLayer.RUN_MAX)
					self._pieces[rid] = pieces
				end
				-- a railroad off the screen as a whole: none of its pieces is looked at
				if off_screen((pieces :: any).bbox, ax, ay, s, cu, cv, vw, vh, slack) then
					continue
				end
				-- (by index: `pieces.bbox` is a field of the same table)
				for i = 1, #pieces do
					local pc = pieces[i]
					local tw, th = pc.x1 - pc.x0 + 1, pc.y1 - pc.y0 + 1
					local w, h = tw * s, th * s
					local mx, my = ax + (pc.mu - cu) * s, ay + (pc.mv - cv) * s
					local mw, mh = w * 0.5 + slack, h * 0.5 + slack
					if mx < -mw or my < -mh or mx > vw + mw or my > vh + mh then
						continue
					end
					local col = colour(st, pc, recolor, me, mine, border)
					drawn += 1
					local j, fresh = acquire(track, pc, pass)
					local b = track.items[j]
					if b == nil then
						b = Instance.new("ImageLabel")
						b.Name = "Track"
						b.AnchorPoint = Vector2.new(0.5, 0.5)
						b.BackgroundTransparency = 1
						b.BorderSizePixel = 0
						b.ResampleMode = Enum.ResamplerMode.Pixelated
						b.ZIndex = RoadLayer.Z
						b.Parent = pan
						track.items[j] = b
					end
					if fresh then
						b.Visible = true
						b.Image = RailArt[KIND_ART[pc.kind]]
						-- a stretch repeats the tile once per tile (TileSize in scale: exact whatever the
						-- px), a turn is one tile
						if tw > 1 or th > 1 then
							b.ScaleType = Enum.ScaleType.Tile
							b.TileSize = UDim2.fromScale(1 / tw, 1 / th)
						else
							b.ScaleType = Enum.ScaleType.Stretch
						end
					end
					if track.col[j] ~= col then
						track.col[j] = col
						b.ImageColor3 = col
					end
					if track.a[j] ~= a then
						track.a[j] = a
						b.ImageTransparency = 1 - a
					end
					-- (in the rails' frame: where it is at this zoom)
					local x, y = pc.mu * s, pc.mv * s
					if track.x[j] ~= x or track.y[j] ~= y then
						track.x[j], track.y[j] = x, y
						b.Position = UDim2.fromOffset(x, y)
					end
					if track.w[j] ~= w or track.h[j] ~= h then
						track.w[j], track.h[j] = w, h
						b.Size = UDim2.fromOffset(w, h)
					end
				end
				continue
			end
			local runs = self._runs[rid]
			if runs == nil then
				runs = RoadLayer.build_runs(r.tiles or {}, W, RoadLayer.RUN_MAX)
				self._runs[rid] = runs
			end
			-- a railroad off the screen as a whole: none of its runs is looked at
			if off_screen((runs :: any).bbox, ax, ay, s, cu, cv, vw, vh, thick + slack) then
				continue
			end
			-- (by index: `runs.bbox` is a field of the same table, and `for _, run in runs` met it
			-- after the runs, failed, and left every later railroad undrawn and stale bars on the
			-- screen: 238K sessions' warnings a day on v79-v81, 2026-10-12)
			for i = 1, #runs do
				local run = runs[i]
				local len = run.lm * s
				local mx, my = ax + (run.mu - cu) * s, ay + (run.mv - cv) * s
				local m = len * 0.5 + thick + slack
				if mx < -m or my < -m or mx > vw + m or my > vh + m then
					continue
				end
				local col = colour(st, run, recolor, me, mine, border)
				drawn += 1
				local j, fresh = acquire(bars, run, pass)
				local b = bars.items[j]
				if b == nil then
					b = Instance.new("Frame")
					b.Name = "Rail"
					b.AnchorPoint = Vector2.new(0.5, 0.5)
					b.BorderSizePixel = 0
					b.ZIndex = RoadLayer.Z
					b.Parent = pan
					bars.items[j] = b
				end
				if fresh then
					b.Visible = true
					b.Rotation = run.rot
				end
				if bars.col[j] ~= col then
					bars.col[j] = col
					b.BackgroundColor3 = col
				end
				if bars.a[j] ~= line_a then
					bars.a[j] = line_a
					b.BackgroundTransparency = 1 - line_a
				end
				local x, y = run.mu * s, run.mv * s
				if bars.x[j] ~= x or bars.y[j] ~= y then
					bars.x[j], bars.y[j] = x, y
					b.Position = UDim2.fromOffset(x, y)
				end
				-- a run spans its end tiles' centres; half a thickness more each way closes the corners
				-- (corner tiles: two half-segments meeting at the centre)
				local w = len + thick
				if bars.w[j] ~= w or bars.h[j] ~= thick then
					bars.w[j], bars.h[j] = w, thick
					b.Size = UDim2.fromOffset(w, thick)
				end
			end
		end
	end
	sweep(bars, pass)
	sweep(track, pass)
	self._drawn = drawn
end

return RoadLayer
