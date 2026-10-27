--!nonstrict
-- The title screen's RoWorld General button (Data/Subscription; 2026-10-27), under the flag shop's and
-- the starter pack's: a night-blue card edged in gold, a general's three stars on a slowly turning
-- sunburst, GENERAL in gold, a line that cycles through what a General gets, a gold MONTHLY tab on its
-- corner, a gold glow breathing behind it, a light that crosses it every few seconds and a star that
-- glints now and then. The first
-- version (a plain glass button reading ROWORLD GENERAL) was easy to miss. A General sees GENERAL and
-- "Your perks are on". pressed() -> UIRoot opens the window (GeneralOffer). Hidden where the
-- subscription doesn't exist (Subscription.id() == "").
local UITheme = require("./UITheme")
local W = require("./Widgets")
local UICtx = require("./UICtx")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local TweenService = if IS_ROBLOX then game:GetService("TweenService") else nil
local Subscription = UICtx.data("Subscription")

local GeneralButton = W.class(W.Control)

--- The card, desktop logical px (phones: PHONE_K of it), as the starter pack's.
GeneralButton.SIZE = Vector2.new(232, 82)
GeneralButton.PHONE_K = 0.72
--- The light crosses it this often; the line under GENERAL changes this often.
GeneralButton.SHINE_S = 3.8
GeneralButton.LINE_S = 2.6

local GOLD = Color3.fromRGB(255, 205, 86)
local GOLD_LIGHT = Color3.fromRGB(255, 238, 178)
local GOLD_DARK = Color3.fromRGB(176, 120, 22)
local INK = Color3.fromRGB(46, 28, 2)
local WHITE = Color3.new(1, 1, 1)
local FONT_H = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Heavy)
local FONT_B = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Bold)

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

local function text(parent: Instance, props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT_H
	props.TextColor3 = props.TextColor3 or WHITE
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props, parent)
end

--- What a General gets, one line at a time under GENERAL.
function GeneralButton.lines(): { string }
	return {
		"A free crate every day",
		string.format("+%d%% Stars every match", math.floor(Subscription.STARS_BONUS * 100 + 0.5)),
		"A new skin every month",
	}
end

function GeneralButton.new(c: any)
	local self = setmetatable({}, GeneralButton.__mt)
	W.Control._init(self)
	self.ctx = c
	self.pressed = Signal.new()
	self._k = 1.0
	self._t = 0.0
	self._shine_t = GeneralButton.SHINE_S - 1.0
	self._line_t = 0.0
	self._line = 1
	self._on = false
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:_build()
	self:set_visible(Subscription.id() ~= "")
	self:set_process(true)
	return self
end

function GeneralButton._build(self)
	local root = self.gui
	root.ClipsDescendants = false
	local S = GeneralButton.SIZE
	-- built at SIZE and scaled (phones, UITheme.scale, hover / press), anchored at its middle
	local body = new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(S.X, S.Y),
		ZIndex = 1,
	}, root)
	self._scale = new("UIScale", {}, body)
	-- a gold glow behind the card, breathing (_process)
	self._halo = new("ImageLabel", {
		Name = "Halo",
		BackgroundTransparency = 1,
		Image = UITheme.crate_art().glow or "",
		ImageColor3 = GOLD,
		ImageTransparency = 0.7,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.45, 2.1),
		ZIndex = 1,
	}, body)
	local card = new("Frame", {
		Name = "Card",
		BackgroundColor3 = WHITE,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0, 14) }, card)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(34, 48, 92), Color3.fromRGB(8, 12, 30)),
		Rotation = 90,
	}, card)
	-- a gold edge with a highlight that travels round it
	local stroke =
		new("UIStroke", { Color = WHITE, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, card)
	self._edge = new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, GOLD_DARK),
			ColorSequenceKeypoint.new(0.45, GOLD),
			ColorSequenceKeypoint.new(0.5, GOLD_LIGHT),
			ColorSequenceKeypoint.new(0.55, GOLD),
			ColorSequenceKeypoint.new(1, GOLD_DARK),
		}),
	}, stroke)
	-- the insignia: a sunburst, a glow, three stars
	local art = UITheme.crate_art()
	self._rays = new("ImageLabel", {
		Name = "Rays",
		BackgroundTransparency = 1,
		Image = art.rays or "",
		ImageColor3 = GOLD,
		ImageTransparency = 0.72,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(42, 41),
		Size = UDim2.fromOffset(120, 120),
		ZIndex = 3,
	}, card)
	new("ImageLabel", {
		Name = "Glow",
		BackgroundTransparency = 1,
		Image = art.glow or "",
		ImageColor3 = Color3.fromRGB(255, 196, 90),
		ImageTransparency = 0.45,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(42, 41),
		Size = UDim2.fromOffset(92, 84),
		ZIndex = 3,
	}, card)
	local star = UITheme.icon("star") or ""
	local function star_at(x: number, y: number, px: number, rot: number): ImageLabel
		return new("ImageLabel", {
			BackgroundTransparency = 1,
			Image = star,
			ImageColor3 = GOLD,
			ScaleType = Enum.ScaleType.Fit,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(px, px),
			Rotation = rot,
			ZIndex = 4,
		}, card)
	end
	star_at(19, 47, 22, -12)
	star_at(65, 47, 22, 12)
	self._star = star_at(42, 39, 38, 0)
	self._glint = new("ImageLabel", {
		Name = "Glint",
		BackgroundTransparency = 1,
		Image = art.sparkle or "",
		ImageColor3 = WHITE,
		ImageTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(52, 26),
		Size = UDim2.fromOffset(26, 26),
		ZIndex = 5,
	}, card)
	-- the words
	text(card, {
		Text = "ROWORLD",
		FontFace = FONT_B,
		TextSize = 11,
		TextColor3 = GOLD_LIGHT,
		TextTransparency = 0.15,
		Position = UDim2.fromOffset(84, 9),
		Size = UDim2.fromOffset(140, 14),
		ZIndex = 6,
	})
	local title = text(card, {
		Text = "GENERAL",
		TextSize = 25,
		Position = UDim2.fromOffset(83, 21),
		Size = UDim2.fromOffset(140, 28),
		ZIndex = 6,
	})
	new("UIGradient", { Color = ColorSequence.new(GOLD_LIGHT, GOLD), Rotation = 90 }, title)
	new("UIStroke", { Color = INK, Thickness = 1.5, Transparency = 0.2 }, title)
	self._title = title
	self._perk = text(card, {
		Text = GeneralButton.lines()[1],
		FontFace = FONT_B,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(220, 228, 250),
		Position = UDim2.fromOffset(84, 52),
		Size = UDim2.fromOffset(142, 18),
		ZIndex = 6,
	})
	self._shine = new("Frame", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.78,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(-0.2, 0.5),
		Size = UDim2.new(0, 24, 1.8, 0),
		Rotation = 18,
		ZIndex = 7,
	}, card)
	-- the tab, out over the corner
	local tab = new("Frame", {
		Name = "Tab",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = WHITE,
		Position = UDim2.fromOffset(S.X - 30, 1),
		Size = UDim2.fromOffset(64, 20),
		Rotation = 6,
		ZIndex = 9,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, tab)
	new("UIGradient", { Color = ColorSequence.new(GOLD_LIGHT, GOLD), Rotation = 90 }, tab)
	new(
		"UIStroke",
		{ Color = INK, Thickness = 1.5, Transparency = 0.3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border },
		tab
	)
	self._tab = tab
	self._tab_text = text(tab, {
		Text = "MONTHLY",
		TextSize = 11,
		TextColor3 = INK,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
	})
	-- the hit area
	local hit = new("TextButton", {
		Name = "Hit",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 20,
	}, body)
	local hover = false
	hit.MouseEnter:Connect(function()
		hover = true
		tween(self._scale, 0.12, { Scale = self:_k_px() * 1.05 })
	end)
	hit.MouseLeave:Connect(function()
		hover = false
		tween(self._scale, 0.12, { Scale = self:_k_px() })
	end)
	hit.MouseButton1Down:Connect(function()
		tween(self._scale, 0.08, { Scale = self:_k_px() * 0.95 })
	end)
	hit.MouseButton1Up:Connect(function()
		tween(self._scale, 0.12, { Scale = self:_k_px() * (if hover then 1.05 else 1) })
	end)
	hit.Activated:Connect(function()
		self.ctx:sfx("click")
		self.pressed:Fire()
	end)
end

--- The UIScale for the card's px: the phone factor times UITheme.scale.
function GeneralButton._k_px(self): number
	return self._k * UITheme.scale
end

--- `k`: 1 on desktop, PHONE_K on phones (also follows UITheme.scale: call it from apply_layout).
function GeneralButton.set_scale(self, k: number)
	self._k = k
	self._scale.Scale = self:_k_px()
	self:set_min_size(self:size_px())
end

--- Its size in logical px.
function GeneralButton.size_px(self): Vector2
	return GeneralButton.SIZE * self._k
end

--- Subscribed or not (Session.general): a General's card says so instead of selling.
function GeneralButton.refresh(self)
	local s = self.ctx.session
	local on = s ~= nil and s.general == true
	self:set_visible(Subscription.id() ~= "")
	if on == self._on then
		return
	end
	self._on = on
	self._tab_text.Text = if on then "ACTIVE" else "MONTHLY"
	self._perk.Text = if on then "Your perks are on" else GeneralButton.lines()[self._line]
	self._perk.TextTransparency = 0
end

function GeneralButton._process(self, dt: number)
	if not self.visible then
		return
	end
	self._t += dt
	local t = self._t
	self._rays.Rotation = (t * 12) % 360
	self._star.Size = UDim2.fromOffset(38 + math.sin(t * 2.2) * 2.5, 38 + math.sin(t * 2.2) * 2.5)
	self._edge.Rotation = (t * 70) % 360
	self._halo.ImageTransparency = 0.68 + math.sin(t * 1.8) * 0.12
	self._tab.Rotation = 6 + math.sin(t * 2.4) * 3
	-- a glint on the big star, briefly, every couple of seconds
	local g = (t % 2.3) / 2.3
	self._glint.ImageTransparency = if g < 0.18 then 1 - math.sin(g / 0.18 * math.pi) * 0.9 else 1
	self._glint.Rotation = g * 180
	-- the line under GENERAL: what a General gets, in turn (cross-fading)
	if not self._on then
		self._line_t += dt
		local lines = GeneralButton.lines()
		local left = GeneralButton.LINE_S - self._line_t
		if left <= 0 then
			self._line_t = 0
			self._line = self._line % #lines + 1
			self._perk.Text = lines[self._line]
		end
		local fade = math.min(self._line_t / 0.25, math.max(left, 0) / 0.25, 1)
		self._perk.TextTransparency = 1 - fade
	end
	self._shine_t += dt
	if self._shine_t >= GeneralButton.SHINE_S then
		self._shine_t = 0
		self._shine.Position = UDim2.fromScale(-0.2, 0.5)
		tween(self._shine, 0.7, { Position = UDim2.fromScale(1.2, 0.5) })
	end
end

return GeneralButton
