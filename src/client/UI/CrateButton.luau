--!nonstrict
-- The title screen's crate button, top right (2026-09-29: on phones the chest button was hard to
-- notice, so it got more to catch the eye). The 3D chest (ChestView) wiggles on a glow and slow
-- rays with a twinkle or two, a CRATES pill under it, and a badge:
--   a crate waiting (bought, not opened)  a red count, the pill says OPEN, it wiggles more often;
--   the first crate not bought yet        its price (15) with the Robux icon;
--   otherwise                             no badge.
-- Where paid random items are restricted, or everything is owned, it's a calm LOCKER button (no wiggle,
-- no price). pressed() -> UIRoot opens the Locker.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local ChestView = require("./ChestView")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local function shared(name: string): any
	if IS_ROBLOX then
		return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data[name]) :: any
	end
	return (require :: any)("../../shared/Data/" .. name)
end
local Products = shared("Products")
local Prices = require("./Prices")
local Cosmetics = shared("Cosmetics")
local TweenService = if IS_ROBLOX then game:GetService("TweenService") else nil

local CrateButton = W.class(W.Control)

--- The chest square, desktop px (phones: PHONE_K of it).
CrateButton.SIZE = 150
CrateButton.PHONE_K = 0.66
CrateButton.WIGGLE_S = 2.4 -- (a crate waiting: WAITING_WIGGLE_S)
CrateButton.WAITING_WIGGLE_S = 1.2

local GOLD = Color3.fromRGB(255, 190, 72)
local GOLD_LIGHT = Color3.fromRGB(255, 226, 150)
local FONT_B = Font.fromId(12187365977, Enum.FontWeight.Heavy)

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

local function tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?)
	if TweenService ~= nil then
		TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
			:Play()
	end
end

function CrateButton.new(c: any)
	local self = setmetatable({}, CrateButton.__mt)
	W.Control._init(self)
	self.ctx = c
	self.pressed = Signal.new()
	self._t = 0.0
	self._k = 1.0
	self._state = "calm"
	self._P = ChestView.rest()
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:_build()
	self:set_process(true)
	return self
end

function CrateButton._build(self)
	local art = UITheme.crate_art()
	local root = self.gui
	root.ClipsDescendants = false
	-- everything but the hit area scales together (hover / press)
	local body = new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, root)
	self._body_scale = new("UIScale", {}, body)
	local function img(name: string, image: string?, z: number, props: any?): ImageLabel
		local p = props or {}
		p.Name = name
		p.BackgroundTransparency = 1
		p.Image = image or ""
		p.AnchorPoint = p.AnchorPoint or Vector2.new(0.5, 0.5)
		p.ZIndex = z
		return new("ImageLabel", p, body)
	end
	-- (the chest square is the top of the button; the pill overlaps its bottom)
	self._rays = img("Rays", art.rays, 1, { ImageColor3 = GOLD, ImageTransparency = 0.82 })
	self._glow = img("Glow", art.glow, 2, { ImageColor3 = GOLD, ImageTransparency = 0.5 })
	local vpf = new(
		"ViewportFrame",
		{ Name = "Chest", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 3 },
		body
	)
	self._vpf = vpf
	self._chest = ChestView.build(vpf)
	self._leak = img("Leak", art.glow, 4, { ImageColor3 = GOLD_LIGHT, ImageTransparency = 1 })
	self._sparks = {}
	for i = 1, 3 do
		self._sparks[i] = {
			img = img("Spark" .. i, art.sparkle, 5, { ImageColor3 = GOLD_LIGHT, ImageTransparency = 1 }),
			t = -i * 0.7,
		}
	end
	-- the pill
	local pill = new("Frame", {
		Name = "Pill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 6,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pill)
	self._pill_grad = new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 214, 110), Color3.fromRGB(242, 160, 40)),
		Rotation = 90,
	}, pill)
	new(
		"UIStroke",
		{
			Color = Color3.fromRGB(70, 40, 6),
			Thickness = 2,
			Transparency = 0.2,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		},
		pill
	)
	self._pill = pill
	self._pill_text = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "CRATES",
		FontFace = FONT_B,
		TextColor3 = Color3.fromRGB(46, 26, 4),
		TextScaled = true,
		ZIndex = 7,
	}, pill)
	new("UIPadding", {
		PaddingTop = UDim.new(0.2, 0),
		PaddingBottom = UDim.new(0.16, 0),
		PaddingLeft = UDim.new(0.12, 0),
		PaddingRight = UDim.new(0.12, 0),
	}, self._pill_text)
	-- the badge (top right of the chest)
	local badge = new("Frame", {
		Name = "Badge",
		BackgroundColor3 = Color3.fromRGB(232, 56, 56),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 8,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, badge)
	new(
		"UIStroke",
		{ Color = Color3.fromRGB(255, 255, 255), Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border },
		badge
	)
	self._badge_scale = new("UIScale", {}, badge)
	self._badge = badge
	local brow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 9 }, badge)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, brow)
	self._badge_icon = new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = "rbxasset://textures/ui/common/robux@3x.png",
		LayoutOrder = 1,
		ZIndex = 9,
	}, brow)
	self._badge_text = new("TextLabel", {
		BackgroundTransparency = 1,
		Text = "",
		FontFace = FONT_B,
		TextColor3 = Color3.new(1, 1, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		ZIndex = 9,
	}, brow)
	-- the hit area (above everything)
	local hit = new("TextButton", {
		Name = "Hit",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 20,
	}, root)
	self._hover = false
	hit.MouseEnter:Connect(function()
		self._hover = true
		tween(self._body_scale, 0.12, { Scale = 1.06 })
	end)
	hit.MouseLeave:Connect(function()
		self._hover = false
		tween(self._body_scale, 0.12, { Scale = 1 })
	end)
	hit.MouseButton1Down:Connect(function()
		tween(self._body_scale, 0.08, { Scale = 0.94 })
	end)
	hit.MouseButton1Up:Connect(function()
		tween(self._body_scale, 0.12, { Scale = if self._hover then 1.06 else 1 })
	end)
	hit.Activated:Connect(function()
		self.ctx:sfx("click")
		self.pressed:Fire()
	end)
	self._hit = hit
	self:_size_parts()
end

--- `k`: 1 on desktop, PHONE_K on phones (also follows UITheme.scale: call it from apply_layout).
function CrateButton.set_scale(self, k: number)
	if k == self._k and UITheme.scale == self._u then
		return
	end
	self._k = k
	self:_size_parts()
end

--- The control's size in logical px: the chest square plus the pill's lower half.
function CrateButton.size_px(self): Vector2
	local s = CrateButton.SIZE * self._k
	return Vector2.new(s, s * 1.08)
end

-- (the raw instances inside are sized in px: logical px x UITheme.scale)
function CrateButton._size_parts(self)
	self._u = UITheme.scale
	local s = CrateButton.SIZE * self._k * self._u
	local cy = s * 0.46 -- the chest's centre (from the top)
	self._s, self._cy = s, cy
	self._vpf.Size = UDim2.fromOffset(s, s)
	self._vpf.Position = UDim2.fromOffset(s * 0.5, cy)
	self._rays.Size = UDim2.fromOffset(s * 1.35, s * 1.35)
	self._rays.Position = UDim2.fromOffset(s * 0.5, cy)
	self._glow.Size = UDim2.fromOffset(s * 1.15, s * 1.05)
	self._glow.Position = UDim2.fromOffset(s * 0.5, cy + s * 0.04)
	local pw, ph = s * 0.8, math.max(22 * self._u, s * 0.22)
	self._pill.Size = UDim2.fromOffset(pw, ph)
	self._pill.Position = UDim2.fromOffset(s * 0.5, s * 1.08)
	local bh = math.max(20 * self._u, s * 0.2)
	self._badge_h = bh
	self._badge.Position = UDim2.fromOffset(s * 0.82, s * 0.16)
	self._badge_icon.Size = UDim2.fromOffset(bh * 0.62, bh * 0.62)
	self._badge_text.Size = UDim2.fromOffset(0, bh)
	self._badge_text.TextSize = math.floor(bh * 0.7)
	self:_size_badge()
	for _, sp in self._sparks do
		sp.img.Size = UDim2.fromOffset(s * 0.1, s * 0.1)
	end
	self:set_min_size(self:size_px())
end

function CrateButton._size_badge(self)
	local bh = self._badge_h or 24
	local w = if self._badge_icon.Visible then bh * 0.62 + 4 + #self._badge_text.Text * bh * 0.46 + bh * 0.5 else bh
	self._badge.Size = UDim2.fromOffset(math.max(bh, w), bh)
end

--- Follow the session's inventory and crate credits.
function CrateButton.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	-- (and Roblox's price of the first crate, on the badge: UI/Prices)
	for _, sig in { s.inventory_changed, s.credits_changed, Prices.changed } do
		if sig then
			sig:Connect(function()
				self:refresh()
			end)
		end
	end
	Prices.fetch()
	self:refresh()
end

function CrateButton.refresh(self)
	local s = self.ctx.session
	local inv = if s ~= nil and s.inventory ~= nil then s.inventory else nil
	local credits = if s ~= nil and type(s.credits) == "table" then (tonumber(s.credits.crate) or 0) else 0
	local owned = Cosmetics.crate_owned(inv and inv.owned or {})
	local allowed = inv ~= nil and inv.crates_allowed == true
	local all_owned = owned >= #Cosmetics.all()
	-- (Studio diag "crate_btn": a forced look for screenshots)
	local fake = self._fake
	if fake == "waiting" then
		allowed, credits = true, 2
	elseif fake == "first" or fake == "offer" then
		allowed, credits, all_owned = true, 0, false
		inv = { crates_bought = if fake == "first" then 0 else 1 }
	elseif fake == "calm" then
		allowed = false
	end
	local state, text, badge, icon = "calm", "LOCKER", nil, false
	if allowed and credits > 0 then
		state, text, badge = "waiting", "OPEN", tostring(credits)
	elseif allowed and not all_owned then
		state, text = "offer", "CRATES"
		local first = Products.crate_first
		if (inv.crates_bought or 0) <= 0 and first and first.id ~= 0 then
			badge, icon = tostring(Prices.robux("crate_first")), true
		end
	end
	local changed = state ~= self._state or badge ~= self._badge_value
	self._state = state
	self._badge_value = badge
	self._pill_text.Text = text
	self._badge.Visible = badge ~= nil
	self._badge_icon.Visible = icon
	self._badge_text.Text = badge or ""
	self._badge.BackgroundColor3 = if icon then Color3.fromRGB(38, 170, 90) else Color3.fromRGB(232, 56, 56)
	self:_size_badge()
	if changed and badge ~= nil then
		self._badge_scale.Scale = 0.4
		tween(self._badge_scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	self._rays.Visible = state ~= "calm"
end

function CrateButton._process(self, dt: number)
	if not self:is_visible_in_tree() then
		return
	end
	self._t += dt
	local t = self._t
	local P = self._P
	local calm = self._state == "calm"
	local every = if self._state == "waiting" then CrateButton.WAITING_WIGGLE_S else CrateButton.WIGGLE_S
	local crack = if calm then 0 else ChestView.idle(P, t, every, if self._state == "waiting" then 1.3 else 1)
	if calm then
		P.y = math.sin(t * 2.0) * 0.05
	end
	ChestView.pose(self._chest, P)
	local s = self._s or 100
	-- light out of the seam while the lid cracks
	local seam = ChestView.project(P, ChestView.v3(ChestView.Model.seam), s)
	self._leak.Position = UDim2.fromOffset(s * 0.5 + seam.X, self._cy + seam.Y)
	self._leak.Size = UDim2.fromOffset(s * 0.7, s * 0.2)
	self._leak.ImageTransparency = 1 - crack * 0.75
	local pulse = 0.5 + 0.5 * math.sin(t * 3.2)
	self._glow.ImageTransparency = (if calm then 0.72 else 0.55) - 0.12 * pulse
	self._rays.Rotation = (self._rays.Rotation + dt * 14) % 360
	-- a twinkle or two around the chest
	for _, sp in self._sparks do
		sp.t += dt
		if calm then
			sp.img.ImageTransparency = 1
		elseif sp.t >= 0 then
			if not sp.placed then
				sp.placed = true
				local a = math.random() * math.pi * 2
				sp.img.Position = UDim2.fromOffset(s * 0.5 + math.cos(a) * s * 0.36, self._cy + math.sin(a) * s * 0.3)
			end
			local k = sp.t / 0.9
			if k >= 1 then
				sp.t = -(0.4 + math.random() * 1.4)
				sp.placed = false
				sp.img.ImageTransparency = 1
			else
				local v = math.sin(k * math.pi)
				sp.img.ImageTransparency = 1 - v * 0.9
				sp.img.Rotation = k * 90
				sp.img.Size = UDim2.fromOffset(s * 0.1 * (0.5 + v * 0.5), s * 0.1 * (0.5 + v * 0.5))
			end
		end
	end
end

return CrateButton
