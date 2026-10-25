--!native
-- Effects on the 2D map: a nuke's shockwave ring grows to 1.5 x its
-- blast radius over 1.5 s behind a white flash, a destroyed ship / shot-down nuke pops a small
-- ring (0.8 s), and the camera shakes a little for nukes near the view. Pooled GUI circles.
-- Conquests by the local player (a flag and a gold popup): a victory
-- flag planted at the conquered name's location, its banner the conqueror's colour (Assets/MapFx:
-- 10 frames of 24 x 24 at 90 ms, drawn 22 full-size tiles wide, 2.5 s, fade in over the first 10 % and
-- out after 60 %; 2026-10-25: it replaced a sword clash for the elimination), and a
-- white "+ 12.3K" gold line below it (font 6 tiles, fading
-- linearly).
-- Both keep a minimum on-screen size, so a zoomed-out map still shows them.
-- Income (2026-10-07:
-- trains show the little money-increase popup as they pass through cities too): gold the local
-- player earned at a tile, a train's stop at a station, is a white "+ 25.0K" that starts 3 full-size tiles
-- above the tile, rises 3 tiles a second and fades out over 1.5 s (font 6 tiles). It keeps a minimum
-- size on screen and is not drawn on a map zoomed far out (and is never bigger than
-- 40 px).
-- Explosions (sprites from the fx atlas; added 2026-10-04 for a destroyed defense post and for a
-- nuke shot down by a SAM): a
-- destroyed defense post or Arsenal structure plays BuildingExplosion over a small ring, a nuke shot
-- down plays SAMExplosion where it was. They are seen, not heard (shots and hits were made silent
-- on 2026-09-27: together they were a constant racket).
-- Nukes (since
-- 2026-10-12; the trailer's hydrogen bombs fell flat when a ring and a green stain were all
-- a nuke left): a nuke that lands plays the explosion (Assets/MapFx: 12 frames of
-- 60 x 60 at 70 ms, drawn 60 full-size tiles wide) and leaves debris burning: mini fires, smoke, big
-- smoke and smoke with fire (DEBRIS_PLAN, looping) scattered within half its radius, 6 s, fading in
-- over the first 10 % and out after 80 %; its ring grows to 1.5 x that radius. The radius is the
-- look's (NUKE_FX_RADIUS), not the blast's.
local ContentProvider = game:GetService("ContentProvider")
local RS = game:GetService("ReplicatedStorage")
local Airfront = RS:WaitForChild("Airfront")
local Defs = require(Airfront:WaitForChild("Core"):WaitForChild("Defs")) :: any
local Rules = require(Airfront:WaitForChild("Core"):WaitForChild("Rules")) :: any
local Sprites = require(Airfront:WaitForChild("Assets"):WaitForChild("MapSprites")) :: any
-- Sprites drawn for Rofront (tools/assets/make_map_fx.py; 2026-10-25: new art for the nuke
-- explosion and the territory claim): the nuke's explosion and the
-- conquest's flag. The other explosions and the debris come from the fx atlas (Assets/MapSprites).
local MapFx = require(Airfront:WaitForChild("Assets"):WaitForChild("MapFx")) :: any
local FrameClock = require(script.Parent:WaitForChild("FrameClock")) :: any

local FxLayer = {}
FxLayer.__index = FxLayer

FxLayer.NUKE_SHOCK_S = 1.5
FxLayer.NUKE_SHOCK_K = 1.5
FxLayer.POP_S = 0.8
FxLayer.POP_RADIUS = 40 -- full-size tiles (the ring of a ship or nuke shot down)
FxLayer.Z = 16
FxLayer.CONQUEST_S = 2.5
FxLayer.CONQUEST_FADE_IN = 0.1
FxLayer.CONQUEST_FADE_OUT = 0.6
--- the flag's frames in Assets/MapFx (px: `flag` in its colours, `banner` the cloth under it, tinted),
--- how wide it is drawn (full-size tiles) and at least (px)
FxLayer.FLAG = MapFx.flag
FxLayer.BANNER = MapFx.banner
FxLayer.FLAG_FRAME_S = 0.09
FxLayer.FLAG_WORLD = 22
FxLayer.FLAG_MIN_PX = 30
--- a banner colour darker than this (luminance) is lightened toward white by BANNER_LIFT, so the cloth
--- stands out from the flag's dark outline
FxLayer.BANNER_MIN_LUMA = 0.32
FxLayer.BANNER_LIFT = 0.3
FxLayer.GOLD_Y_OFFSET = 8 -- full-size tiles below the name
FxLayer.GOLD_SIZE = 6 -- full-size tiles
FxLayer.GOLD_MIN_PX = 15
FxLayer.GOLD_FONT = Font.fromId(12187365977, Enum.FontWeight.Bold)
--- Income popups: lifetime, rise (full-size tiles a second), where it starts
--- (tiles above the tile), the font (tiles; at least BONUS_MIN_PX on screen), the zoom (px per full-size
--- tile) under which none are drawn, and how many may be up at once.
FxLayer.BONUS_S = 1.5
FxLayer.BONUS_RISE = 3.0
FxLayer.BONUS_Y_OFFSET = -3.0
FxLayer.BONUS_SIZE = 6.0
FxLayer.BONUS_MIN_PX = 13
--- (on a map zoomed far in, 6 tiles of text would fill the screen)
FxLayer.BONUS_MAX_PX = 40
FxLayer.BONUS_CULL_ZOOM = 0.3
FxLayer.BONUS_MAX = 48
--- The explosion sprites: the atlas row's y, a frame's size, how many frames and how long each shows,
--- how wide it is drawn (full-size tiles) and the least it is drawn on screen (px); `image` and `x`: an
--- atlas other than the fx one (Sprites), and where the row starts in it.
--- (`loop`: the debris, which cycle until their lifetime ends; the atlas's rows 6 to 9)
FxLayer.BURSTS = {
	building = { y = 98, w = 17, h = 15, frames = 10, frame_s = 0.07, world = 18, min_px = 32 },
	sam = { y = 60, w = 48, h = 38, frames = 9, frame_s = 0.08, world = 40, min_px = 60 },
	nuke = {
		image = MapFx.id,
		x = MapFx.nuke.x,
		y = MapFx.nuke.y,
		w = MapFx.nuke.w,
		h = MapFx.nuke.h,
		frames = MapFx.nuke.frames,
		frame_s = 0.07,
		world = 60,
		min_px = 36,
	},
	fire = { y = 158, w = 7, h = 13, frames = 6, frame_s = 0.1, world = 7, min_px = 4, loop = true },
	smoke = { y = 171, w = 11, h = 12, frames = 4, frame_s = 0.12, world = 11, min_px = 6, loop = true },
	big_smoke = { y = 183, w = 24, h = 16, frames = 5, frame_s = 0.12, world = 24, min_px = 12, loop = true },
	smoke_fire = { y = 199, w = 24, h = 16, frames = 5, frame_s = 0.12, world = 24, min_px = 12, loop = true },
}
--- A nuke's look by Defs.N_* (full-size tiles): 70 for an atom bomb, 160 for a hydrogen bomb, 70 a
--- MIRV warhead; the Arsenal's Mega Nuke (a blast between the two) 120, a Scatter
--- bomb an atom's.
FxLayer.NUKE_FX_RADIUS = { [0] = 70, [1] = 160, [3] = 70, [4] = 120, [5] = 70 }
--- The debris a nuke leaves: the sprite, how far out (of the radius) and how many (radius x density)
FxLayer.DEBRIS_PLAN = {
	{ kind = "fire", factor = 1.0, density = 1 / 25 },
	{ kind = "smoke", factor = 1.0, density = 1 / 28 },
	{ kind = "big_smoke", factor = 0.9, density = 1 / 70 },
	{ kind = "smoke_fire", factor = 0.9, density = 1 / 70 },
}
FxLayer.DEBRIS_S = 6.0 -- s each debris sprite lasts
FxLayer.DEBRIS_FADE_IN = 0.1
FxLayer.DEBRIS_FADE_OUT = 0.8
--- Every sprite is a GUI object, and a MIRV's 350 warheads would be some 2,500
--- GUI objects. So at most BURST_MAX explosions and DEBRIS_MAX debris are up at once (the newest
--- wait their turn: none is drawn), and of a strike's warheads about WARHEAD_DEBRIS leave debris,
--- picked at random over all of them (so it is spread over the whole strike).
FxLayer.BURST_MAX = 96
FxLayer.DEBRIS_MAX = 240
FxLayer.WARHEAD_DEBRIS = 28
--- how long a strike's warheads are counted together (s)
FxLayer.WARHEAD_WINDOW_S = 10.0

type Fx = { u: number, v: number, r0: number, r1: number, t0: number, dur: number, col: Color3, flash: boolean }
type Pop = { u: number, v: number, t0: number, text: string, col: Color3 }
type PopGui = { flag: ImageLabel, banner: ImageLabel, gold: TextLabel, stroke: UIStroke }
--- (`life`, `fade_in`, `fade_out`: debris only; a burst ends with its last frame)
type Burst = { u: number, v: number, t0: number, row: any, life: number?, fade_in: number?, fade_out: number? }
type Bonus = { u: number, v: number, t0: number, text: string }
type BonusGui = { label: TextLabel, stroke: UIStroke }

function FxLayer.new(parent: Instance, view: any)
	local self = setmetatable({}, FxLayer) :: any
	local root = Instance.new("Frame")
	root.Name = "Fx"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = FxLayer.Z
	root.Parent = parent
	self.root = root
	self.view = view
	self._state = nil :: any
	self._fx = {} :: { Fx }
	self._frames = {} :: { Frame }
	self._pops = {} :: { Pop }
	self._pop_gui = {} :: { PopGui }
	self._bursts = {} :: { Burst }
	self._burst_gui = {} :: { ImageLabel }
	self._debris = {} :: { Burst }
	self._debris_gui = {} :: { ImageLabel }
	--- a strike's warheads: those landed lately (times) and in flight (counted once a frame)
	self._warheads_landed = {} :: { number }
	self._warheads_flying = 0
	self._warheads_counted = -1.0
	self._bonus = {} :: { Bonus }
	self._bonus_gui = {} :: { BonusGui }
	-- Fetch the fx atlases now: a cold download outlasts the 2.5 s conquest popup.
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ Sprites.fx.id, MapFx.id })
		end)
	end)
	return self
end

function FxLayer.bind(self: any, state: any)
	self._state = state
	table.clear(self._fx)
	table.clear(self._pops)
	table.clear(self._bursts)
	table.clear(self._debris)
	table.clear(self._warheads_landed)
	table.clear(self._bonus)
end

function FxLayer.unbind(self: any)
	self._state = nil
	table.clear(self._fx)
	table.clear(self._pops)
	table.clear(self._bursts)
	table.clear(self._debris)
	table.clear(self._warheads_landed)
	table.clear(self._bonus)
	for _, f in self._frames do
		f.Visible = false
	end
	for _, g in self._bonus_gui do
		g.label.Visible = false
	end
	for _, g in self._burst_gui do
		g.Visible = false
	end
	for _, g in self._debris_gui do
		g.Visible = false
	end
	for _, g in self._pop_gui do
		g.flag.Visible = false
		g.banner.Visible = false
		g.gold.Visible = false
	end
end

function FxLayer.destroy(self: any)
	self:unbind()
	self.root:Destroy()
end

local function add(self: any, tile: number, r0: number, r1: number, dur: number, col: Color3, flash: boolean)
	local st = self._state
	if st == nil or tile < 0 then
		return
	end
	local W = st.map.W or Defs.W
	table.insert(self._fx, {
		u = tile % W + 0.5,
		v = tile // W + 0.5,
		r0 = r0,
		r1 = r1,
		t0 = FrameClock.now(),
		dur = dur,
		col = col,
		flash = flash,
	})
end

--- 32-bit multiply, low 32 bits (Math.imul, unsigned)
local function imul(a: number, b: number): number
	local ah, al = a // 65536, a % 65536
	return ((ah * b) % 65536 * 65536 + al * b) % 4294967296
end

--- mulberry32: a float in [0, 1) from an integer seed.
function FxLayer.seeded_random(seed: number): number
	local s = (seed + 0x6d2b79f5) % 4294967296
	local t = imul(bit32.bxor(s, bit32.rshift(s, 15)), bit32.bor(1, s))
	t = bit32.bxor((t + imul(bit32.bxor(t, bit32.rshift(t, 7)), bit32.bor(61, t))) % 4294967296, t)
	return bit32.bxor(t, bit32.rshift(t, 14)) / 4294967296
end

--- The debris a nuke leaves: map positions (offsets from the tile in full-size tiles, divided
--- by k) and sprites, for a nuke of look radius `radius` (full-size tiles) at `tile`.
function FxLayer.debris_plan(tile: number, radius: number, k: number): { { kind: string, du: number, dv: number } }
	local out = {}
	local idx = 0
	for _, d in FxLayer.DEBRIS_PLAN do
		local count = math.max(0, math.floor(radius * d.density))
		local r = radius * d.factor
		for _ = 1, count do
			local seed = tile * 997 + idx
			idx += 1
			local angle = FxLayer.seeded_random(seed) * math.pi * 2
			local dist = FxLayer.seeded_random(seed + 0x10000) * (r / 2)
			-- (Math.floor of the offsets in full-size tiles)
			table.insert(out, {
				kind = d.kind,
				du = math.floor(math.cos(angle) * dist) / k,
				dv = math.floor(math.sin(angle) * dist) / k,
			})
		end
	end
	return out
end

--- Whether this warhead leaves debris: about WARHEAD_DEBRIS of a strike's do, picked by its tile.
function FxLayer._warhead_debris(self: any, tile: number): boolean
	local st = self._state
	local now = FrameClock.now()
	local landed = self._warheads_landed
	while #landed > 0 and now - landed[1] > FxLayer.WARHEAD_WINDOW_S do
		table.remove(landed, 1)
	end
	table.insert(landed, now)
	if self._warheads_counted ~= now then
		self._warheads_counted = now
		local n = 0
		for _, m in st.nukes do
			if m.kind == Defs.N_WARHEAD then
				n += 1
			end
		end
		self._warheads_flying = n
	end
	local p = FxLayer.WARHEAD_DEBRIS / math.max(1, #landed + self._warheads_flying)
	return FxLayer.seeded_random(tile * 31 + 7) < p
end

--- GameState.nuke_detonated(uid, kind, tile, radius, owner).
function FxLayer.nuke(self: any, kind: number, tile: number, radius: number)
	-- a MIRV splitting into its warheads: nothing (no look radius of its own; a
	-- flash its spread wide whitened the screen)
	if kind == Defs.N_MIRV then
		return
	end
	local r = radius
	local VR = self.view.view_rules
	if VR then
		local _, outer = VR.nuke_radii(kind)
		if outer > 0 then
			r = outer
		end
	end
	-- a strike (a shell, an air strike, a slug; Data/Arsenal) is a small burst: no flash, no shake
	-- for a shell, a nudge for the others
	if Rules.NUKE_FLAT ~= nil and Rules.NUKE_FLAT[kind] then
		local col = if kind == Defs.N_SLUG then Color3.new(0.75, 0.6, 1) else Color3.new(1, 0.72, 0.35)
		add(self, tile, 0, math.max(r, 2.5) * 1.15, if kind == Defs.N_SHELL then 0.45 else 0.8, col, false)
		if kind ~= Defs.N_SHELL then
			local cam = self.view.rig
			local x, y = cam:tile_to_screen(tile)
			if cam:on_screen(x, y, 200) then
				cam:add_shake(0.25)
			end
		end
		return
	end
	local st = self._state
	local k = tonumber(st and st.map and st.map.k_lin) or Rules.K_LIN
	local look = FxLayer.NUKE_FX_RADIUS[kind]
	-- (a warhead's ring without the flash: 350 flashes a look radius
	-- wide whiten the screen)
	add(
		self,
		tile,
		0,
		(if look then look / k else r) * FxLayer.NUKE_SHOCK_K,
		FxLayer.NUKE_SHOCK_S,
		Color3.new(1, 0.92, 0.75),
		kind ~= Defs.N_WARHEAD
	)
	if st ~= nil and look ~= nil and tile >= 0 then
		local W = st.map.W or Defs.W
		local u, v = tile % W + 0.5, tile // W + 0.5
		self:burst("nuke", u, v)
		if kind ~= Defs.N_WARHEAD or self:_warhead_debris(tile) then
			local now = FrameClock.now()
			for _, d in FxLayer.debris_plan(tile, look, k) do
				if #self._debris >= FxLayer.DEBRIS_MAX then
					break
				end
				table.insert(self._debris, {
					u = u + d.du,
					v = v + d.dv,
					t0 = now,
					row = FxLayer.BURSTS[d.kind],
					life = FxLayer.DEBRIS_S,
					fade_in = FxLayer.DEBRIS_FADE_IN,
					fade_out = FxLayer.DEBRIS_FADE_OUT,
				})
			end
		end
	end
	local cam = self.view.rig
	local x, y = cam:tile_to_screen(tile)
	if cam:on_screen(x, y, 200) then
		cam:add_shake(if kind == Defs.N_HYDROGEN or kind == Defs.N_MEGA then 0.9 else 0.5)
	end
end

--- A ship destroyed / a nuke shot down at `tile`.
function FxLayer.pop(self: any, tile: number, col: Color3?)
	local st = self._state
	local k = tonumber(st and st.map and st.map.k_lin) or Rules.K_LIN
	add(self, tile, 0, FxLayer.POP_RADIUS / k * 0.25, FxLayer.POP_S, col or Color3.new(1, 0.6, 0.25), false)
end

--- An explosion sprite (BURSTS) at map position (u, v) (tile + 0.5 is the tile's centre).
function FxLayer.burst(self: any, kind: string, u: number, v: number)
	local row = FxLayer.BURSTS[kind]
	if self._state == nil or row == nil or #self._bursts >= FxLayer.BURST_MAX then
		return
	end
	table.insert(self._bursts, { u = u, v = v, t0 = FrameClock.now(), row = row })
end

--- GameState.structure_removed (the structure is still in the state): the ones a capture destroys go
--- up in a small explosion (Sim._struct_tile_changed: a defense post, the Arsenal's structures).
function FxLayer.on_structure_removed(self: any, sid: number)
	local st = self._state
	local s = if st ~= nil then st.structures[sid] else nil
	if s == nil or not (s.kind == Defs.S_DEFENSE or s.kind >= Defs.S_ARTILLERY) then
		return
	end
	local W = st.map.W or Defs.W
	local k = tonumber(st.map.k_lin) or Rules.K_LIN
	self:burst("building", s.tile % W + 0.5, s.tile // W + 0.5)
	add(self, s.tile, 0, 14 / k, 0.5, Color3.new(1, 0.7, 0.3), false)
end

--- Gold as a popup shows it: one decimal K / M (halves round up), whole numbers
--- below 1,000.
function FxLayer.format_gold(gold: number): string
	local function fixed1(v: number): string
		return string.format("%.1f", math.floor(v * 10 + 0.5) / 10)
	end
	if gold >= 1_000_000 then
		return fixed1(gold / 1_000_000) .. "M"
	elseif gold >= 1_000 then
		return fixed1(gold / 1_000) .. "K"
	end
	return tostring(math.floor(gold))
end

--- The local player conquered someone whose name sat at map tile (u, v) and took `gold`.
--- The banner's tint for an owner's colour: the colour, lightened when it is too dark to show.
function FxLayer.banner_color(c: any): Color3
	if typeof(c) ~= "Color3" then
		return Color3.new(1, 1, 1)
	end
	local luma = c.R * 0.299 + c.G * 0.587 + c.B * 0.114
	return if luma < FxLayer.BANNER_MIN_LUMA then c:Lerp(Color3.new(1, 1, 1), FxLayer.BANNER_LIFT) else c
end

function FxLayer.conquest(self: any, u: number, v: number, gold: number)
	if self._state == nil then
		return
	end
	table.insert(self._pops, {
		u = u,
		v = v,
		t0 = FrameClock.now(),
		text = "+ " .. FxLayer.format_gold(gold),
		col = FxLayer.banner_color(self._state:owner_color(self._state.local_owner)),
	})
end

--- The local player earned `gold` at `tile` (GameState.bonus: a train of theirs stopped at a station,
--- or someone's train at a station of theirs).
function FxLayer.bonus(self: any, tile: number, gold: number)
	local st = self._state
	if st == nil or tile < 0 or gold <= 0 then
		return
	end
	local W = st.map.W or Defs.W
	local list = self._bonus
	if #list >= FxLayer.BONUS_MAX then
		table.remove(list, 1)
	end
	table.insert(list, {
		u = tile % W + 0.5,
		v = tile // W + 0.5,
		t0 = FrameClock.now(),
		text = "+ " .. FxLayer.format_gold(gold),
	})
end

local function bonus_step(self: any, cam: any, now: number)
	local st = self._state
	local k = tonumber(st and st.map and st.map.k_lin) or Rules.K_LIN
	local zoom = cam.scale / k -- px per full-size tile
	local n = 0
	local i = 1
	local list = self._bonus
	while i <= #list do
		local b = list[i]
		local el = now - b.t0
		if el >= FxLayer.BONUS_S then
			table.remove(list, i)
			continue
		end
		i += 1
		if zoom < FxLayer.BONUS_CULL_ZOOM then
			continue
		end
		local fs = math.clamp(FxLayer.BONUS_SIZE * zoom, FxLayer.BONUS_MIN_PX, FxLayer.BONUS_MAX_PX)
		-- (offset and rise are in tiles; under the minimum size they keep pace with the text)
		local unit = fs / FxLayer.BONUS_SIZE
		local x, y = cam:map_to_screen(b.u, b.v)
		y += (FxLayer.BONUS_Y_OFFSET - FxLayer.BONUS_RISE * el) * unit
		if not cam:on_screen(x, y, fs * 4) then
			continue
		end
		n += 1
		local g = self._bonus_gui[n]
		if g == nil then
			local label = Instance.new("TextLabel")
			label.Name = "Income"
			label.BackgroundTransparency = 1
			label.AnchorPoint = Vector2.new(0.5, 0.5)
			label.AutomaticSize = Enum.AutomaticSize.XY
			label.Size = UDim2.fromOffset(0, 0)
			label.FontFace = FxLayer.GOLD_FONT
			label.TextColor3 = Color3.new(1, 1, 1)
			label.ZIndex = FxLayer.Z + 1
			label.Parent = self.root
			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.new(0, 0, 0)
			stroke.LineJoinMode = Enum.LineJoinMode.Round
			stroke.Parent = label
			g = { label = label, stroke = stroke }
			self._bonus_gui[n] = g
		end
		local t = el / FxLayer.BONUS_S
		local label = g.label
		label.Visible = true
		label.Text = b.text
		label.TextSize = fs
		label.Position = UDim2.fromOffset(x, y)
		label.TextTransparency = t
		g.stroke.Thickness = math.max(1.5, fs * 0.12)
		g.stroke.Transparency = t
	end
	for j = n + 1, #self._bonus_gui do
		local g = self._bonus_gui[j]
		if g.label.Visible then
			g.label.Visible = false
		end
	end
end

local function pop_gui(self: any, n: number): PopGui
	local g = self._pop_gui[n]
	if g ~= nil then
		return g
	end
	-- (the cloth and the flag never share a pixel: their order doesn't matter)
	local function layer(name: string, row: any): ImageLabel
		local l = Instance.new("ImageLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0.5, 0.5)
		l.Image = MapFx.id
		l.ImageRectSize = Vector2.new(row.w, row.h)
		l.ResampleMode = Enum.ResamplerMode.Pixelated
		l.ZIndex = FxLayer.Z
		l.Parent = self.root
		return l
	end
	local banner = layer("ConquestBanner", FxLayer.BANNER)
	local flag = layer("Conquest", FxLayer.FLAG)
	local gold = Instance.new("TextLabel")
	gold.Name = "ConquestGold"
	gold.BackgroundTransparency = 1
	gold.AnchorPoint = Vector2.new(0.5, 0.5)
	gold.AutomaticSize = Enum.AutomaticSize.XY
	gold.Size = UDim2.fromOffset(0, 0)
	gold.FontFace = FxLayer.GOLD_FONT
	gold.TextColor3 = Color3.new(1, 1, 1)
	gold.ZIndex = FxLayer.Z + 1
	gold.Parent = self.root
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = gold
	g = { flag = flag, banner = banner, gold = gold, stroke = stroke }
	self._pop_gui[n] = g
	return g
end

local function pops_step(self: any, cam: any, now: number)
	local st = self._state
	local k = tonumber(st and st.map and st.map.k_lin) or Rules.K_LIN
	local n = 0
	local i = 1
	while i <= #self._pops do
		local p = self._pops[i]
		local el = now - p.t0
		if el >= FxLayer.CONQUEST_S then
			table.remove(self._pops, i)
			continue
		end
		i += 1
		local x, y = cam:map_to_screen(p.u, p.v)
		local sw = math.max(FxLayer.FLAG_MIN_PX, FxLayer.FLAG_WORLD / k * cam.scale)
		if not cam:on_screen(x, y, sw * 2) then
			continue
		end
		n += 1
		local g = pop_gui(self, n)
		local t = el / FxLayer.CONQUEST_S
		local a = 1.0
		if t < FxLayer.CONQUEST_FADE_IN then
			a = t / FxLayer.CONQUEST_FADE_IN
		elseif t > FxLayer.CONQUEST_FADE_OUT then
			a = (1 - t) / (1 - FxLayer.CONQUEST_FADE_OUT)
		end
		local F, B = FxLayer.FLAG, FxLayer.BANNER
		local frame = math.min(math.floor(el / FxLayer.FLAG_FRAME_S), F.frames - 1)
		local size = UDim2.fromOffset(sw, sw * F.h / F.w)
		for _, l in { g.flag, g.banner } do
			l.Visible = true
			l.Position = UDim2.fromOffset(x, y)
			l.Size = size
			l.ImageTransparency = 1 - a
		end
		g.flag.ImageRectOffset = Vector2.new(F.x + frame * F.w, F.y)
		g.banner.ImageRectOffset = Vector2.new(B.x + frame * B.w, B.y)
		g.banner.ImageColor3 = p.col
		local fs = math.max(FxLayer.GOLD_MIN_PX, FxLayer.GOLD_SIZE / k * cam.scale)
		-- GOLD_Y_OFFSET's 8 tiles scaled with the flag; its mound ends 0.42 of the sprite below its
		-- centre, so the line never overlaps it when the minimum sizes apply
		local gy = math.max(sw * FxLayer.GOLD_Y_OFFSET / FxLayer.FLAG_WORLD, sw * 0.42 + fs * 0.5)
		local gold = g.gold
		gold.Visible = true
		gold.Text = p.text
		gold.TextSize = math.min(fs, 100)
		gold.Position = UDim2.fromOffset(x, y + gy)
		gold.TextTransparency = t
		g.stroke.Thickness = math.max(1.5, fs * 0.12)
		g.stroke.Transparency = t
	end
	for j = n + 1, #self._pop_gui do
		local g = self._pop_gui[j]
		if g.flag.Visible then
			g.flag.Visible = false
			g.banner.Visible = false
			g.gold.Visible = false
		end
	end
end

--- Draw a list of bursts (or debris) with its pool; a looping one runs until its `life`, fading.
local function bursts_step(self: any, cam: any, now: number, list: { Burst }, pool: { ImageLabel }, z: number)
	local st = self._state
	local k = tonumber(st and st.map and st.map.k_lin) or Rules.K_LIN
	local n = 0
	local i = 1
	while i <= #list do
		local b = list[i]
		local row = b.row
		local el = now - b.t0
		local frame = math.floor(el / row.frame_s)
		local a = 1.0
		if b.life ~= nil then
			if el >= b.life then
				table.remove(list, i)
				continue
			end
			if row.loop then
				frame %= row.frames
			end
			local t = el / b.life
			if t < (b.fade_in or 0) then
				a = t / b.fade_in
			elseif t > (b.fade_out or 1) then
				a = (1 - t) / (1 - b.fade_out)
			end
		elseif frame >= row.frames then
			table.remove(list, i)
			continue
		end
		i += 1
		local x, y = cam:map_to_screen(b.u, b.v)
		local w = math.max(row.min_px, row.world / k * cam.scale)
		if not cam:on_screen(x, y, w) then
			continue
		end
		n += 1
		local g = pool[n]
		if g == nil then
			g = Instance.new("ImageLabel")
			g.Name = "Explosion"
			g.BackgroundTransparency = 1
			g.AnchorPoint = Vector2.new(0.5, 0.5)
			g.ResampleMode = Enum.ResamplerMode.Pixelated
			g.ZIndex = z
			g.Parent = self.root
			pool[n] = g
		end
		local image = row.image or Sprites.fx.id
		if g.Image ~= image then
			g.Image = image
		end
		g.Visible = true
		g.Position = UDim2.fromOffset(x, y)
		g.Size = UDim2.fromOffset(w, w * row.h / row.w)
		g.ImageRectSize = Vector2.new(row.w, row.h)
		g.ImageRectOffset = Vector2.new((row.x or 0) + frame * row.w, row.y)
		g.ImageTransparency = 1 - a
	end
	for j = n + 1, #pool do
		local g = pool[j]
		if g.Visible then
			g.Visible = false
		end
	end
end

function FxLayer.tick(self: any, _dt: number)
	local cam = self.view.rig
	local now = FrameClock.now()
	local n = 0
	local i = 1
	while i <= #self._fx do
		local fx = self._fx[i]
		local t = (now - fx.t0) / fx.dur
		if t >= 1 then
			table.remove(self._fx, i)
			continue
		end
		i += 1
		local x, y = cam:map_to_screen(fx.u, fx.v)
		local e = 1 - (1 - t) ^ 3
		local r = (fx.r0 + (fx.r1 - fx.r0) * e) * cam.scale
		if not cam:on_screen(x, y, r) then
			continue
		end
		n += 1
		local f = self._frames[n]
		if f == nil then
			f = Instance.new("Frame")
			f.Name = "Fx"
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.BorderSizePixel = 0
			f.ZIndex = FxLayer.Z
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0.5, 0)
			c.Parent = f
			local s = Instance.new("UIStroke")
			s.Parent = f
			f.Parent = self.root
			self._frames[n] = f
		end
		f.Visible = true
		f.Position = UDim2.fromOffset(x, y)
		f.Size = UDim2.fromOffset(r * 2, r * 2)
		f.BackgroundColor3 = fx.col
		-- the flash fills the disc early on; the ring stays
		f.BackgroundTransparency = if fx.flash then math.clamp(0.25 + t * 3, 0, 1) else 0.8 + 0.2 * t
		local s = f:FindFirstChildOfClass("UIStroke") :: UIStroke
		s.Color = fx.col
		s.Thickness = math.max(1.5, r * 0.04)
		s.Transparency = t
	end
	for j = n + 1, #self._frames do
		local f = self._frames[j]
		if f.Visible then
			f.Visible = false
		end
	end
	pops_step(self, cam, now)
	bursts_step(self, cam, now, self._bursts, self._burst_gui, FxLayer.Z + 1)
	-- (the debris over the fireball, pushed after it)
	bursts_step(self, cam, now, self._debris, self._debris_gui, FxLayer.Z + 2)
	bonus_step(self, cam, now)
end

return FxLayer
