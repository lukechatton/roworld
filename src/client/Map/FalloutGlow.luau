--!native
-- The glow of fresh fallout on the 2D map (2026-10-12, so irradiated land looks better and
-- glows: the fallout used to be a flat green, with no glow).
-- How it is made:
--   * heat: a tile that turns to fallout is at heat 1, which drains by HEAT_DECAY_PER_TICK / 255 a game
--     tick (gone in 25.5 s); a tile no longer fallout is at 0. Fallout already
--     on the map when the state is bound has none.
--   * the glow is worked out for one tile in every SCALE x SCALE block (its centre tile):
--     a "broil" of two value noises, contrast and intensity mixed from
--     cold to hot by the heat, a slower meta noise over it, all faded in by the heat; and, on some
--     blocks (a hash over the threshold), a dot of light flickering at a rate of its own
--     (the extract function). Kept in 0..1 (RGBA8).
--   * a 5-tap Gaussian blur across and down (BLUR), then laid over the map, linearly
--     filtered, times COVERAGE: one EditableImage
--     of the blocks (straight alpha) stretched over the map in one ImageLabel, under the overlays.
-- Worked out on the CPU, so redrawn UPDATE_S apart, not every frame, its noise (the costly part)
-- for as many blocks as NOISE_BUDGET_S allows each time, round robin (the noise moves over seconds);
-- not written on a frame the map surface wrote one of its images (MapSurface: Roblox shows one
-- EditableImage update a frame), unless it has waited SKIP_MAX frames. (2026-10-26, phones' slow
-- frames: its lists, noise and buffers are kept from one draw to the next, and the label is placed
-- again only when the camera moved.)
local AssetService = game:GetService("AssetService")
local RS = game:GetService("ReplicatedStorage")
local Airfront = RS:WaitForChild("Airfront")
local Defs = require(Airfront:WaitForChild("Core"):WaitForChild("Defs")) :: any
local FrameClock = require(script.Parent:WaitForChild("FrameClock")) :: any

local FalloutGlow = {}
FalloutGlow.__index = FalloutGlow

FalloutGlow.SCALE = 8 -- tiles a side of a glow block
-- the glow's look
FalloutGlow.BROIL_SPEED_COLD = 0.0018
FalloutGlow.BROIL_SPEED_HOT = 0.0
FalloutGlow.NOISE_FREQ1 = 0.059
FalloutGlow.NOISE_FREQ2 = 0.171
FalloutGlow.CONTRAST_LO_COLD = 0.52
FalloutGlow.CONTRAST_LO_HOT = 0.0
FalloutGlow.CONTRAST_HI_COLD = 1.0
FalloutGlow.CONTRAST_HI_HOT = 0.0
FalloutGlow.META_FREQ = 0.02
FalloutGlow.INTENSITY_COLD = 0.15
FalloutGlow.INTENSITY_HOT = 1.8
FalloutGlow.META_INFLUENCE_COLD = 1.0
FalloutGlow.META_INFLUENCE_HOT = 0.0
FalloutGlow.OPACITY_FADE_END = 1.0
FalloutGlow.BLOOM = { 0.054901960784313725, 0.8196078431372549, 0.0 }
FalloutGlow.COVERAGE = 1.1
FalloutGlow.HEAT_DECAY_PER_TICK = 1.0
FalloutGlow.PARTICLE_DARK = { 0.05, 0.4, 0.05 }
FalloutGlow.PARTICLE_BRIGHT = { 0.2, 1.0, 0.2 }
FalloutGlow.PARTICLE_THRESHOLD_UNOWNED = 0.85
FalloutGlow.PARTICLE_THRESHOLD_OWNED = 0.875
FalloutGlow.PARTICLE_FLICKER_SPEED = 0.2
FalloutGlow.PARTICLE_STRENGTH = 1.0
FalloutGlow.PARTICLE_FRESH_SCALE = 0.2
--- The blur's weights: the pixel, then 1 and 2 away
FalloutGlow.BLUR = { 0.375, 0.25, 0.0625 }
-- pacing
FalloutGlow.UPDATE_S = 1 / 20
FalloutGlow.NOISE_BUDGET_S = 0.0015
FalloutGlow.SKIP_MAX = 2
FalloutGlow.Z = 1 -- in the overlay, under the rails

local F_FALLOUT: number = Defs.F_FALLOUT
local band = bit32.band
local readu8 = buffer.readu8
local readi32 = buffer.readi32
local floor = math.floor
local sin = math.sin

local function fract(x: number): number
	return x - floor(x)
end

local function mix(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--- smoothstep (0..1 between e0 and e1); with e0 >= e1 a step at e0 ((x - e0) / 0 is +inf above it).
local function smoothstep(e0: number, e1: number, x: number): number
	if e1 <= e0 then
		return if x > e0 then 1 else 0
	end
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function hash3(x: number, y: number, z: number): number
	return fract(sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453)
end

--- Trilinear value noise, smoothstep-faded.
function FalloutGlow.vnoise3(px: number, py: number, pz: number): number
	local ix, iy, iz = floor(px), floor(py), floor(pz)
	local fx, fy, fz = px - ix, py - iy, pz - iz
	fx, fy, fz = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy), fz * fz * (3 - 2 * fz)
	local n000 = hash3(ix, iy, iz)
	local n100 = hash3(ix + 1, iy, iz)
	local n010 = hash3(ix, iy + 1, iz)
	local n110 = hash3(ix + 1, iy + 1, iz)
	local n001 = hash3(ix, iy, iz + 1)
	local n101 = hash3(ix + 1, iy, iz + 1)
	local n011 = hash3(ix, iy + 1, iz + 1)
	local n111 = hash3(ix + 1, iy + 1, iz + 1)
	return mix(mix(mix(n000, n100, fx), mix(n010, n110, fx), fy), mix(mix(n001, n101, fx), mix(n011, n111, fx), fy), fz)
end

function FalloutGlow.new(parent: Instance, view: any)
	local self = setmetatable({}, FalloutGlow) :: any
	local label = Instance.new("ImageLabel")
	label.Name = "FalloutGlow"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.ScaleType = Enum.ScaleType.Stretch
	label.ResampleMode = Enum.ResamplerMode.Default
	label.Active = false
	label.Visible = false
	label.ZIndex = FalloutGlow.Z
	label.Parent = parent
	self.label = label
	self.view = view
	self._state = nil :: any
	self._img = nil :: EditableImage?
	self._bw, self._bh = 0, 0
	--- block -> the tick its heat was 1 (blocks with heat); block -> fallout last seen (sample tiles)
	self._hot = {} :: { [number]: number }
	self._was = {} :: { [number]: boolean }
	--- block -> its noise (broil before contrast, meta) and when it was worked out
	self._noise = {} :: { [number]: { number } }
	self._order = {} :: { number }
	--- the hot blocks' next order (swapped with _order each draw)
	self._live = {} :: { number }
	self._rr = 1
	self._next = 0.0
	self._skipped = 0
	--- the pixel box written last time (cleared next time if it shrinks; the table is kept)
	self._box = nil :: { number }?
	self._box_buf = { 0, 0, 0, 0 }
	--- the label's last position and size (px)
	self._lx, self._ly, self._lw, self._lh = math.huge, math.huge, -1, -1
	--- the last box's pixels, and zeros of that size (WritePixelsBuffer takes a buffer of the box's
	--- size exactly; made again only when the box's size changes)
	self._out = nil :: buffer?
	self._out_cells = -1
	self._zero = nil :: buffer?
	self._zero_cells = -1
	return self
end

function FalloutGlow.bind(self: any, state: any)
	self._state = state
	self:_reset()
end

function FalloutGlow.unbind(self: any)
	self._state = nil
	table.clear(self._hot)
	table.clear(self._was)
	table.clear(self._noise)
	self.label.Visible = false
end

function FalloutGlow.destroy(self: any)
	self:unbind()
	if self._img ~= nil then
		self._img:Destroy()
		self._img = nil
	end
	self.label:Destroy()
end

--- A state (re)loaded: what is fallout now has no heat.
function FalloutGlow.on_snapshot(self: any)
	self:_reset()
end

function FalloutGlow._reset(self: any)
	table.clear(self._hot)
	table.clear(self._was)
	table.clear(self._noise)
	self._box = nil
	self.label.Visible = false
	local st = self._state
	if st == nil or st.map == nil or st.flags == nil then
		return
	end
	local W, H = st.map.W or Defs.W, st.map.H or Defs.H
	local S = FalloutGlow.SCALE
	local bw, bh = math.max(1, W // S), math.max(1, H // S)
	if bw ~= self._bw or bh ~= self._bh or self._img == nil then
		if self._img ~= nil then
			self._img:Destroy()
			self._img = nil
		end
		self._bw, self._bh = bw, bh
		local ok, img = pcall(function()
			return AssetService:CreateEditableImage({ Size = Vector2.new(bw, bh) })
		end)
		if ok and img ~= nil then
			self._img = img
			self.label.ImageContent = Content.fromObject(img)
		end
	end
	if (tonumber(st.fallout_count) or 1) <= 0 then
		return
	end
	local flags = st.flags
	local half = S // 2
	for j = 0, bh - 1 do
		local y = j * S + half
		if y >= H then
			break
		end
		for i = 0, bw - 1 do
			local x = i * S + half
			if x >= W then
				break
			end
			if band(readu8(flags, y * W + x), F_FALLOUT) ~= 0 then
				self._was[j * bw + i] = true
			end
		end
	end
end

--- GameState.flags_changed (tile * 256 + flags): a block's centre tile turned to fallout is hot.
function FalloutGlow.on_flags_changed(self: any, changed: { number })
	local st = self._state
	if st == nil or st.map == nil or self._bw == 0 then
		return
	end
	local W = st.map.W or Defs.W
	local S = FalloutGlow.SCALE
	local half = S // 2
	local bw, bh = self._bw, self._bh
	local tick = st.render_tick or st.tick or 0
	for _, v in changed do
		local tile = v // 256
		local x, y = tile % W, tile // W
		if x % S ~= half or y % S ~= half then
			continue
		end
		local i, j = x // S, y // S
		if i >= bw or j >= bh then
			continue
		end
		local b = j * bw + i
		local now = band(v % 256, F_FALLOUT) ~= 0
		local was = self._was[b] == true
		if now and not was then
			self._was[b] = true
			if self._hot[b] == nil then
				table.insert(self._order, b)
			end
			self._hot[b] = tick
			self._noise[b] = nil
		elseif was and not now then
			self._was[b] = nil
			self._hot[b] = nil
			self._noise[b] = nil
		end
	end
	self._next = 0
end

--- The glow of block `b` (centre tile cx, cy) at heat `heat`, tick `rt`: premultiplied rgba,
--- each in 0..1. `nz` = { broil noise, meta noise } (worked out when nil or stale).
local function extract(cx: number, cy: number, heat: number, rt: number, nz: { number }, owned: boolean)
	local G = FalloutGlow
	local lo = mix(G.CONTRAST_LO_COLD, G.CONTRAST_LO_HOT, heat)
	local hi = mix(G.CONTRAST_HI_COLD, G.CONTRAST_HI_HOT, heat)
	local broil = smoothstep(lo, hi, nz[1])
	local intensity = mix(G.INTENSITY_COLD, G.INTENSITY_HOT, heat)
		* mix(1.0, nz[2], mix(G.META_INFLUENCE_COLD, G.META_INFLUENCE_HOT, heat))
	local opacity = smoothstep(0.0, G.OPACITY_FADE_END, heat)
	local s = broil * intensity * opacity
	local col = G.BLOOM
	local r, g, bb, a = col[1] * s, col[2] * s, col[3] * s, s
	-- the particle dots (tile coordinates of the centre tile)
	local tx, ty = cx - 0.5, cy - 0.5
	local h1 = fract(sin(tx * 12.9898 + ty * 78.233) * 43758.5453)
	local h2 = fract(sin(tx * 63.7 + ty * 157.3) * 23421.631)
	if h2 > (if owned then G.PARTICLE_THRESHOLD_OWNED else G.PARTICLE_THRESHOLD_UNOWNED) then
		local rate = G.PARTICLE_FLICKER_SPEED * (0.4 + h1 * 1.2)
		local flick = math.max(0.0, sin(rt * rate + h1 * 12.0) * 0.8 + 0.2)
		flick *= flick
		flick *= mix(G.PARTICLE_FRESH_SCALE, 1.0, 1.0 - heat)
		flick *= opacity
		local k = flick * G.PARTICLE_STRENGTH
		local d, br = G.PARTICLE_DARK, G.PARTICLE_BRIGHT
		local pr, pg, pb = mix(d[1], br[1], h1) * k, mix(d[2], br[2], h1) * k, mix(d[3], br[3], h1) * k
		r, g, bb, a = r + pr, g + pg, bb + pb, a + math.max(pr, pg, pb)
	end
	return math.min(r, 1), math.min(g, 1), math.min(bb, 1), math.min(a, 1)
end

--- (written into the block's own table, `into`, when it has one)
local function noise_of(cx: number, cy: number, heat: number, rt: number, into: { number }?): { number }
	local G = FalloutGlow
	local t = rt * mix(G.BROIL_SPEED_COLD, G.BROIL_SPEED_HOT, heat)
	local n1 = FalloutGlow.vnoise3(cx * G.NOISE_FREQ1, cy * G.NOISE_FREQ1, t)
	local n2 = FalloutGlow.vnoise3(cx * G.NOISE_FREQ2, cy * G.NOISE_FREQ2, t * 1.3)
	local meta = FalloutGlow.vnoise3(cx * G.META_FREQ, cy * G.META_FREQ, t * 0.5)
	if into ~= nil then
		into[1], into[2] = n1 * 0.6 + n2 * 0.4, meta
		return into
	end
	return { n1 * 0.6 + n2 * 0.4, meta }
end

--- The blur down at a pixel (its index and those 1 and 2 rows either side) for channel byte `c`,
--- times COVERAGE and clamped to 0..1, as laid over the map.
local function vblur(tmp: buffer, p: number, a1: number, b1: number, a2: number, b2: number, c: number): number
	local w0, w1, w2 = FalloutGlow.BLUR[1], FalloutGlow.BLUR[2], FalloutGlow.BLUR[3]
	local readf32 = buffer.readf32
	local acc = readf32(tmp, p * 16 + c) * w0
		+ (readf32(tmp, a1 * 16 + c) + readf32(tmp, b1 * 16 + c)) * w1
		+ (readf32(tmp, a2 * 16 + c) + readf32(tmp, b2 * 16 + c)) * w2
	return math.min(1, acc * FalloutGlow.COVERAGE)
end

function FalloutGlow.tick(self: any, _dt: number)
	local st = self._state
	local label = self.label
	if st == nil or self._img == nil then
		return
	end
	local cam = self.view.rig
	local W, H = st.map.W or Defs.W, st.map.H or Defs.H
	if next(self._hot) == nil then
		if label.Visible then
			label.Visible = false
			self:_clear_box()
		end
		return
	end
	-- (laid over the map, moved when the camera did; drawn again UPDATE_S apart)
	local x0, y0 = cam:map_to_screen(0, 0)
	local x1, y1 = cam:map_to_screen(W, H)
	if x0 ~= self._lx or y0 ~= self._ly then
		self._lx, self._ly = x0, y0
		label.Position = UDim2.fromOffset(x0, y0)
	end
	if x1 - x0 ~= self._lw or y1 - y0 ~= self._lh then
		self._lw, self._lh = x1 - x0, y1 - y0
		label.Size = UDim2.fromOffset(x1 - x0, y1 - y0)
	end
	local now = FrameClock.now()
	if now < self._next then
		return
	end
	local surface = self.view.surface
	if surface ~= nil and surface.uploaded and self._skipped < FalloutGlow.SKIP_MAX then
		self._skipped += 1
		return
	end
	self._skipped = 0
	self._next = now + FalloutGlow.UPDATE_S
	self:_draw(st, W)
	label.Visible = true
end

function FalloutGlow._clear_box(self: any)
	local box = self._box
	local img = self._img
	if box == nil or img == nil then
		return
	end
	local w, h = box[3] - box[1] + 1, box[4] - box[2] + 1
	-- (zeros, never written to: kept while boxes of this size come and go)
	if self._zero_cells ~= w * h then
		self._zero_cells = w * h
		self._zero = buffer.create(w * h * 4)
	end
	img:WritePixelsBuffer(Vector2.new(box[1], box[2]), Vector2.new(w, h), self._zero :: buffer)
	self._box = nil
end

function FalloutGlow._draw(self: any, st: any, W: number)
	local G = FalloutGlow
	local S = G.SCALE
	local half = S / 2
	local bw, bh = self._bw, self._bh
	local rt = st.render_tick or st.tick or 0
	local own = st.owner
	local decay = G.HEAT_DECAY_PER_TICK / 255
	-- the hot blocks (the cold ones go) and their box (into the other list, swapped with this one)
	local order = self._order
	local live = self._live
	table.clear(live)
	local i0, j0, i1, j1 = math.huge, math.huge, -1, -1
	for _, b in order do
		local t0 = self._hot[b]
		if t0 == nil then
			continue
		end
		local heat = 1 - (rt - t0) * decay
		if heat <= 0 then
			self._hot[b] = nil
			self._noise[b] = nil
			continue
		end
		table.insert(live, b)
		local i, j = b % bw, b // bw
		i0, j0 = math.min(i0, i), math.min(j0, j)
		i1, j1 = math.max(i1, i), math.max(j1, j)
	end
	self._order, self._live = live, order
	if #live == 0 then
		self:_clear_box()
		self.label.Visible = false
		return
	end
	-- the noise: as many blocks as the budget allows, round robin; a block without any first
	local deadline = os.clock() + G.NOISE_BUDGET_S
	local n = #live
	local rr = ((self._rr - 1) % n) + 1
	for k = 0, n - 1 do
		local b = live[(rr + k - 1) % n + 1]
		local nz = self._noise[b]
		if nz ~= nil and os.clock() > deadline then
			continue
		end
		local heat = 1 - (rt - self._hot[b]) * decay
		local cx, cy = (b % bw) * S + half + 0.5, (b // bw) * S + half + 0.5
		self._noise[b] = noise_of(cx, cy, heat, rt, nz)
		self._rr = (rr + k) % n + 1
	end
	-- the box, 2 blocks of blur either side, inside the image
	i0, j0 = math.max(0, i0 - 2), math.max(0, j0 - 2)
	i1, j1 = math.min(bw - 1, i1 + 2), math.min(bh - 1, j1 + 2)
	local w, h = i1 - i0 + 1, j1 - j0 + 1
	-- extract (premultiplied) into a float grid of the box (scratch buffers kept, grown as needed)
	local cells = w * h
	if self._cap == nil or self._cap < cells then
		self._cap = cells
		self._grid = buffer.create(cells * 16)
		self._tmp = buffer.create(cells * 16)
	end
	if self._out_cells ~= cells then
		self._out_cells = cells
		self._out = buffer.create(cells * 4)
	end
	local grid, tmp = self._grid, self._tmp
	local out = self._out :: buffer
	buffer.fill(grid, 0, 0, cells * 16)
	buffer.fill(out, 0, 0, cells * 4)
	local writef32, readf32, writeu8 = buffer.writef32, buffer.readf32, buffer.writeu8
	for _, b in live do
		local i, j = b % bw, b // bw
		local heat = 1 - (rt - self._hot[b]) * decay
		local tile = (j * S + S // 2) * W + i * S + S // 2
		local owned = own ~= nil and readi32(own, tile * 4) > 0
		local r, g, bb, a = extract(i * S + half + 0.5, j * S + half + 0.5, heat, rt, self._noise[b], owned)
		local o = ((j - j0) * w + (i - i0)) * 16
		writef32(grid, o, r)
		writef32(grid, o + 4, g)
		writef32(grid, o + 8, bb)
		writef32(grid, o + 12, a)
	end
	-- blur across, then down (clamped at the box's edges, where it is zero anyway)
	local wt = G.BLUR
	local w0, w1, w2 = wt[1], wt[2], wt[3]
	for y = 0, h - 1 do
		local row = y * w
		for x = 0, w - 1 do
			local xa1, xb1 = math.min(w - 1, x + 1), math.max(0, x - 1)
			local xa2, xb2 = math.min(w - 1, x + 2), math.max(0, x - 2)
			for c = 0, 12, 4 do
				local acc = readf32(grid, (row + x) * 16 + c) * w0
					+ (readf32(grid, (row + xa1) * 16 + c) + readf32(grid, (row + xb1) * 16 + c)) * w1
					+ (readf32(grid, (row + xa2) * 16 + c) + readf32(grid, (row + xb2) * 16 + c)) * w2
				writef32(tmp, (row + x) * 16 + c, acc)
			end
		end
	end
	for y = 0, h - 1 do
		local ya1, yb1 = math.min(h - 1, y + 1) * w, math.max(0, y - 1) * w
		local ya2, yb2 = math.min(h - 1, y + 2) * w, math.max(0, y - 2) * w
		local row = y * w
		for x = 0, w - 1 do
			-- (alpha first: a pixel with none is left clear)
			local a = vblur(tmp, row + x, ya1 + x, yb1 + x, ya2 + x, yb2 + x, 12)
			if a > 0.002 then
				-- premultiplied to straight alpha for the GUI
				local o = (row + x) * 4
				writeu8(
					out,
					o,
					math.min(255, floor(vblur(tmp, row + x, ya1 + x, yb1 + x, ya2 + x, yb2 + x, 0) / a * 255 + 0.5))
				)
				writeu8(
					out,
					o + 1,
					math.min(255, floor(vblur(tmp, row + x, ya1 + x, yb1 + x, ya2 + x, yb2 + x, 4) / a * 255 + 0.5))
				)
				writeu8(
					out,
					o + 2,
					math.min(255, floor(vblur(tmp, row + x, ya1 + x, yb1 + x, ya2 + x, yb2 + x, 8) / a * 255 + 0.5))
				)
				writeu8(out, o + 3, floor(a * 255 + 0.5))
			end
		end
	end
	-- the last box where this one does not reach is cleared first
	local box = self._box
	if box ~= nil and (box[1] < i0 or box[2] < j0 or box[3] > i1 or box[4] > j1) then
		self:_clear_box()
	end
	local img = self._img :: EditableImage
	img:WritePixelsBuffer(Vector2.new(i0, j0), Vector2.new(w, h), out)
	local nb = self._box_buf
	nb[1], nb[2], nb[3], nb[4] = i0, j0, i1, j1
	self._box = nb
end

return FalloutGlow
