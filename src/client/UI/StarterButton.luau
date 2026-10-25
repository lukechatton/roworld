--!nonstrict
-- The title screen's starter pack button, under the Arsenal and crate buttons, while the starter pack's
-- offer runs (Data/Starter; 2026-10-15: available for a limited time only): a red card with the
-- Mega Nuke's render, STARTER PACK, the regular price struck through
-- beside the offer's, ENDS IN and the clock, a red "-76%" sticker on its corner and a light that
-- crosses it every few seconds. pressed() -> UIRoot opens the offer (StarterOffer). Hidden when there
-- is no running offer.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local Signal = UITheme.core("Signal")
local StarterOffer = require("./StarterOffer")

local IS_ROBLOX = typeof(game) == "Instance"
local function shared(folder: string, name: string): any
	if IS_ROBLOX then
		return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront")[folder][name]) :: any
	end
	return (require :: any)("../../shared/" .. folder .. "/" .. name)
end
local Art: any = (function()
	local ok, m = pcall(shared, "Assets", "ArsenalArt")
	return if ok and type(m) == "table" then m else {}
end)()
local TweenService = if IS_ROBLOX then game:GetService("TweenService") else nil

local StarterButton = W.class(W.Control)

--- The card, desktop logical px (phones: PHONE_K of it).
StarterButton.SIZE = Vector2.new(232, 82)
StarterButton.PHONE_K = 0.72
--- The light crosses it this often.
StarterButton.SHINE_S = 3.4

local GOLD = Color3.fromRGB(255, 200, 61)
local WHITE = Color3.new(1, 1, 1)
local PINK = Color3.fromRGB(255, 186, 186)
local RED = Color3.fromRGB(232, 46, 56)
local ROBUX = "rbxasset://textures/ui/common/robux@3x.png"
local FONT_H = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Heavy)

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

function StarterButton.new(c: any)
	local self = setmetatable({}, StarterButton.__mt)
	W.Control._init(self)
	self.ctx = c
	self.pressed = Signal.new()
	self._k = 1.0
	self._t = 0.0
	self._shine_t = 0.0
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:_build()
	self:set_visible(false)
	self:set_process(true)
	return self
end

function StarterButton._build(self)
	local root = self.gui
	root.ClipsDescendants = false
	local S = StarterButton.SIZE
	-- everything is built at SIZE and scaled (phones, UITheme.scale, hover / press); anchored at its middle
	-- so it pops in and grows from the centre, not from its top-left corner (2026-10-15),
	-- and at its resting scale it fills the control exactly
	local body = new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(S.X, S.Y),
		ZIndex = 1,
	}, root)
	self._scale = new("UIScale", {}, body)
	self._body = body
	local card = new("Frame", {
		Name = "Card",
		BackgroundColor3 = WHITE,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0, 14) }, card)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(236, 64, 60), Color3.fromRGB(124, 12, 34)),
		Rotation = 90,
	}, card)
	new("UIStroke", { Color = GOLD, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, card)
	local crate = UITheme.crate_art()
	new("ImageLabel", {
		Name = "Glow",
		BackgroundTransparency = 1,
		Image = crate.glow or "",
		ImageColor3 = Color3.fromRGB(255, 190, 120),
		ImageTransparency = 0.35,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(40, 42),
		Size = UDim2.fromOffset(96, 90),
		ZIndex = 3,
	}, card)
	local r = (Art.renders or {}).mega
	local iw, ih = 56, 70
	if type(r) == "table" and r.w and r.h then
		local k = math.min(64 / r.w, 70 / r.h)
		iw, ih = r.w * k, r.h * k
	end
	self._art = new("ImageLabel", {
		Name = "Art",
		BackgroundTransparency = 1,
		Image = if type(r) == "table" then r.id else "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(40, 42),
		Size = UDim2.fromOffset(iw, ih),
		ZIndex = 4,
	}, card)
	text(card, {
		Text = "STARTER PACK",
		TextSize = 17,
		Position = UDim2.fromOffset(78, 7),
		Size = UDim2.fromOffset(150, 20),
		ZIndex = 5,
	})
	-- the prices: the regular one struck through, the offer's in gold
	local row = new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(78, 28),
		Size = UDim2.fromOffset(150, 26),
		ZIndex = 5,
	}, card)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	self._was = text(row, {
		Text = "165",
		TextSize = 14,
		TextColor3 = PINK,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		LayoutOrder = 1,
		ZIndex = 5,
	})
	self._strike = new("Frame", {
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -2, 0.5, 0),
		Size = UDim2.new(1, 4, 0, 2),
		ZIndex = 6,
	}, self._was)
	new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = ROBUX,
		ImageColor3 = GOLD,
		Size = UDim2.fromOffset(18, 18),
		LayoutOrder = 2,
		ZIndex = 5,
	}, row)
	self._price = text(row, {
		Text = "39",
		TextSize = 24,
		TextColor3 = GOLD,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		LayoutOrder = 3,
		ZIndex = 5,
	})
	self._clock = text(card, {
		Text = "ENDS IN 48:00:00",
		TextSize = 12,
		TextColor3 = Color3.fromRGB(255, 232, 220),
		Position = UDim2.fromOffset(78, 56),
		Size = UDim2.fromOffset(150, 18),
		ZIndex = 5,
	})
	self._shine = new("Frame", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.7,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(-0.2, 0, 0.5, 0),
		Size = UDim2.new(0, 26, 1.8, 0),
		Rotation = 18,
		ZIndex = 7,
	}, card)
	-- the sticker, out over the corner
	local sticker = new("Frame", {
		Name = "Sticker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = RED,
		Position = UDim2.fromOffset(S.X - 14, 6),
		Size = UDim2.fromOffset(46, 46),
		Rotation = 14,
		ZIndex = 9,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, sticker)
	new("UIStroke", { Color = WHITE, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, sticker)
	self._sticker = sticker
	self._off = text(sticker, {
		Text = "-76%",
		TextSize = 14,
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
function StarterButton._k_px(self): number
	return self._k * UITheme.scale
end

--- `k`: 1 on desktop, PHONE_K on phones (also follows UITheme.scale: call it from apply_layout).
function StarterButton.set_scale(self, k: number)
	self._k = k
	self._scale.Scale = self:_k_px()
	self:set_min_size(self:size_px())
end

--- Its size in logical px.
function StarterButton.size_px(self): Vector2
	return StarterButton.SIZE * self._k
end

function StarterButton.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	s.inventory_changed:Connect(function()
		self:refresh()
	end)
	-- (Roblox's prices for this player: UI/Prices)
	self:_connect(StarterOffer.prices_changed():Connect(function()
		self:refresh()
	end))
	self:refresh()
end

function StarterButton._offer(self): any
	local s = self.ctx.session
	local inv = if s ~= nil then s.inventory else nil
	return if inv ~= nil then inv.starter else nil
end

--- Shown while the offer runs (its clock started: the window has been on the player's screen).
function StarterButton.refresh(self)
	local o = self:_offer()
	local on = type(o) == "table" and o.state == "active"
	if on ~= self.visible then
		self:set_visible(on)
		if on then
			self._scale.Scale = self:_k_px() * 0.5
			tween(self._scale, 0.35, { Scale = self:_k_px() }, Enum.EasingStyle.Back)
		end
	end
	local price, regular, off = StarterOffer.prices()
	self._price.Text = tostring(price)
	self._was.Text = tostring(regular)
	self._off.Text = "-" .. tostring(off) .. "%"
end

function StarterButton._process(self, dt: number)
	if not self.visible then
		return
	end
	self._t += dt
	local o = self:_offer()
	if type(o) == "table" and o.ends_at ~= nil then
		local left = o.ends_at - os.clock()
		if left <= 0 then
			self:set_visible(false) -- (time's up: gone for good)
			return
		end
		self._clock.Text = "ENDS IN " .. StarterOffer.clock(left)
	end
	self._sticker.Rotation = 14 + math.sin(self._t * 2.6) * 4
	self._art.Rotation = math.sin(self._t * 1.7) * 3
	self._shine_t += dt
	if self._shine_t >= StarterButton.SHINE_S then
		self._shine_t = 0
		self._shine.Position = UDim2.new(-0.2, 0, 0.5, 0)
		tween(self._shine, 0.7, { Position = UDim2.new(1.2, 0, 0.5, 0) })
	end
end

return StarterButton
