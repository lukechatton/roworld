--!nonstrict
-- The title screen's Arsenal button, left of the crate button (its twin, CrateButton.luau): the
-- Arsenal's shield on a gold glow and slow rays, an ARSENAL pill under it, and a badge with the
-- player's Stars (Data/Stars: what every match pays, spent in the Arsenal). pressed() -> UIRoot opens
-- the Arsenal. A payout makes the badge pop.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local TweenService = if IS_ROBLOX then game:GetService("TweenService") else nil

local ArsenalButton = W.class(W.Control)

--- The square, desktop px (phones: PHONE_K of it).
ArsenalButton.SIZE = 132
ArsenalButton.PHONE_K = 0.6

local GOLD = Color3.fromRGB(255, 200, 61)
local GOLD_LIGHT = Color3.fromRGB(255, 232, 160)
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

local function commas(n: number): string
	local s = tostring(math.floor(math.abs(n) + 0.5))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return if string.sub(out, 1, 1) == "," then string.sub(out, 2) else out
end

function ArsenalButton.new(c: any)
	local self = setmetatable({}, ArsenalButton.__mt)
	W.Control._init(self)
	self.ctx = c
	self.pressed = Signal.new()
	self._t = 0.0
	self._k = 1.0
	self._stars = -1
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:_build()
	self:set_process(true)
	return self
end

function ArsenalButton._build(self)
	local art = UITheme.crate_art()
	local root = self.gui
	root.ClipsDescendants = false
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
	self._rays = img("Rays", art.rays, 1, { ImageColor3 = GOLD, ImageTransparency = 0.84 })
	self._glow = img("Glow", art.glow, 2, { ImageColor3 = GOLD, ImageTransparency = 0.5 })
	-- the shield: a dark copy under it for depth
	self._shade =
		img("Shade", UITheme.icon("arsenal"), 3, { ImageColor3 = Color3.fromRGB(60, 34, 0), ImageTransparency = 0.25 })
	self._shield = img("Shield", UITheme.icon("arsenal"), 4, { ImageColor3 = GOLD })
	new(
		"UIGradient",
		{ Color = ColorSequence.new(GOLD_LIGHT, Color3.fromRGB(240, 150, 30)), Rotation = 90 },
		self._shield
	)
	self._shield.ImageColor3 = Color3.new(1, 1, 1)
	self._spark = img("Spark", art.sparkle, 5, { ImageColor3 = GOLD_LIGHT, ImageTransparency = 1 })
	local pill = new(
		"Frame",
		{ Name = "Pill", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 1), ZIndex = 6 },
		body
	)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pill)
	new(
		"UIGradient",
		{ Color = ColorSequence.new(Color3.fromRGB(255, 214, 110), Color3.fromRGB(242, 160, 40)), Rotation = 90 },
		pill
	)
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
	local pt = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "ARSENAL",
		FontFace = FONT_B,
		TextColor3 = Color3.fromRGB(46, 26, 4),
		TextScaled = true,
		ZIndex = 7,
	}, pill)
	new("UIPadding", {
		PaddingTop = UDim.new(0.2, 0),
		PaddingBottom = UDim.new(0.16, 0),
		PaddingLeft = UDim.new(0.1, 0),
		PaddingRight = UDim.new(0.1, 0),
	}, pt)
	-- the Stars badge (top right of the shield)
	local badge = new("Frame", {
		Name = "Stars",
		BackgroundColor3 = Color3.fromRGB(20, 28, 52),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 8,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, badge)
	new("UIStroke", { Color = GOLD, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, badge)
	self._badge_scale = new("UIScale", {}, badge)
	self._badge = badge
	local brow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 9 }, badge)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 3),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, brow)
	self._badge_icon = new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = UITheme.icon("star") or "",
		ImageColor3 = GOLD,
		LayoutOrder = 1,
		ZIndex = 9,
	}, brow)
	self._badge_text = new("TextLabel", {
		BackgroundTransparency = 1,
		Text = "0",
		FontFace = FONT_B,
		TextColor3 = GOLD_LIGHT,
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		ZIndex = 9,
	}, brow)
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
		if not self.ctx.touch then
			self.ctx:sfx("hover", -12.0)
		end
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
		self.pressed:Fire()
	end)
	self:_size_parts()
end

--- `k`: 1 on desktop, PHONE_K on phones (also follows UITheme.scale: call it from apply_layout).
function ArsenalButton.set_scale(self, k: number)
	if k == self._k and UITheme.scale == self._u then
		return
	end
	self._k = k
	self:_size_parts()
end

--- The control's size in logical px: the square plus the pill's lower half.
function ArsenalButton.size_px(self): Vector2
	local s = ArsenalButton.SIZE * self._k
	return Vector2.new(s, s * 1.08)
end

function ArsenalButton._size_parts(self)
	self._u = UITheme.scale
	local s = ArsenalButton.SIZE * self._k * self._u
	local cy = s * 0.46
	self._s, self._cy = s, cy
	self._rays.Size = UDim2.fromOffset(s * 1.4, s * 1.4)
	self._rays.Position = UDim2.fromOffset(s * 0.5, cy)
	self._glow.Size = UDim2.fromOffset(s * 1.2, s * 1.1)
	self._glow.Position = UDim2.fromOffset(s * 0.5, cy)
	self._shield.Size = UDim2.fromOffset(s * 0.7, s * 0.7)
	self._shade.Size = UDim2.fromOffset(s * 0.7, s * 0.7)
	self._spark.Size = UDim2.fromOffset(s * 0.14, s * 0.14)
	local pw, ph = s * 0.86, math.max(22 * self._u, s * 0.22)
	self._pill.Size = UDim2.fromOffset(pw, ph)
	self._pill.Position = UDim2.fromOffset(s * 0.5, s * 1.08)
	local bh = math.max(20 * self._u, s * 0.2)
	self._badge_h = bh
	self._badge.Position = UDim2.fromOffset(s * 0.78, s * 0.12)
	self._badge_icon.Size = UDim2.fromOffset(bh * 0.6, bh * 0.6)
	self._badge_text.Size = UDim2.fromOffset(0, bh)
	self._badge_text.TextSize = math.floor(bh * 0.62)
	self:_size_badge()
	self:set_min_size(self:size_px())
end

function ArsenalButton._size_badge(self)
	local bh = self._badge_h or 24
	local w = bh * 0.6 + 3 + #self._badge_text.Text * bh * 0.4 + bh * 0.7
	self._badge.Size = UDim2.fromOffset(math.max(bh * 1.8, w), bh)
end

--- Follow the session's inventory (the Stars balance).
function ArsenalButton.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	s.inventory_changed:Connect(function()
		self:refresh()
	end)
	self:refresh()
end

function ArsenalButton.refresh(self)
	local s = self.ctx.session
	local inv = if s ~= nil then s.inventory else nil
	local stars = if inv ~= nil then (tonumber(inv.stars) or 0) else 0
	local loaded = inv ~= nil and inv.loaded == true
	self._badge.Visible = loaded
	if stars == self._stars then
		return
	end
	local grew = self._stars >= 0 and stars > self._stars
	self._stars = stars
	self._badge_text.Text = commas(stars)
	self:_size_badge()
	if grew then
		self._badge_scale.Scale = 1.5
		tween(self._badge_scale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

function ArsenalButton._process(self, dt: number)
	if not self:is_visible_in_tree() then
		return
	end
	self._t += dt
	local t = self._t
	local s = self._s or 100
	local bob = math.sin(t * 2.0) * s * 0.018
	self._shield.Position = UDim2.fromOffset(s * 0.5, self._cy + bob)
	self._shade.Position = UDim2.fromOffset(s * 0.5, self._cy + bob + s * 0.03)
	self._shield.Rotation = math.sin(t * 1.3) * 3
	self._shade.Rotation = self._shield.Rotation
	self._glow.ImageTransparency = 0.56 - 0.12 * (0.5 + 0.5 * math.sin(t * 3.2))
	self._rays.Rotation = (self._rays.Rotation - dt * 12) % 360
	-- a twinkle on the shield now and then
	local k = (t % 2.6) / 0.9
	if k < 1 then
		local v = math.sin(k * math.pi)
		self._spark.ImageTransparency = 1 - v * 0.9
		self._spark.Rotation = k * 90
		self._spark.Position = UDim2.fromOffset(s * 0.66, self._cy - s * 0.2 + bob)
	else
		self._spark.ImageTransparency = 1
	end
end

return ArsenalButton
