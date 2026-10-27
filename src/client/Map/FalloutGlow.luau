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
-- (2026-10-27, "Script - Fallout Glow" led phones' slow frames: a MIRV's or a few far-apart nukes'
-- box is most of the image, and it was blurred whole every draw (a MIRV: ~32 ms a draw on a Mac,
-- interpreted). Now only what the view can reach is drawn (`_win`: the view's blocks and a quarter
-- view more each way, drawn again at once when the view leaves it for glow not drawn), the blur goes
-- over the rows with glow and the columns it reaches, sliding along them (one read a cell, not five),
-- a block's hashes are worked out once, phones redraw at UPDATE_S_MOBILE and a long draw waits DUTY
-- times as long. The pixels drawn are the same.)
local AssetService = game:GetService("AssetService")
local UserInputService = game:GetService("UserInputService")
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
--- Phones (touch, no keyboard): the glow changes over seconds, only its dots flicker faster
FalloutGlow.UPDATE_S_MOBILE = 1 / 12
--- The next draw waits at least DUTY times as long as this one took (a slow phone's glow takes at
--- most 1 / DUTY of its time, not every frame)
FalloutGlow.DUTY = 8
FalloutGlow.NOISE_BUDGET_S = 0.0015
FalloutGlow.SKIP_MAX = 2
--- The window drawn: the view's blocks and CUSHION more each way (the linear filter and a frame of
--- panning), then a quarter of the view (at least WIN_MIN blocks) more each way
FalloutGlow.CUSHION = 2
FalloutGlow.WIN_MIN = 4
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
	--- block -> its dot's hashes (from where it is: worked out once)
	self._h1 = {} :: { [number]: number }
	self._h2 = {} :: { [number]: number }
	--- the last draw's box: the hot blocks and the blur's 2 blocks either side (i1 < i0: none)
	self._fb = { 0, 0, -1, -1 }
	--- the blocks the view can reach (i0, j0, i1, j1; none until the first tick), and per row of a
	--- draw's work box its first and last column with glow
	self._win = { 0, 0, -1, -1 }
	self._rlo = {} :: { number }
	self._rhi = {} :: { number }
	--- and per column the first and last row blurred across
	self._cf = {} :: { number }
	self._cl = {} :: { number }
	--- label.Visible as last written
	self._vis = false
	return self
end

function FalloutGlow._show(self: any, on: boolean)
	if self._vis ~= on then
		self._vis = on
		self.label.Visible = on
	end
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
	self:_show(false)
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
	table.clear(self._h1)
	table.clear(self._h2)
	-- (cleared, not forgotten: a match that ended glowing left its pixels for the next one's first
	-- glow to show where that one's box did not reach)
	self:_clear_box()
	self._win[3], self._win[4] = -1, -1
	self._fb[3] = -1
	self:_show(false)
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

--- A block's dot hashes from its centre (cx, cy): h1 its colour and rate, h2 whether it has one.
local function hashes(cx: number, cy: number): (number, number)
	-- (tile coordinates of the centre tile)
	local tx, ty = cx - 0.5, cy - 0.5
	return fract(sin(tx * 12.9898 + ty * 78.233) * 43758.5453), fract(sin(tx * 63.7 + ty * 157.3) * 23421.631)
end

--- The glow of a block at heat `heat`, tick `rt`: premultiplied rgba,
--- each in 0..1. `nz` = { broil noise, meta noise } (worked out when nil or stale), h1 / h2 its hashes.
local function extract(heat: number, rt: number, nz: { number }, owned: boolean, h1: number, h2: number)
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
	-- the particle dots
	if h2 >(if owned then G.PARTICLE_THRESHOLD_OWNED else G.PARTICLE_THRESHOLD_UNOWNED) then
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

--- The window follows the view: when the view's blocks (and CUSHION) leave it, or it is far bigger
--- than they are (zoomed in), it is made again around them, a quarter of the view more each way.
--- True when that shows glow the last draw did not (a draw is due now).
function FalloutGlow._follow_view(self: any, cam: any): boolean
	local S, c = FalloutGlow.SCALE, FalloutGlow.CUSHION
	local u0, v0, u1, v1 = cam:visible_rect()
	local vi0, vj0, vi1, vj1 = floor(u0 / S) - c, floor(v0 / S) - c, floor(u1 / S) + c, floor(v1 / S) + c
	local win = self._win
	local left = vi0 < win[1] or vj0 < win[2] or vi1 > win[3] or vj1 > win[4]
	local vw, vh = vi1 - vi0 + 1, vj1 - vj0 + 1
	if left or win[3] - win[1] + 1 > 3 * vw or win[4] - win[2] + 1 > 3 * vh then
		local mi, mj = math.max(FalloutGlow.WIN_MIN, vw // 4), math.max(FalloutGlow.WIN_MIN, vh // 4)
		win[1], win[2], win[3], win[4] = vi0 - mi, vj0 - mj, vi1 + mi, vj1 + mj
	end
	if not left then
		return false
	end
	-- the glow's box (as of the last draw) where the view now is, and whether that was drawn
	local fb = self._fb
	if fb[3] < fb[1] then
		return false
	end
	local i0, j0 = math.max(vi0, fb[1]), math.max(vj0, fb[2])
	local i1, j1 = math.min(vi1, fb[3]), math.min(vj1, fb[4])
	if i1 < i0 or j1 < j0 then
		return false
	end
	local box = self._box
	return box == nil or i0 < box[1] or j0 < box[2] or i1 > box[3] or j1 > box[4]
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
		if self._vis then
			self:_show(false)
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
	-- (the view about to show what was not drawn: drawn now)
	if self:_follow_view(cam) then
		self._next = 0
	end
	if now < self._next then
		return
	end
	local surface = self.view.surface
	if surface ~= nil and surface.uploaded and self._skipped < FalloutGlow.SKIP_MAX then
		self._skipped += 1
		return
	end
	self._skipped = 0
	local t0 = os.clock()
	self:_draw(st, W)
	local wait = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
		then FalloutGlow.UPDATE_S_MOBILE
		else FalloutGlow.UPDATE_S
	-- (not while a Studio film steps the clock: its frames take real time the film does not)
	if FrameClock.film == nil then
		wait = math.max(wait, (os.clock() - t0) * FalloutGlow.DUTY)
	end
	self._next = now + wait
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
	local hot, noise = self._hot, self._noise
	-- the hot blocks (the cold ones go) and their box (into the other list, swapped with this one)
	local order = self._order
	local live = self._live
	table.clear(live)
	local n, missing = 0, 0
	local i0, j0, i1, j1 = math.huge, math.huge, -1, -1
	for _, b in order do
		local t0 = hot[b]
		if t0 == nil then
			continue
		end
		local heat = 1 - (rt - t0) * decay
		if heat <= 0 then
			hot[b] = nil
			noise[b] = nil
			continue
		end
		n += 1
		live[n] = b
		if noise[b] == nil then
			missing += 1
		end
		local i, j = b % bw, b // bw
		if i < i0 then
			i0 = i
		end
		if i > i1 then
			i1 = i
		end
		if j < j0 then
			j0 = j
		end
		if j > j1 then
			j1 = j
		end
	end
	self._order, self._live = live, order
	local fb = self._fb
	if n == 0 then
		fb[3] = -1
		self:_clear_box()
		self:_show(false)
		return
	end
	fb[1], fb[2], fb[3], fb[4] = math.max(0, i0 - 2), math.max(0, j0 - 2), math.min(bw - 1, i1 + 2), math.min(bh - 1, j1 + 2)
	-- the noise: as many blocks as the budget allows, round robin; a block without any first (past
	-- the budget only those: the clock is not asked again, and the loop stops when none is left)
	local deadline = os.clock() + G.NOISE_BUDGET_S
	local spent = false
	local rr = ((self._rr - 1) % n) + 1
	for k = 0, n - 1 do
		local b = live[(rr + k - 1) % n + 1]
		local nz = noise[b]
		if nz ~= nil then
			if spent then
				continue
			elseif os.clock() > deadline then
				spent = true
				if missing == 0 then
					break
				end
				continue
			end
		else
			missing -= 1
		end
		local heat = 1 - (rt - hot[b]) * decay
		local cx, cy = (b % bw) * S + half + 0.5, (b // bw) * S + half + 0.5
		noise[b] = noise_of(cx, cy, heat, rt, nz)
		self._rr = (rr + k) % n + 1
		if spent and missing == 0 then
			break
		end
	end
	-- what is drawn (R): the box, 2 blocks of blur either side, inside the image and the window;
	-- worked out over K, R and the blur's reach (2 blocks) inside the image. (Clamped at K's edges
	-- as the box was at its own: at the image's edge the same, elsewhere R's blur stays inside K.)
	local win = self._win
	local ri0, rj0 = math.max(0, i0 - 2, win[1]), math.max(0, j0 - 2, win[2])
	local ri1, rj1 = math.min(bw - 1, i1 + 2, win[3]), math.min(bh - 1, j1 + 2, win[4])
	if ri1 < ri0 or rj1 < rj0 then
		-- (none of it where the view is or can go before the next draw)
		self:_clear_box()
		self:_show(false)
		return
	end
	local ki0, kj0 = math.max(0, ri0 - 2), math.max(0, rj0 - 2)
	local kw, kh = math.min(bw - 1, ri1 + 2) - ki0 + 1, math.min(bh - 1, rj1 + 2) - kj0 + 1
	local w, h = ri1 - ri0 + 1, rj1 - rj0 + 1
	-- extract (premultiplied) into a float grid of K (scratch buffers kept, grown as needed)
	local kcells, cells = kw * kh, w * h
	if self._cap == nil or self._cap < kcells then
		self._cap = kcells
		self._grid = buffer.create(kcells * 16)
		self._tmp = buffer.create(kcells * 16)
	end
	if self._out_cells ~= cells then
		self._out_cells = cells
		self._out = buffer.create(cells * 4)
	end
	local grid, tmp = self._grid, self._tmp
	local out = self._out :: buffer
	buffer.fill(grid, 0, 0, kcells * 16)
	buffer.fill(tmp, 0, 0, kcells * 16)
	buffer.fill(out, 0, 0, cells * 4)
	-- each row's first and last column with glow (1-based by row)
	local rlo, rhi = self._rlo, self._rhi
	for y = 1, kh do
		rlo[y], rhi[y] = kw, -1
	end
	local h1s, h2s = self._h1, self._h2
	local ki1, kj1 = ki0 + kw - 1, kj0 + kh - 1
	local writef32, readf32, writeu8 = buffer.writef32, buffer.readf32, buffer.writeu8
	for _, b in live do
		local i, j = b % bw, b // bw
		if i < ki0 or i > ki1 or j < kj0 or j > kj1 then
			continue
		end
		local heat = 1 - (rt - hot[b]) * decay
		local tile = (j * S + S // 2) * W + i * S + S // 2
		local owned = own ~= nil and readi32(own, tile * 4) > 0
		local h1, h2 = h1s[b], h2s[b]
		if h1 == nil then
			h1, h2 = hashes(i * S + half + 0.5, j * S + half + 0.5)
			h1s[b], h2s[b] = h1, h2
		end
		local r, g, bb, a = extract(heat, rt, noise[b], owned, h1, h2)
		local x, y = i - ki0, j - kj0 + 1
		local o = ((y - 1) * kw + x) * 16
		writef32(grid, o, r)
		writef32(grid, o + 4, g)
		writef32(grid, o + 8, bb)
		writef32(grid, o + 12, a)
		if x < rlo[y] then
			rlo[y] = x
		end
		if x > rhi[y] then
			rhi[y] = x
		end
	end
	-- blur across, then down, over R's columns that a glowing block reaches (the rest stays zero).
	-- Each pass slides a window of the 5 cells it weighs along its row / column: one read per cell
	-- and channel, not five (the same sums in the same order).
	local wt = G.BLUR
	local w0, w1, w2 = wt[1], wt[2], wt[3]
	local cov = G.COVERAGE
	local xr0, xr1, yr0 = ri0 - ki0, ri1 - ki0, rj0 - kj0
	-- per column of K: the first and last row blurred across (1-based by column; -1: none)
	local cf, cl = self._cf, self._cl
	for x = xr0 + 1, xr1 + 1 do
		cf[x], cl[x] = -1, -1
	end
	for y = 0, kh - 1 do
		local lo, hi = rlo[y + 1], rhi[y + 1]
		if hi < 0 then
			continue
		end
		local xa, xb = math.max(xr0, lo - 2), math.min(xr1, hi + 2)
		if xb < xa then
			continue
		end
		local row = y * kw
		local q = (row + math.max(0, xa - 2)) * 16
		local rm2, gm2, bm2, am2 = readf32(grid, q), readf32(grid, q + 4), readf32(grid, q + 8), readf32(grid, q + 12)
		q = (row + math.max(0, xa - 1)) * 16
		local rm1, gm1, bm1, am1 = readf32(grid, q), readf32(grid, q + 4), readf32(grid, q + 8), readf32(grid, q + 12)
		q = (row + xa) * 16
		local r0, g0, b0, a0 = readf32(grid, q), readf32(grid, q + 4), readf32(grid, q + 8), readf32(grid, q + 12)
		q = (row + math.min(kw - 1, xa + 1)) * 16
		local rp1, gp1, bp1, ap1 = readf32(grid, q), readf32(grid, q + 4), readf32(grid, q + 8), readf32(grid, q + 12)
		q = (row + math.min(kw - 1, xa + 2)) * 16
		local rp2, gp2, bp2, ap2 = readf32(grid, q), readf32(grid, q + 4), readf32(grid, q + 8), readf32(grid, q + 12)
		for x = xa, xb do
			local p = (row + x) * 16
			writef32(tmp, p, r0 * w0 + (rp1 + rm1) * w1 + (rp2 + rm2) * w2)
			writef32(tmp, p + 4, g0 * w0 + (gp1 + gm1) * w1 + (gp2 + gm2) * w2)
			writef32(tmp, p + 8, b0 * w0 + (bp1 + bm1) * w1 + (bp2 + bm2) * w2)
			writef32(tmp, p + 12, a0 * w0 + (ap1 + am1) * w1 + (ap2 + am2) * w2)
			if cl[x + 1] < 0 then
				cf[x + 1] = y
			end
			cl[x + 1] = y
			q = (row + math.min(kw - 1, x + 3)) * 16
			rm2, rm1, r0, rp1, rp2 = rm1, r0, rp1, rp2, readf32(grid, q)
			gm2, gm1, g0, gp1, gp2 = gm1, g0, gp1, gp2, readf32(grid, q + 4)
			bm2, bm1, b0, bp1, bp2 = bm1, b0, bp1, bp2, readf32(grid, q + 8)
			am2, am1, a0, ap1, ap2 = am1, a0, ap1, ap2, readf32(grid, q + 12)
		end
	end
	local yr1 = yr0 + h - 1
	for x = xr0, xr1 do
		local last = cl[x + 1]
		if last < 0 then
			continue
		end
		-- R's rows the blur down reaches in this column
		local ya, yb = math.max(yr0, cf[x + 1] - 2), math.min(yr1, last + 2)
		if yb < ya then
			continue
		end
		local q = (math.max(0, ya - 2) * kw + x) * 16
		local rm2, gm2, bm2, am2 = readf32(tmp, q), readf32(tmp, q + 4), readf32(tmp, q + 8), readf32(tmp, q + 12)
		q = (math.max(0, ya - 1) * kw + x) * 16
		local rm1, gm1, bm1, am1 = readf32(tmp, q), readf32(tmp, q + 4), readf32(tmp, q + 8), readf32(tmp, q + 12)
		q = (ya * kw + x) * 16
		local r0, g0, b0, a0 = readf32(tmp, q), readf32(tmp, q + 4), readf32(tmp, q + 8), readf32(tmp, q + 12)
		q = (math.min(kh - 1, ya + 1) * kw + x) * 16
		local rp1, gp1, bp1, ap1 = readf32(tmp, q), readf32(tmp, q + 4), readf32(tmp, q + 8), readf32(tmp, q + 12)
		q = (math.min(kh - 1, ya + 2) * kw + x) * 16
		local rp2, gp2, bp2, ap2 = readf32(tmp, q), readf32(tmp, q + 4), readf32(tmp, q + 8), readf32(tmp, q + 12)
		for yk = ya, yb do
			-- (alpha first: a pixel with none is left clear; each channel times COVERAGE, at most 1)
			local a = math.min(1, (a0 * w0 + (ap1 + am1) * w1 + (ap2 + am2) * w2) * cov)
			if a > 0.002 then
				-- premultiplied to straight alpha for the GUI
				local o = ((yk - yr0) * w + x - xr0) * 4
				local r = math.min(1, (r0 * w0 + (rp1 + rm1) * w1 + (rp2 + rm2) * w2) * cov)
				local g = math.min(1, (g0 * w0 + (gp1 + gm1) * w1 + (gp2 + gm2) * w2) * cov)
				local bb = math.min(1, (b0 * w0 + (bp1 + bm1) * w1 + (bp2 + bm2) * w2) * cov)
				writeu8(out, o, math.min(255, floor(r / a * 255 + 0.5)))
				writeu8(out, o + 1, math.min(255, floor(g / a * 255 + 0.5)))
				writeu8(out, o + 2, math.min(255, floor(bb / a * 255 + 0.5)))
				writeu8(out, o + 3, floor(a * 255 + 0.5))
			end
			q = (math.min(kh - 1, yk + 3) * kw + x) * 16
			rm2, rm1, r0, rp1, rp2 = rm1, r0, rp1, rp2, readf32(tmp, q)
			gm2, gm1, g0, gp1, gp2 = gm1, g0, gp1, gp2, readf32(tmp, q + 4)
			bm2, bm1, b0, bp1, bp2 = bm1, b0, bp1, bp2, readf32(tmp, q + 8)
			am2, am1, a0, ap1, ap2 = am1, a0, ap1, ap2, readf32(tmp, q + 12)
		end
	end
	-- the last box where this one does not reach is cleared first
	local box = self._box
	if box ~= nil and (box[1] < ri0 or box[2] < rj0 or box[3] > ri1 or box[4] > rj1) then
		self:_clear_box()
	end
	local img = self._img :: EditableImage
	img:WritePixelsBuffer(Vector2.new(ri0, rj0), Vector2.new(w, h), out)
	local nb = self._box_buf
	nb[1], nb[2], nb[3], nb[4] = ri0, rj0, ri1, rj1
	self._box = nb
	self:_show(true)
end

return FalloutGlow
