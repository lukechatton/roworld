--!nonstrict
-- Opening a cosmetic crate: a Clash Royale-style show around a 3D chest (2026-09-29: the first version
-- of opening a crate was not satisfying at all, and it should be super fun; the show was then made
-- 3D, around a ready-made voxel chest).
-- The chest is BedWars' voxel block chest (Assets/CrateModel) in a
-- ViewportFrame; the choreography follows Tribes' drop reveal (the same studio's game).
--   land    the screen dims; the chest falls in stretched past air streaks, lands with a squash, dust,
--           a floor ring and a shake; the title slams in;
--   idle    it bobs; every WIGGLE_EVERY_S it wiggles with a rattle, the lid cracks and light leaks out;
--           "TAP TO OPEN". It never opens by itself (no auto-open: the player has to click or tap
--           it open);
--   build   tapped: distinct rattles, closer together and bigger, while the light turns the item's
--           rarity colour and BedWars' lucky box preview for that rarity plays; the rarer the item, the
--           longer the build (BUILD_S; Epic and Legendary tease with rays); a roll still on its way
--           keeps it rattling (the network wait hides in there);
--   burst   a crouch, then the lid bursts open: a flash in the rarity colour, rays, a light beam and
--           sparks out of the chest, a shockwave ring, a shake;
--   card    the card flies out of the chest face down while the chest steps down; it glows in its
--           rarity colour (CARD_HOLD_S: longer for the rarer ones, a tap hurries it), then flips: the
--           item, NEW!, the rarity, the name, the rarity's sound;
--   choose  WEAR IT · OPEN ANOTHER (a waiting crate, or the next one's price) · DONE.
-- Nothing clips to white: flashes are the rarity colour at part strength.
-- Locker drives it: play(info) as the crate is opened, resolve(item_id) / fail(text) from the server.
-- Signals: wear(item_id), again(), closed(fail_text?), shown(open). `pace` > 1 slows the whole show
-- (frame captures).
local UITheme = require("./UITheme")
local W = require("./Widgets")
local ChestView = require("./ChestView")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local Airfront: any = if IS_ROBLOX then (game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront") else nil
local Cosmetics: any = if IS_ROBLOX then require(Airfront.Data.Cosmetics) else (require :: any)("../../shared/Data/Cosmetics")
local Model: any = ChestView.Model
local TweenService = if IS_ROBLOX then game:GetService("TweenService") else nil
local RunService = if IS_ROBLOX then game:GetService("RunService") else nil
local UserInputService = if IS_ROBLOX then game:GetService("UserInputService") else nil

local CrateOpening = W.class(W.Control)

CrateOpening.FALL_S = 0.42
CrateOpening.SETTLE_S = 0.45
CrateOpening.WIGGLE_EVERY_S = 1.1
CrateOpening.BUILD_S = { common = 0.55, rare = 0.8, epic = 1.15, legendary = 1.7 }
--- a build-up rattle's length, and the gap before the next (at the start .. at the end of the build)
CrateOpening.JOLT_S = 0.26
CrateOpening.JOLT_GAP_S = { 0.22, 0.04 }
CrateOpening.CARD_HOLD_S = { common = 0.2, rare = 0.35, epic = 0.6, legendary = 1.0 }
CrateOpening.RESULT_WAIT_S = 12.0
CrateOpening.BURST = { common = 18, rare = 26, epic = 36, legendary = 54 }
CrateOpening.MAX_PARTICLES = 150

local VIEW_K = 1.1 -- the viewport's side, in stage units (S)

-- the chest's own light before the roll shows through
local GOLD = Color3.fromRGB(255, 190, 72)
local GOLD_LIGHT = Color3.fromRGB(255, 226, 150)
local AMBIENT = ChestView.AMBIENT

local FONT_B = Font.fromId(12187365977, Enum.FontWeight.Heavy)
local FONT_M = Font.fromId(12187365977, Enum.FontWeight.Bold)

local function c3(hex: number): Color3
	return Color3.fromRGB((hex // 65536) % 256, (hex // 256) % 256, hex % 256)
end

local function tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	if TweenService == nil then
		return
	end
	TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
		:Play()
end

local function new(class: string, props: { [string]: any }, parent: Instance?): any
	local i = Instance.new(class)
	for k, v in props do
		(i :: any)[k] = v
	end
	if parent then
		i.Parent = parent
	end
	return i
end

local EASE = {
	linear = function(k: number): number
		return k
	end,
	outQuad = function(k: number): number
		return 1 - (1 - k) * (1 - k)
	end,
	inQuad = function(k: number): number
		return k * k
	end,
	inOutSine = function(k: number): number
		return -(math.cos(math.pi * k) - 1) / 2
	end,
	outBack = function(k: number): number
		local c1 = 1.70158
		return 1 + (c1 + 1) * (k - 1) ^ 3 + c1 * (k - 1) ^ 2
	end,
}

local v3 = ChestView.v3

local function place(g: GuiObject, at: Vector2)
	g.Position = UDim2.fromOffset(at.X, at.Y)
end

function CrateOpening.new(c: any)
	local self = setmetatable({}, CrateOpening.__mt)
	W.Control._init(self)
	self.ctx = c
	self.wear = Signal.new()
	self.again = Signal.new()
	self.closed = Signal.new()
	self.shown = Signal.new() -- (open: boolean) the show starts / ends (the top bar row hides)
	self.is_open = false
	self.pace = 1.0
	self._gen = 0
	self._phase = "off"
	self._item = nil
	self._particles = {}
	self._anims = {}
	-- the chest pose: y (studs), yaw / roll / pitch (radians), sq (squash, + = flat), s (scale), lid
	-- (degrees); hy (the viewport's centre below the stage centre, in S), hs (its scale)
	self._P = { y = 0, yaw = 0, roll = 0, pitch = 0, sq = 0, s = 1, lid = 0, hy = 0, hs = 1 }
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self:_build()
	return self
end

-- ---------------------------------------------------------------------------------------------
-- Build (once)
-- ---------------------------------------------------------------------------------------------

function CrateOpening._build(self)
	local art = UITheme.crate_art()
	local root = self.gui
	-- everything moves together (the screen shake). ZIndex 1: under the kit's buttons row (the kit
	-- numbers its children from 11); the stage's own layers order among themselves
	local stage = new("Frame", { Name = "Stage", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 1 }, root)
	self._stage = stage
	local function layer(name: string, z: number): Frame
		return new("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z }, stage)
	end
	local function img(name: string, image: string, z: number, parent: Instance?, props: any?): ImageLabel
		local p = props or {}
		p.Name = name
		p.BackgroundTransparency = 1
		p.Image = image or ""
		p.ImageTransparency = if p.ImageTransparency ~= nil then p.ImageTransparency else 1
		p.AnchorPoint = p.AnchorPoint or Vector2.new(0.5, 0.5)
		p.ZIndex = z
		return new("ImageLabel", p, parent or stage)
	end
	-- the backdrop: a deep blue, nearly opaque (the chest is the only thing on screen)
	self._dim = new("Frame", {
		Name = "Dim",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(2, 2),
		Position = UDim2.fromScale(-0.5, -0.5),
		ZIndex = 1,
	}, stage)
	new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(4, 6, 18)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(22, 32, 84)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(4, 6, 18)),
		}),
		Rotation = 90,
	}, self._dim)
	-- a wash of the rarity colour behind everything (after the burst)
	self._tint = img("Tint", art.glow, 2)
	-- rays (two counter-rotating layers) + a halo
	local rays = new("Frame", { Name = "Rays", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 3 }, stage)
	self._rays = rays
	self._rays_scale = new("UIScale", {}, rays)
	self._rays_a = img("RaysA", art.rays, 3, rays, { Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1) })
	self._rays_b = img("RaysB", art.rays, 3, rays, { Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1.25, 1.25) })
	-- a Legendary's rays shimmer through the rainbow
	self._rays_grad = new("UIGradient", { Enabled = false }, self._rays_a)
	self._halo = img("Halo", art.glow, 3, rays, { Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6) })
	self._back_fx = layer("BackFx", 4)
	-- the chest: its floor shadow, a floor ring, the light beam, its glow, the viewport, the leak
	self._shadow = img("Shadow", art.glow, 5, nil, { ImageColor3 = Color3.new(0, 0, 0) })
	self._floor_ring = img("FloorRing", art.ring, 5)
	self._beam = img("Beam", art.beam, 6, nil, { AnchorPoint = Vector2.new(0.5, 1) })
	self._chest_glow = img("ChestGlow", art.glow, 6)
	local holder = new("Frame", { Name = "Chest", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 7 }, stage)
	self._holder = holder
	self._holder_scale = new("UIScale", {}, holder)
	local vpf = new("ViewportFrame", { Name = "View", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 7 }, holder)
	self._vpf = vpf
	self._chest = ChestView.build(vpf)
	-- light out of the open chest, and out of the lid's seam while it cracks (in front of the viewport)
	self._mouth_glow = img("MouthGlow", art.glow, 8)
	self._leak = img("Leak", art.glow, 8)
	self._leak_flare = img("LeakFlare", art.flare, 8)
	-- the card's glow (behind the card)
	self._card_glow = img("CardGlow", art.glow, 9)
	-- the card: a back (the crate's emblem) and a front (the item)
	local card = new("Frame", {
		Name = "Card",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 10,
	}, stage)
	self._card = card
	self._card_scale = new("UIScale", {}, card)
	-- (a UIGradient multiplies the frame's colour: the faces are white under their gradients)
	local back = new("Frame", {
		Name = "Back",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
	}, card)
	new("UICorner", { CornerRadius = UDim.new(0.08, 0) }, back)
	self._back_stroke = new("UIStroke", { Color = Color3.fromRGB(242, 190, 75), Thickness = 4 }, back)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(62, 80, 176), Color3.fromRGB(20, 26, 70)),
		Rotation = 90,
	}, back)
	new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = art.icon or "",
		ImageColor3 = Color3.fromRGB(255, 214, 110),
		ScaleType = Enum.ScaleType.Fit,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.55, 0.55),
		ZIndex = 11,
	}, back)
	self._back = back
	local front = new("Frame", {
		Name = "Front",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ClipsDescendants = true,
		ZIndex = 10,
	}, card)
	new("UICorner", { CornerRadius = UDim.new(0.08, 0) }, front)
	self._front_stroke = new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 4 }, front)
	self._front_grad = new("UIGradient", { Rotation = 90 }, front)
	self._front = front
	self._preview = new("ImageLabel", {
		Name = "Preview",
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.7),
		ZIndex = 11,
	}, front)
	-- a moving shine over the front (Epic, Legendary): a gradient band swept by its offset (a rotated
	-- frame would not be clipped)
	self._shine = new("Frame", {
		Name = "Shine",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 12,
	}, front)
	new("UICorner", { CornerRadius = UDim.new(0.08, 0) }, self._shine)
	self._shine_grad = new("UIGradient", {
		Rotation = 20,
		Offset = Vector2.new(-1, 0),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.42, 1),
			NumberSequenceKeypoint.new(0.5, 0.45),
			NumberSequenceKeypoint.new(0.58, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, self._shine)
	self._new = new("TextLabel", {
		Name = "New",
		BackgroundColor3 = Color3.fromRGB(235, 64, 64),
		Text = "NEW!",
		FontFace = FONT_B,
		TextColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.86, 0.04),
		Size = UDim2.fromScale(0.42, 0.13),
		TextScaled = true,
		Rotation = 12,
		Visible = false,
		ZIndex = 13,
	}, card)
	new("UICorner", { CornerRadius = UDim.new(0.3, 0) }, self._new)
	new("UIStroke", { Color = Color3.fromRGB(120, 20, 20), Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, self._new)
	new("UIPadding", {
		PaddingLeft = UDim.new(0.1, 0),
		PaddingRight = UDim.new(0.1, 0),
		PaddingTop = UDim.new(0.12, 0),
		PaddingBottom = UDim.new(0.12, 0),
	}, self._new)
	self._new_scale = new("UIScale", {}, self._new)
	local function label(name: string, font: Font, z: number): TextLabel
		local l = new("TextLabel", {
			Name = name,
			BackgroundTransparency = 1,
			Text = "",
			FontFace = font,
			TextColor3 = Color3.new(1, 1, 1),
			TextTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = z,
		}, stage)
		new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 1 }, l)
		return l
	end
	-- the title (slams in as the chest lands) and the words under the card
	self._title = label("Title", FONT_B, 14)
	self._title_scale = new("UIScale", {}, self._title)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 240, 200), Color3.fromRGB(255, 184, 60)),
		Rotation = 90,
	}, self._title)
	self._subtitle = label("Subtitle", FONT_M, 14)
	self._rarity = label("Rarity", FONT_B, 14)
	self._rarity_scale = new("UIScale", {}, self._rarity)
	self._name = label("ItemName", FONT_B, 14)
	self._kind = label("Kind", FONT_M, 14)
	-- "TAP TO OPEN" in a pill
	local hint = new("Frame", {
		Name = "Hint",
		BackgroundColor3 = Color3.fromRGB(12, 16, 36),
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 14,
	}, stage)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, hint)
	self._hint_stroke = new("UIStroke", { Color = GOLD, Thickness = 2, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, hint)
	self._hint_scale = new("UIScale", {}, hint)
	self._hint_text = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "TAP TO OPEN",
		FontFace = FONT_B,
		TextColor3 = Color3.new(1, 1, 1),
		TextTransparency = 1,
		TextScaled = true,
		ZIndex = 15,
	}, hint)
	new("UIPadding", {
		PaddingTop = UDim.new(0.24, 0),
		PaddingBottom = UDim.new(0.24, 0),
		PaddingLeft = UDim.new(0.1, 0),
		PaddingRight = UDim.new(0.1, 0),
	}, self._hint_text)
	self._hint = hint
	self._front_fx = layer("FrontFx", 16)
	self._flash = new("Frame", {
		Name = "Flash",
		BackgroundColor3 = GOLD_LIGHT,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(2, 2),
		Position = UDim2.fromScale(-0.5, -0.5),
		ZIndex = 17,
	}, stage)
	-- taps anywhere open the chest / hurry the card (the buttons row sits above the stage)
	self._catch = new("TextButton", {
		Name = "Tap",
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 18,
	}, stage)
	self._catch.Activated:Connect(function()
		self:_tap()
	end)
	-- the choice (kit buttons in a row, placed in _layout)
	local row = UITheme.hbox(10)
	row:set_alignment(W.ALIGN_CENTER)
	self._row = row
	self._wear_b = UITheme.button("WEAR IT", "PrimaryButton", "check", 48.0)
	self._wear_b.pressed:Connect(function()
		if self._item then
			self.wear:Fire(self._item)
		end
	end)
	row:add_child(self._wear_b)
	self._again_b = UITheme.button("OPEN ANOTHER", "GlassButton", "robux", 48.0)
	self._again_b.pressed:Connect(function()
		if self._phase == "choose" then
			self.again:Fire()
		end
	end)
	row:add_child(self._again_b)
	self._done_b = UITheme.button("DONE", "GlassButton", "", 48.0)
	self._done_b.pressed:Connect(function()
		self:close()
	end)
	row:add_child(self._done_b)
	row:set_visible(false)
	self:add_child(row)
end

-- ---------------------------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------------------------

--- The stage unit: the chest, the card and the words scale with it.
function CrateOpening._size(self): number
	local area = self.ctx:clear_rect()
	return math.min(area.Width * 0.7, area.Height * 0.64, 560)
end

-- (the stage's raw instances are sized in px: logical px x UITheme.scale; the kit's buttons row keeps
-- logical px)
function CrateOpening._layout(self)
	local u = UITheme.scale
	local area = self.ctx:clear_rect()
	local SL = self:_size()
	local S = SL * u
	local cx = (area.Min.X + area.Width * 0.5) * u
	local cy = (area.Min.Y + area.Height * 0.5) * u
	self._cx, self._cy, self._S = cx, cy, S
	--- a text size: S-relative, clamped in logical px
	local function ts(k: number, lo: number, hi: number): number
		return math.floor(math.clamp(SL * k, lo, hi) * u)
	end
	local V = S * VIEW_K
	self._V = V
	self._holder.Size = UDim2.fromOffset(V, V)
	self._rays.Size = UDim2.fromOffset(S * 2.2, S * 2.2)
	self._tint.Size = UDim2.fromOffset(S * 3.2, S * 2.4)
	self._tint.Position = UDim2.fromOffset(cx, cy)
	self._title.Size = UDim2.fromOffset(S * 2, S * 0.16)
	self._title.TextSize = ts(0.13, 24, 64)
	self._title.Position = UDim2.fromOffset(cx, cy - S * 0.64)
	self._subtitle.Size = UDim2.fromOffset(S * 2, S * 0.06)
	self._subtitle.TextSize = ts(0.042, 11, 20)
	self._subtitle.Position = UDim2.fromOffset(cx, cy - S * 0.53)
	local hw = math.clamp(SL * 0.5, 150, 240) * u
	self._hint.Size = UDim2.fromOffset(hw, hw * 0.2)
	self._hint.Position = UDim2.fromOffset(cx, cy + S * 0.6)
	-- the card and the words under it
	local cw, ch = S * 0.56, S * 0.74
	local card_y = cy - S * 0.17
	self._card.Size = UDim2.fromOffset(cw, ch)
	self._card_pos = UDim2.fromOffset(cx, card_y)
	self._card_glow.Size = UDim2.fromOffset(cw * 2.2, ch * 1.9)
	self._card_glow.Position = self._card_pos
	-- the words stack under the card by their real sizes (the phone sizes are floored)
	local y = card_y + ch * 0.5 + math.max(6 * u, S * 0.035)
	for _, e in { { self._rarity, 0.075, 15, 36 }, { self._name, 0.1, 20, 50 }, { self._kind, 0.04, 11, 18 } } do
		local l, size = e[1], ts(e[2], e[3], e[4])
		l.TextSize = size
		l.Size = UDim2.fromOffset(S * 1.6, size + 4)
		l.Position = UDim2.fromOffset(cx, y + size * 0.5)
		y += size + 3 * u
	end
	local compact = self.ctx.compact
	local bh = if compact then 42 else 48
	self._wear_b:set_min_size(Vector2.new(if compact then 128 else 165, bh))
	self._again_b:set_min_size(Vector2.new(if compact then 140 else 175, bh))
	self._done_b:set_min_size(Vector2.new(if compact then 96 else 120, bh))
	local rs = self._row:get_combined_minimum_size()
	local ry = math.min(area.Max.Y - rs.Y - 8, y / u + math.max(8, SL * 0.04))
	local rx = cx / u
	self._row:set_offsets(rx - rs.X * 0.5, ry, rx + rs.X * 0.5, ry + rs.Y)
	self._row:reset_size()
end

function CrateOpening.apply_layout(self)
	if self.is_open then
		self:_layout()
		if self._card.Visible and not self._card_flying then
			self._card.Position = self._card_pos
		end
		if self._phase == "card" or self._phase == "choose" then
			self._rays.Position = self._card_pos
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- The chest: pose, projection, keyframes
-- ---------------------------------------------------------------------------------------------

--- Tween a pose value through segments { {to, seconds, ease}, ... } (replaces what it was doing).
function CrateOpening._animate(self, key: string, segs: { any })
	local list = {}
	for _, s in segs do
		table.insert(list, { to = s[1], dur = s[2], ease = EASE[s[3] or "outQuad"] or EASE.outQuad, t = 0.0 })
	end
	self._anims[key] = list
end

function CrateOpening._step_anims(self, dt: number)
	local P = self._P
	for key, list in self._anims do
		local seg = list[1]
		if seg.from == nil then
			seg.from = P[key]
		end
		seg.t += dt
		local k = math.min(1, seg.t / math.max(seg.dur, 1e-3))
		P[key] = seg.from + (seg.to - seg.from) * seg.ease(k)
		if k >= 1 then
			table.remove(list, 1)
			if #list == 0 then
				self._anims[key] = nil
			end
		end
	end
end

--- Place the chest from the pose (the viewport rides P.hy / P.hs).
function CrateOpening._apply_pose(self)
	local P = self._P
	self._holder.Position = UDim2.fromOffset(self._cx, self._cy + P.hy * (self._S or 300))
	self._holder_scale.Scale = P.hs
	ChestView.pose(self._chest, P)
end

--- Stage px of a chest point (studs, chest space) in the current pose.
function CrateOpening._project(self, p: Vector3): Vector2
	local P = self._P
	local v = ChestView.project(P, p, (self._V or 300) * P.hs)
	return Vector2.new(self._cx + v.X, self._cy + P.hy * (self._S or 300) + v.Y)
end

-- ---------------------------------------------------------------------------------------------
-- The show
-- ---------------------------------------------------------------------------------------------

--- Start a crate: the chest drops in. `info` = { crates, price, can_more, wearing } (the next offer).
function CrateOpening.play(self, info: any)
	self._gen += 1
	local gen = self._gen
	self._info = info or {}
	self._item = nil
	self._rar = nil
	self._fail = nil
	self._tapped = false
	self._hurry = false
	self._card_flying = false
	self._falling = false
	self._idle_st, self._build_st, self._card_hold = nil, nil, nil
	local was_open = self.is_open
	self.is_open = true
	self:set_visible(true)
	if not was_open then
		self.shown:Fire(true)
	end
	self:_layout()
	self:_clear_particles()
	table.clear(self._anims)
	local P = self._P
	P.y, P.yaw, P.roll, P.pitch, P.sq, P.s, P.lid, P.hy, P.hs = 0, math.rad(-14), 0, 0, -0.18, 1, 0, -1.8, 1
	self._t = 0.0
	self._shake = 0.0
	self._rays_spin = 10
	self._light = GOLD_LIGHT
	self._stage.Position = UDim2.new()
	self._dim.BackgroundTransparency = 1
	tween(self._dim, 0.3, { BackgroundTransparency = 0 })
	self._tint.ImageTransparency = 1
	self._rays_a.ImageTransparency, self._rays_b.ImageTransparency, self._halo.ImageTransparency = 1, 1, 1
	self._rays_a.ImageColor3, self._rays_b.ImageColor3, self._halo.ImageColor3 = GOLD_LIGHT, GOLD, GOLD
	self._rays_grad.Enabled = false
	self._rays_scale.Scale = 1
	self._rays.Position = UDim2.fromOffset(self._cx, self._cy)
	for _, g in {
		self._shadow,
		self._floor_ring,
		self._beam,
		self._chest_glow,
		self._mouth_glow,
		self._leak,
		self._leak_flare,
		self._card_glow,
	} do
		g.ImageTransparency = 1
	end
	self._chest_glow.ImageColor3 = GOLD
	self._leak.ImageColor3, self._leak_flare.ImageColor3 = GOLD_LIGHT, GOLD_LIGHT
	self._vpf.ImageTransparency = 0
	self._vpf.Ambient = AMBIENT
	self._holder.Visible = true
	self._card.Visible = false
	self._card.Rotation = 0
	self._new.Visible = false
	self._shine.Visible = false
	self._back_stroke.Color = Color3.fromRGB(242, 190, 75)
	for _, l in { self._title, self._subtitle, self._rarity, self._name, self._kind } do
		l.TextTransparency = 1
		l:FindFirstChildOfClass("UIStroke").Transparency = 1
	end
	self._hint.BackgroundTransparency = 1
	self._hint_text.TextTransparency = 1
	self._hint_stroke.Transparency = 1
	self._row:set_visible(false)
	self._flash.BackgroundTransparency = 1
	self:_apply_pose()
	if self._conn == nil and RunService ~= nil then
		self._conn = RunService.RenderStepped:Connect(function(dt)
			self:_step(dt / math.max(self.pace, 0.05))
		end)
	end
	task.spawn(function()
		self:_run(gen)
	end)
end

--- The server's roll.
function CrateOpening.resolve(self, id: string)
	self._item = id
	local it = Cosmetics.item(id)
	if it then
		self._rar = Cosmetics.rarity(it.rarity)
	end
end

--- The crate couldn't be opened (the server said why): the show ends with a word.
function CrateOpening.fail(self, text: string)
	self._fail = text
	self:close()
end

function CrateOpening._tap(self)
	local ph = self._phase
	if ph == "land" or ph == "idle" then
		self._tapped = true
	elseif ph == "card" then
		self._hurry = true
	end
end

--- Wait `t` show-seconds; false once the show was replaced or closed. `hurry`: a tap ends it early.
function CrateOpening._sleep(self, gen: number, t: number, hurry: boolean?): boolean
	local left = t
	while left > 0 do
		if gen ~= self._gen then
			return false
		end
		if hurry and self._hurry then
			self._hurry = false
			return true
		end
		left -= task.wait() / math.max(self.pace, 0.05)
	end
	return gen == self._gen
end

function CrateOpening._run(self, gen: number)
	if self:_land(gen) and self:_idle(gen) and self:_build_up(gen) and self:_burst(gen) and self:_card_out(gen) then
		self:_reveal(gen)
	end
end

function CrateOpening._land(self, gen: number): boolean
	local S = self._S
	self._phase = "land"
	-- it falls in stretched, turning to face you, past air streaks; its shadow grows
	self:_animate("hy", { { 0.04, CrateOpening.FALL_S, "inQuad" } })
	self:_animate("yaw", { { 0, CrateOpening.FALL_S + 0.25, "outQuad" } })
	self.ctx:sfx("crate_drop", -2)
	self._falling = true
	if not self:_sleep(gen, CrateOpening.FALL_S) then
		return false
	end
	self._falling = false
	-- impact: squash and spring, dust, sparks, a floor ring, a shake, the title
	self.ctx:sfx("crate_land", -3)
	self:_animate("sq", {
		{ 0.3, 0.06, "outQuad" },
		{ -0.12, 0.13, "inOutSine" },
		{ 0.05, 0.12, "inOutSine" },
		{ 0, 0.14, "outQuad" },
	})
	self:_kick(S * 0.04)
	local foot = self:_project(Vector3.new(0, 0, -Model.size[3] * 0.5))
	for _, side in { -1, 1 } do
		self:_emit(7, {
			x = foot.X + side * S * 0.24,
			y = foot.Y,
			jitter = 0.04,
			dir = if side < 0 then 180 else 0,
			spread = 14,
			vmin = 0.5,
			vmax = 1.3,
			kind = "dust",
			size = 0.13,
			grow = 1.6,
			drag = 3.2,
			grav = -0.12,
			life = { 0.5, 0.9 },
			base = 0.55,
			colors = { Color3.fromRGB(190, 176, 150) },
			front = true,
		})
	end
	self:_emit(9, {
		x = foot.X,
		y = foot.Y - S * 0.05,
		jitter = 0.25,
		dir = -90,
		spread = 70,
		vmin = 0.7,
		vmax = 1.6,
		size = 0.05,
		grav = 2.4,
		drag = 1.2,
		life = { 0.4, 0.75 },
		colors = { GOLD_LIGHT, GOLD },
		front = true,
	})
	place(self._floor_ring, self:_project(Vector3.zero))
	self._floor_ring.ImageColor3 = GOLD_LIGHT
	self._floor_ring.Size = UDim2.fromOffset(S * 0.4, S * 0.1)
	self._floor_ring.ImageTransparency = 0.25
	tween(self._floor_ring, 0.55, { Size = UDim2.fromOffset(S * 2.2, S * 0.5), ImageTransparency = 1 }, Enum.EasingStyle.Quart)
	self._rays.Position = UDim2.fromOffset(self._cx, self._cy)
	self._halo.Size = UDim2.fromScale(0.6, 0.6)
	tween(self._halo, 0.5, { ImageTransparency = 0.6 })
	tween(self._chest_glow, 0.5, { ImageTransparency = 0.6 })
	self:_title_in(gen)
	return self:_sleep(gen, CrateOpening.SETTLE_S)
end

function CrateOpening._title_in(self, gen: number)
	local S = self._S
	self._title.Text = "CRATE"
	self._subtitle.Text = "A SKIN OR FLAG · NEVER A DUPLICATE"
	self._title_scale.Scale = 1.8
	tween(self._title_scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(self._title, 0.12, { TextTransparency = 0 })
	tween(self._title:FindFirstChildOfClass("UIStroke"), 0.12, { Transparency = 0.1 })
	local p = UDim2.fromOffset(self._cx, self._cy - S * 0.53)
	self._subtitle.Position = p + UDim2.fromOffset(0, S * 0.03)
	task.delay(0.12, function()
		if gen == self._gen and self._phase ~= "burst" then
			tween(self._subtitle, 0.3, { TextTransparency = 0.1, Position = p }, Enum.EasingStyle.Quint)
			tween(self._subtitle:FindFirstChildOfClass("UIStroke"), 0.3, { Transparency = 0.4 })
		end
	end)
end

function CrateOpening._title_out(self)
	for _, l in { self._title, self._subtitle } do
		tween(l, 0.2, { TextTransparency = 1 })
		tween(l:FindFirstChildOfClass("UIStroke"), 0.2, { Transparency = 1 })
	end
end

function CrateOpening._idle(self, gen: number): boolean
	self._phase = "idle"
	self._idle_st = { t = 0.0, next = 0.3, wt = -1.0 }
	local touch = UserInputService ~= nil and UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	self._hint_text.Text = if touch then "TAP TO OPEN" else "CLICK TO OPEN"
	tween(self._hint, 0.25, { BackgroundTransparency = 0.25 })
	tween(self._hint_text, 0.25, { TextTransparency = 0 })
	tween(self._hint_stroke, 0.25, { Transparency = 0.2 })
	-- (a tap while it was landing opens it as soon as it has settled)
	while not self._tapped do
		if gen ~= self._gen then
			return false
		end
		task.wait()
	end
	self._idle_st = nil
	self:_animate("roll", { { 0, 0.08 } })
	self:_animate("yaw", { { 0, 0.08 } })
	self:_animate("lid", { { 0, 0.08 } })
	self:_animate("y", { { 0, 0.08 } })
	tween(self._hint, 0.15, { BackgroundTransparency = 1 })
	tween(self._hint_text, 0.15, { TextTransparency = 1 })
	tween(self._hint_stroke, 0.15, { Transparency = 1 })
	return true
end

function CrateOpening._build_up(self, gen: number): boolean
	self._phase = "build"
	table.clear(self._anims)
	local P = self._P
	self._build_st = { t = 0.0, k = 0.0, next = 0.0, from = { roll = P.roll, yaw = P.yaw, y = P.y, lid = P.lid } }
	-- BedWars' lucky box preview for the rarity (as soon as the server's roll is in)
	local previewed = false
	local waited = 0.0
	while true do
		local dt = task.wait() / math.max(self.pace, 0.05)
		if gen ~= self._gen then
			return false
		end
		local b = self._build_st
		b.t += dt
		local rid = if self._rar then self._rar.id else nil
		local len = CrateOpening.BUILD_S[rid or "rare"] or 0.8
		if rid ~= nil and not previewed then
			previewed = true
			self.ctx:sfx("crate_preview_" .. rid, -1, 0)
		end
		b.k = math.clamp(b.t / len, 0, 1)
		if b.k >= 1 then
			if self._item ~= nil then
				break
			end
			-- the roll is still on its way: it keeps rattling
			waited += dt
			if waited > CrateOpening.RESULT_WAIT_S then
				self:fail("The crate didn't open. It's saved: try again in a moment.")
				return false
			end
		end
	end
	self._build_st = nil
	return true
end

function CrateOpening._burst(self, gen: number): boolean
	local S = self._S
	local rar = self._rar or Cosmetics.RARITIES[1]
	local rid = rar.id
	local col = c3(rar.color)
	local light = col:Lerp(Color3.new(1, 1, 1), 0.35)
	self._light = light
	self._phase = "burst"
	self:_title_out()
	-- crouch
	self:_animate("roll", { { 0, 0.06 } })
	self:_animate("yaw", { { 0, 0.06 } })
	self:_animate("lid", { { 0, 0.06 } })
	self:_animate("y", { { 0, 0.06 } })
	self:_animate("sq", { { 0.2, 0.1 } })
	if not self:_sleep(gen, 0.1) then
		return false
	end
	-- the lid bursts open
	self:_animate("sq", { { -0.14, 0.1 }, { 0.06, 0.14, "inOutSine" }, { 0, 0.2 } })
	self:_animate("y", { { 0.45, 0.12 }, { 0, 0.26, "inQuad" } })
	self:_animate("lid", { { Model.lid_open or 118, 0.34, "outBack" } })
	self:_animate("s", { { 1.08, 0.1 }, { 1, 0.3 } })
	self.ctx:sfx("crate_open", 0, 0)
	self:_kick(S * (if rid == "legendary" then 0.075 elseif rid == "epic" then 0.055 else 0.04))
	self._flash.BackgroundColor3 = light
	self._flash.BackgroundTransparency = if rid == "legendary" then 0.45 else 0.58
	tween(self._flash, 0.45, { BackgroundTransparency = 1 })
	self._tint.ImageColor3 = col
	self._tint.ImageTransparency = 0.5
	tween(self._tint, 1.2, { ImageTransparency = 0.78 })
	self._vpf.Ambient = AMBIENT:Lerp(light, 0.6)
	tween(self._vpf, 0.6, { Ambient = AMBIENT:Lerp(light, 0.15) })
	-- rays, halo, beam and a shockwave out of the chest's mouth
	local mouth = self:_project(v3(Model.mouth))
	place(self._rays, mouth)
	self._rays_a.ImageColor3 = light
	self._rays_b.ImageColor3 = col
	self._halo.ImageColor3 = col
	self._rays_scale.Scale = if rid == "legendary" then 0.8 else 0.3
	tween(self._rays_scale, 0.55, { Scale = if rid == "legendary" then 1.15 else 1 }, Enum.EasingStyle.Back)
	self._rays_a.ImageTransparency = 0.25
	self._rays_b.ImageTransparency = 0.45
	tween(self._rays_a, 1.1, { ImageTransparency = if rid == "legendary" then 0.35 else 0.5 })
	tween(self._rays_b, 1.1, { ImageTransparency = if rid == "legendary" then 0.5 else 0.7 })
	self._rays_spin = if rid == "legendary" then 70 else 45
	if rid == "legendary" then
		self._rays_a.ImageColor3 = Color3.new(1, 1, 1)
		self._rays_grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
			ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 60)),
			ColorSequenceKeypoint.new(0.4, Color3.fromRGB(120, 230, 90)),
			ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 170, 255)),
			ColorSequenceKeypoint.new(0.8, Color3.fromRGB(190, 110, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 90, 90)),
		})
		self._rays_grad.Enabled = true
	end
	self._halo.Size = UDim2.fromScale(0.35, 0.35)
	self._halo.ImageTransparency = 0.2
	tween(self._halo, 0.8, { ImageTransparency = 0.5, Size = UDim2.fromScale(0.7, 0.7) }, Enum.EasingStyle.Quart)
	self._beam.ImageColor3 = light
	place(self._beam, mouth + Vector2.new(0, S * 0.05))
	self._beam.Size = UDim2.fromOffset(S * 0.25, S * 0.6)
	self._beam.ImageTransparency = 0.2
	tween(self._beam, 0.25, { Size = UDim2.fromOffset(S * 0.5, S * 1.5) }, Enum.EasingStyle.Quart)
	task.delay(0.15 * self.pace, function()
		if self._gen == gen then
			tween(self._beam, 0.9 * self.pace, { ImageTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end
	end)
	place(self._floor_ring, mouth)
	self._floor_ring.ImageColor3 = light
	self._floor_ring.Size = UDim2.fromOffset(S * 0.3, S * 0.3)
	self._floor_ring.ImageTransparency = 0.15
	tween(self._floor_ring, 0.6, { Size = UDim2.fromOffset(S * 2.8, S * 2.8), ImageTransparency = 1 }, Enum.EasingStyle.Quart)
	self._mouth_glow.ImageColor3 = col
	self._mouth_glow.ImageTransparency = 0.1
	self._chest_glow.ImageColor3 = col
	self._chest_glow.ImageTransparency = 0.3
	tween(self._chest_glow, 0.9, { ImageTransparency = 0.55 })
	local n = CrateOpening.BURST[rid] or 18
	self:_emit(n, {
		x = mouth.X,
		y = mouth.Y,
		jitter = 0.08,
		dir = -90,
		spread = 62,
		vmin = 1.6,
		vmax = 3.2,
		kind = "mix",
		streaks = 0.6,
		size = 0.06,
		grav = 2.0,
		drag = 1.5,
		life = { 0.5, 1.0 },
		colors = { col, light },
		white = 0.25,
		front = true,
	})
	self:_emit(math.floor(n * 0.6), {
		x = mouth.X,
		y = mouth.Y,
		jitter = 0.1,
		dir = -90,
		spread = 80,
		vmin = 0.6,
		vmax = 1.5,
		size = 0.07,
		grav = 1.1,
		drag = 1.4,
		life = { 0.7, 1.3 },
		colors = { light, col },
		front = true,
	})
	return self:_sleep(gen, if rid == "legendary" then 0.7 else 0.5)
end

function CrateOpening._card_out(self, gen: number): boolean
	local rar = self._rar or Cosmetics.RARITIES[1]
	local rid = rar.id
	local col = c3(rar.color)
	self._phase = "card"
	self._hurry = false
	-- the card flies out of the chest, face down and spinning; the chest steps down under it
	local mouth = self:_project(v3(Model.mouth))
	local card = self._card
	card.Visible = true
	self._back.Visible = true
	self._front.Visible = false
	self._new.Visible = false
	card.Position = UDim2.fromOffset(mouth.X, mouth.Y)
	card.Rotation = -200
	self._card_scale.Scale = 0.12
	self._card_flying = true
	tween(card, 0.45, { Position = self._card_pos }, Enum.EasingStyle.Back)
	tween(card, 0.45, { Rotation = 0 }, Enum.EasingStyle.Quad)
	tween(self._card_scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	self.ctx:sfx("card_whoosh")
	self:_animate("hy", { { 0.66, 0.45, "outQuad" } })
	self:_animate("hs", { { 0.5, 0.45, "outQuad" } })
	tween(self._rays, 0.45, { Position = self._card_pos })
	tween(self._mouth_glow, 0.45, { ImageTransparency = 0.5 })
	if not self:_sleep(gen, 0.45) then
		return false
	end
	self._card_flying = false
	-- the back glows in the rarity colour (the rarer, the longer)
	self._back_stroke.Color = col:Lerp(Color3.new(1, 1, 1), 0.2)
	self._card_glow.ImageColor3 = col
	self._card_glow.ImageTransparency = 1
	self._card_glow.Position = self._card_pos
	tween(self._card_glow, 0.25, { ImageTransparency = 0.35 })
	self._card_hold = { t = 0.0, rid = rid }
	if rid == "epic" or rid == "legendary" then
		self.ctx:sfx("crate_shimmer", -3, 0)
	end
	local ok = self:_sleep(gen, CrateOpening.CARD_HOLD_S[rid] or 0.2, true)
	self._card_hold = nil
	card.Rotation = 0
	self._card_scale.Scale = 1
	return ok
end

function CrateOpening._reveal(self, gen: number)
	local it = Cosmetics.item(self._item)
	local rar = self._rar or Cosmetics.RARITIES[1]
	local rid = rar.id
	local col = c3(rar.color)
	local S = self._S
	local card = self._card
	local w = card.Size
	-- the chest leaves the stage to the words and buttons
	self:_animate("hy", { { 1.6, 0.4, "inQuad" } })
	tween(self._vpf, 0.35, { ImageTransparency = 1 })
	for _, g in { self._mouth_glow, self._chest_glow, self._shadow } do
		tween(g, 0.3, { ImageTransparency = 1 })
	end
	-- the flip
	tween(card, 0.12, { Size = UDim2.fromOffset(2, w.Y.Offset) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	self.ctx:sfx("card_flip")
	if not self:_sleep(gen, 0.12) then
		return
	end
	self._back.Visible = false
	self._front.Visible = true
	self._front_stroke.Color = col
	self._front_grad.Color = ColorSequence.new(col:Lerp(Color3.fromRGB(20, 24, 48), 0.35), col:Lerp(Color3.fromRGB(10, 12, 30), 0.8))
	self:_show_item(it)
	tween(card, 0.22, { Size = w }, Enum.EasingStyle.Back)
	self._card_scale.Scale = 1.12
	tween(self._card_scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	self.ctx:sfx("reveal_" .. rid, 0, 0)
	self:_kick(S * (if rid == "legendary" then 0.04 else 0.018))
	self._card_glow.ImageTransparency = 0.15
	tween(self._card_glow, 0.6, { ImageTransparency = 0.45 })
	self:_emit(if rid == "legendary" then 34 elseif rid == "epic" then 22 else 12, {
		x = self._card_pos.X.Offset,
		y = self._card_pos.Y.Offset,
		jitter = 0.15,
		spread = 180,
		vmin = 0.8,
		vmax = 2.0,
		kind = "mix",
		streaks = 0.35,
		size = 0.055,
		grav = 1.2,
		drag = 2,
		life = { 0.5, 1.0 },
		colors = { col, col:Lerp(Color3.new(1, 1, 1), 0.4) },
		white = 0.2,
		front = true,
	})
	if rid == "epic" or rid == "legendary" then
		self._shine.Visible = true
		self._shine_grad.Offset = Vector2.new(-1, 0)
		tween(self._shine_grad, 0.9, { Offset = Vector2.new(1, 0) }, Enum.EasingStyle.Sine)
	end
	-- NEW! (never a duplicate)
	self._new.Visible = true
	self._new_scale.Scale = 0
	tween(self._new_scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	-- the words
	self._rarity.Text = string.upper(rar.name)
	self._rarity.TextColor3 = col:Lerp(Color3.new(1, 1, 1), 0.15)
	self._rarity_scale.Scale = 1.6
	tween(self._rarity_scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	self._name.Text = if it then it.name else "?"
	self._kind.Text = if it and it.kind == "flag" then "FLAG · SHOWN BY YOUR NAME" else "TERRITORY SKIN"
	for i, l in { self._rarity, self._name, self._kind } do
		local p = l.Position
		l.Position = p + UDim2.fromOffset(0, S * 0.03)
		task.delay(0.08 * i * self.pace, function()
			if gen == self._gen then
				tween(l, 0.3, { TextTransparency = 0, Position = p }, Enum.EasingStyle.Back)
				tween(l:FindFirstChildOfClass("UIStroke"), 0.3, { Transparency = 0.2 })
			end
		end)
	end
	if not self:_sleep(gen, 0.5) then
		return
	end
	self._holder.Visible = false
	self._phase = "choose"
	self:refresh_buttons()
	self._row:set_visible(true)
	self._row:set_modulate_a(0)
	W.fade(self._row, 1.0, 0.25)
end

function CrateOpening._show_item(self, it: any)
	local img = self._preview
	if self.show_item ~= nil then
		-- (the Locker's: skins from the uploaded preview atlas, flags from theirs)
		self.show_item(img, it)
		return
	end
	img.ImageRectOffset = Vector2.zero
	img.ImageRectSize = Vector2.zero
	img.ImageContent = Content.none
	img.Image = ""
	if it == nil then
		return
	end
	if it.kind == "flag" then
		img.ResampleMode = Enum.ResamplerMode.Default
		img.Image = Cosmetics.flag_image(it)
		img.ImageRectOffset = Vector2.new(it.x, it.y)
		img.ImageRectSize = Vector2.new(it.w, it.h)
	elseif self.preview_of ~= nil then
		img.ResampleMode = Enum.ResamplerMode.Pixelated
		local ed = self.preview_of(it)
		if ed ~= nil then
			img.ImageContent = Content.fromObject(ed)
		end
	end
end

--- The buttons under the card: WEAR IT (unless worn) · the next crate · DONE.
function CrateOpening.refresh_buttons(self)
	local info = if self.info_of then self.info_of() else (self._info or {})
	local it = Cosmetics.item(self._item)
	local wearing = it ~= nil and info.wearing ~= nil and info.wearing(it.kind) == it.id
	self._wear_b:set_disabled(wearing)
	self._wear_b:set_text(if wearing then "WEARING" else "WEAR IT")
	self._again_b:set_visible(info.can_more == true)
	if (info.crates or 0) > 0 then
		self._again_b:set_icon("crate")
		self._again_b:set_text(if info.crates > 1 then string.format("OPEN NEXT (%d)", info.crates) else "OPEN NEXT")
	else
		self._again_b:set_icon("robux")
		self._again_b:set_text(string.format("ANOTHER · %d", info.price or 49))
	end
	self:_layout()
end

-- ---------------------------------------------------------------------------------------------
-- Per frame
-- ---------------------------------------------------------------------------------------------

function CrateOpening._kick(self, px: number)
	self._shake = math.max(self._shake or 0, px)
end

function CrateOpening._step(self, dt: number)
	if not self.is_open then
		return
	end
	dt = math.min(dt, 0.1)
	self._t += dt
	local t = self._t
	local S = self._S or 300
	local P = self._P
	self:_step_anims(dt)
	-- idle: bob, and a wiggle now and then with a rattle, the lid cracking and light leaking out
	local id = self._idle_st
	if id ~= nil and self._phase == "idle" then
		id.t += dt
		P.y = math.sin(id.t * 2.4) * 0.08
		if id.t >= id.next and id.wt < 0 then
			id.wt = 0
			self.ctx:sfx("crate_rattle", -4, 0.06)
			local seam = self:_project(v3(Model.seam))
			self:_emit(3, {
				x = seam.X,
				y = seam.Y,
				jitter = 0.12,
				dir = -90,
				spread = 55,
				vmin = 0.3,
				vmax = 0.7,
				size = 0.045,
				grav = 0.4,
				drag = 1.6,
				life = { 0.45, 0.8 },
				colors = { GOLD_LIGHT, GOLD },
				front = true,
			})
		end
		if id.wt >= 0 then
			id.wt += dt
			local k = id.wt / 0.36
			if k >= 1 then
				id.wt = -1
				id.next = id.t + CrateOpening.WIGGLE_EVERY_S
				P.roll, P.yaw, P.lid = 0, 0, 0
			else
				local wig = math.sin(k * math.pi * 3) * (1 - k) * math.rad(5)
				P.roll = wig
				P.yaw = wig * 0.6
				P.lid = math.sin(k * math.pi) * 7
			end
		end
		self._hint_scale.Scale = 1 + 0.04 * (0.5 + 0.5 * math.sin(t * 4.2))
		-- rising sparkles around the chest
		if math.random() < dt * 5 then
			local mid = self:_project(Vector3.new(0, Model.size[2] * 0.4, 0))
			self:_emit(1, {
				x = mid.X,
				y = mid.Y,
				jitter = 0.32,
				dir = -90,
				spread = 15,
				vmin = 0.06,
				vmax = 0.16,
				size = 0.04,
				grav = -0.05,
				drag = 0.2,
				life = { 0.9, 1.6 },
				colors = { GOLD_LIGHT, GOLD },
			})
		end
		self._chest_glow.ImageTransparency = 0.6 - 0.12 * (0.5 + 0.5 * math.sin(t * 4.2))
	end
	-- the build-up: rattles, each a hop with one damped swing and the lid popping (distinct jolts, not a
	-- continuous jitter, which looked glitchy once the chest was tapped open, 2026-09-29), closer
	-- together and bigger as it builds; the chest swells; the light turns the
	-- rarity colour
	local b = self._build_st
	if b ~= nil and self._phase == "build" then
		local k = b.k
		if b.jt == nil and b.t >= (b.next or 0) then
			b.jt = 0.0
			b.dir = -(b.dir or -1)
			self.ctx:sfx("crate_rattle", -4 + 3 * k, 0, 1 + 0.3 * k)
			self:_kick(S * (0.004 + 0.01 * k))
			local seam = self:_project(v3(Model.seam))
			self:_emit(2 + math.floor(4 * k), {
				x = seam.X,
				y = seam.Y,
				jitter = 0.18,
				dir = -90,
				spread = 65,
				vmin = 0.5,
				vmax = 1.2,
				kind = "mix",
				streaks = 0.5,
				size = 0.045,
				grav = 1.0,
				drag = 1.4,
				life = { 0.35, 0.7 },
				colors = { self._light },
				white = 0.2,
				front = true,
			})
		end
		local roll, y, lid, sq = 0.0, 0.0, 0.0, 0.0
		if b.jt ~= nil then
			b.jt += dt
			local q = b.jt / CrateOpening.JOLT_S
			if q >= 1 then
				b.jt = nil
				b.next = b.t + CrateOpening.JOLT_GAP_S[1] + (CrateOpening.JOLT_GAP_S[2] - CrateOpening.JOLT_GAP_S[1]) * k
			else
				local hump = math.sin(q * math.pi)
				roll = math.sin(q * math.pi * 2) * (1 - q) * math.rad(5 + 7 * k) * b.dir
				y = hump * (0.12 + 0.3 * k)
				lid = hump * (6 + 14 * k)
				sq = -0.05 * hump
			end
		end
		-- (eases in from the idle pose over the first frames)
		local e = math.min(1, b.t / 0.1)
		local f = b.from
		P.roll = f.roll + (roll - f.roll) * e
		P.yaw = f.yaw + (roll * 0.5 - f.yaw) * e
		P.y = f.y + (y - f.y) * e
		P.lid = f.lid + (lid - f.lid) * e
		P.sq = sq
		P.s = 1 + 0.07 * k
		local target = if self._rar then c3(self._rar.color):Lerp(Color3.new(1, 1, 1), 0.3) else GOLD_LIGHT
		if k > 0.3 then
			self._light = self._light:Lerp(target, math.min(1, dt * 4))
		end
		self._chest_glow.ImageColor3 = self._light
		self._chest_glow.ImageTransparency = 0.55 - 0.3 * k
		self._leak.ImageColor3, self._leak_flare.ImageColor3 = self._light, self._light
		self._vpf.Ambient = AMBIENT:Lerp(self._light, 0.3 * k)
		if self._rar ~= nil and (self._rar.id == "legendary" or self._rar.id == "epic") then
			-- the rarer ones tease with rays behind the chest
			local legend = self._rar.id == "legendary"
			self._rays_a.ImageColor3 = self._light
			self._rays_b.ImageColor3 = self._light
			self._rays_a.ImageTransparency = 1 - (if legend then 0.55 else 0.35) * k
			self._rays_b.ImageTransparency = 1 - (if legend then 0.35 else 0.2) * k
			self._rays_spin = 10 + 50 * k
		end
	end
	-- falling: air streaks rushing past
	if self._falling and math.random() < dt * 60 then
		local c = self:_project(Vector3.new(0, Model.size[2] * 0.5, 0))
		self:_emit(1, {
			x = c.X,
			y = c.Y,
			jitter = 0.34,
			dir = -90,
			spread = 2,
			vmin = 3.0,
			vmax = 4.6,
			kind = "streak",
			size = 0.14,
			drag = 0,
			life = { 0.12, 0.22 },
			base = 0.55,
			colors = { GOLD_LIGHT },
		})
	end
	-- the card: while it holds face down it glows and (the rarer ones) shakes; then it breathes
	local hold = self._card_hold
	if hold ~= nil then
		hold.t += dt
		local strong = hold.rid == "legendary" or hold.rid == "epic"
		local k = math.clamp(hold.t / (CrateOpening.CARD_HOLD_S[hold.rid] or 0.2), 0, 1)
		if strong then
			self._card.Rotation = math.sin(t * (30 + 20 * k)) * (2 + 5 * k)
			self._card_scale.Scale = 1 + 0.06 * k
		end
		self._card_glow.ImageTransparency = 0.35 - 0.2 * k * (0.5 + 0.5 * math.sin(t * 18))
		if strong and math.random() < dt * 22 then
			self:_emit(1, {
				x = self._card_pos.X.Offset,
				y = self._card_pos.Y.Offset,
				jitter = 0.3,
				dir = -90,
				spread = 40,
				vmin = 0.2,
				vmax = 0.6,
				size = 0.045,
				grav = -0.2,
				drag = 0.8,
				life = { 0.5, 0.9 },
				colors = { self._card_glow.ImageColor3 },
				white = 0.3,
				front = true,
			})
		end
	elseif self._phase == "choose" then
		self._card.Rotation = math.sin(t * 1.6) * 1.2
	end
	-- rays spin (and slow back down after the burst)
	if self._phase ~= "build" then
		self._rays_spin += (10 - self._rays_spin) * math.min(1, dt * 1.2)
	end
	self._rays_a.Rotation = (self._rays_a.Rotation + dt * self._rays_spin) % 360
	self._rays_b.Rotation = (self._rays_b.Rotation - dt * self._rays_spin * 0.6) % 360
	if self._rays_grad.Enabled then
		self._rays_grad.Rotation = (self._rays_grad.Rotation + dt * 90) % 360
	end
	-- the chest and what rides on it: the shadow, the leak at the seam, the light in its mouth
	if self._holder.Visible then
		self:_apply_pose()
		place(self._shadow, self:_project(Vector3.zero) + Vector2.new(0, S * 0.01))
		-- (smaller and fainter while it's still up in the air)
		local near = math.clamp(1 + P.hy / 1.8, 0, 1)
		local sw = S * 0.85 * P.hs * (0.3 + 0.7 * near)
		self._shadow.Size = UDim2.fromOffset(sw, sw * 0.2)
		if self._phase == "land" or self._phase == "idle" or self._phase == "build" or self._phase == "burst" then
			self._shadow.ImageTransparency = 0.92 - 0.52 * near
		end
		local seam = self:_project(v3(Model.seam))
		place(self._leak, seam)
		place(self._leak_flare, seam)
		self._leak.Size = UDim2.fromOffset(S * 0.6 * P.hs, S * 0.16 * P.hs)
		self._leak_flare.Size = UDim2.fromOffset(S * 0.95 * P.hs, S * 0.08 * P.hs)
		local la = if P.lid < 60 then math.clamp(P.lid / 9, 0, 1) else 0
		self._leak.ImageTransparency = 1 - la * 0.75
		self._leak_flare.ImageTransparency = 1 - la * 0.65
		place(self._chest_glow, self:_project(Vector3.new(0, Model.size[2] * 0.42, 0)))
		self._chest_glow.Size = UDim2.fromOffset(S * 1.25 * P.hs, S * 1.05 * P.hs)
		place(self._mouth_glow, self:_project(v3(Model.mouth)))
		self._mouth_glow.Size = UDim2.fromOffset(S * 0.9 * P.hs, S * 0.5 * P.hs)
	end
	self:_step_particles(dt)
	-- the screen shake
	if (self._shake or 0) > 0.3 then
		self._shake *= math.exp(-dt * 8)
		self._stage.Position = UDim2.fromOffset((math.random() - 0.5) * self._shake, (math.random() - 0.5) * self._shake)
	elseif self._stage.Position ~= UDim2.new() then
		self._shake = 0
		self._stage.Position = UDim2.new()
	end
end

-- ---------------------------------------------------------------------------------------------
-- Particles (image sparks: sparkle / streak / dust; speeds and sizes in stage units S)
-- ---------------------------------------------------------------------------------------------

function CrateOpening._emit(self, n: number, o: any)
	local art = UITheme.crate_art()
	local S = self._S or 300
	local parent = if o.front then self._front_fx else self._back_fx
	local cols = o.colors or { GOLD_LIGHT }
	for _ = 1, n do
		if #self._particles >= CrateOpening.MAX_PARTICLES then
			return
		end
		local kind = o.kind or "sparkle"
		if kind == "mix" then
			kind = if math.random() < (o.streaks or 0.5) then "streak" else "sparkle"
		end
		local a = math.rad((o.dir or -90) + (math.random() * 2 - 1) * (o.spread or 180))
		local vmin, vmax = o.vmin or 0.5, o.vmax or 1.0
		local sp = S * (vmin + math.random() * (vmax - vmin))
		local j = (o.jitter or 0) * S
		local x = o.x + (math.random() * 2 - 1) * j
		local y = o.y + (math.random() * 2 - 1) * j * 0.5
		local col = if math.random() < (o.white or 0) then Color3.new(1, 1, 1) else cols[math.random(1, #cols)]
		local size = S * (o.size or 0.05) * (0.7 + math.random() * 0.6)
		local w, h = size, size
		if kind == "streak" then
			w, h = size * 0.3, size * 2.6
		end
		local life = o.life or { 0.6, 1.0 }
		local base = o.base or 0
		local img = new("ImageLabel", {
			BackgroundTransparency = 1,
			Image = (if kind == "dust" then art.glow elseif kind == "streak" then art.streak else art.sparkle) or "",
			ImageColor3 = col,
			ImageTransparency = base,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(w, h),
			Position = UDim2.fromOffset(x, y),
			ZIndex = parent.ZIndex,
		}, parent)
		table.insert(self._particles, {
			img = img,
			x = x,
			y = y,
			vx = math.cos(a) * sp,
			vy = math.sin(a) * sp,
			grav = (o.grav or 0) * S,
			drag = o.drag or 1.5,
			spin = if kind == "sparkle" then (math.random() - 0.5) * 540 else 0,
			align = kind == "streak",
			grow = o.grow or 0,
			w = w,
			h = h,
			base = base,
			life = 0.0,
			ttl = life[1] + math.random() * (life[2] - life[1]),
		})
	end
end

function CrateOpening._step_particles(self, dt: number)
	for i = #self._particles, 1, -1 do
		local p = self._particles[i]
		p.life += dt
		if p.life >= p.ttl then
			p.img:Destroy()
			table.remove(self._particles, i)
		else
			local d = math.exp(-dt * p.drag)
			p.vx *= d
			p.vy = p.vy * d + p.grav * dt
			p.x += p.vx * dt
			p.y += p.vy * dt
			local k = p.life / p.ttl
			local img = p.img
			img.Position = UDim2.fromOffset(p.x, p.y)
			if p.align then
				img.Rotation = math.deg(math.atan2(p.vy, p.vx)) - 90
			elseif p.spin ~= 0 then
				img.Rotation += p.spin * dt
			end
			if p.grow > 0 then
				local g = 1 + p.grow * k
				img.Size = UDim2.fromOffset(p.w * g, p.h * g)
			end
			img.ImageTransparency = p.base + (1 - p.base) * k * k
		end
	end
end

function CrateOpening._clear_particles(self)
	for _, p in self._particles do
		p.img:Destroy()
	end
	table.clear(self._particles)
end

-- ---------------------------------------------------------------------------------------------
-- Close
-- ---------------------------------------------------------------------------------------------

function CrateOpening.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self._gen += 1
	self._phase = "off"
	self._idle_st, self._build_st, self._card_hold = nil, nil, nil
	self._falling = false
	self._row:set_visible(false)
	tween(self._dim, 0.2, { BackgroundTransparency = 1 })
	for _, i in {
		self._rays_a,
		self._rays_b,
		self._halo,
		self._tint,
		self._preview,
		self._card_glow,
		self._chest_glow,
		self._mouth_glow,
		self._shadow,
		self._leak,
		self._leak_flare,
		self._beam,
		self._floor_ring,
	} do
		tween(i, 0.18, { ImageTransparency = 1 })
	end
	tween(self._vpf, 0.18, { ImageTransparency = 1 })
	self._card.Visible = false
	for _, l in { self._rarity, self._name, self._kind, self._title, self._subtitle, self._hint_text } do
		tween(l, 0.15, { TextTransparency = 1 })
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			tween(st, 0.15, { Transparency = 1 })
		end
	end
	tween(self._hint, 0.15, { BackgroundTransparency = 1 })
	tween(self._hint_stroke, 0.15, { Transparency = 1 })
	local gen = self._gen
	task.delay(0.22, function()
		if gen == self._gen and not self.is_open then
			self:_clear_particles()
			self:set_visible(false)
			if self._conn then
				self._conn:Disconnect()
				self._conn = nil
			end
		end
	end)
	self.shown:Fire(false)
	self.closed:Fire(self._fail)
end

return CrateOpening
