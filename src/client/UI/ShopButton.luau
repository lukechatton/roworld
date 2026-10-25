--!nonstrict
-- The title screen's flag shop button (Data/Shop; 2026-10-22: a daily rotating shop of flags for
-- sale), under the Arsenal and crate buttons: a purple card with the shop's flags taking
-- turns on its left, FLAG SHOP, the running set's name (HALLOWEEN FLAGS) or NEW FLAGS DAILY, and the
-- clock to the next shop. A NEW sticker until the player has opened today's shop (setting
-- "shop_seen_day"). pressed() -> UIRoot opens the shop (FlagShop). Shown while the shop has something
-- on sale here (FlagShop.on_sale).
local UITheme = require("./UITheme")
local W = require("./Widgets")
local Signal = UITheme.core("Signal")
local FlagShop = require("./FlagShop")

local IS_ROBLOX = typeof(game) == "Instance"
local function shared(name: string): any
	if IS_ROBLOX then
		return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data[name]) :: any
	end
	return (require :: any)("../../shared/Data/" .. name)
end
local Shop = shared("Shop")
local Cosmetics = shared("Cosmetics")
local TweenService = if IS_ROBLOX then game:GetService("TweenService") else nil

local ShopButton = W.class(W.Control)

--- The card, desktop logical px (phones: PHONE_K of it).
ShopButton.SIZE = Vector2.new(232, 74)
ShopButton.PHONE_K = 0.72
--- A new flag on the card this often.
ShopButton.TURN_S = 2.6

local WHITE = Color3.new(1, 1, 1)
local PUMPKIN = Color3.fromRGB(255, 160, 60)
local LILAC = Color3.fromRGB(214, 196, 255)
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

function ShopButton.new(c: any)
	local self = setmetatable({}, ShopButton.__mt)
	W.Control._init(self)
	self.ctx = c
	self.pressed = Signal.new()
	self._k = 1.0
	self._turn_t = 0.0
	self._turn = 0
	self._day = -1
	self._keys = {}
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:_build()
	self:set_visible(false)
	self:set_process(true)
	return self
end

function ShopButton._build(self)
	local root = self.gui
	root.ClipsDescendants = false
	local S = ShopButton.SIZE
	-- (built at SIZE and scaled, anchored at its middle: it grows from the centre, like the starter's)
	local body = new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(S.X, S.Y),
		ZIndex = 1,
	}, root)
	self._scale = new("UIScale", {}, body)
	local card = new("Frame", {
		Name = "Card",
		BackgroundColor3 = WHITE,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0, 14) }, card)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(122, 62, 214), Color3.fromRGB(42, 18, 92)),
		Rotation = 90,
	}, card)
	new("UIStroke", { Color = LILAC, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, card)
	self._flag = new("ImageLabel", {
		Name = "Flag",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(42, 37),
		Size = UDim2.fromOffset(66, 44),
		Rotation = -4,
		ZIndex = 4,
	}, card)
	new("UICorner", { CornerRadius = UDim.new(0, 5) }, self._flag)
	new("UIStroke", { Color = WHITE, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, self._flag)
	self._flag_scale = new("UIScale", {}, self._flag)
	text(card, {
		Text = "FLAG SHOP",
		TextSize = 17,
		Position = UDim2.fromOffset(84, 8),
		Size = UDim2.fromOffset(144, 20),
		ZIndex = 5,
	})
	self._what = text(card, {
		Text = "NEW FLAGS DAILY",
		TextSize = 12,
		TextColor3 = LILAC,
		Position = UDim2.fromOffset(84, 30),
		Size = UDim2.fromOffset(144, 16),
		ZIndex = 5,
	})
	self._clock = text(card, {
		Text = "NEW IN 0:00:00",
		TextSize = 12,
		TextColor3 = Color3.fromRGB(236, 230, 255),
		Position = UDim2.fromOffset(84, 48),
		Size = UDim2.fromOffset(144, 16),
		ZIndex = 5,
	})
	local sticker = new("Frame", {
		Name = "New",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(46, 190, 104),
		Position = UDim2.fromOffset(S.X - 12, 4),
		Size = UDim2.fromOffset(44, 22),
		Rotation = 10,
		Visible = false,
		ZIndex = 9,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, sticker)
	new("UIStroke", { Color = WHITE, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, sticker)
	text(sticker, {
		Text = "NEW",
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
	})
	self._sticker = sticker
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

function ShopButton._k_px(self): number
	return self._k * UITheme.scale
end

--- `k`: 1 on desktop, PHONE_K on phones (also follows UITheme.scale: call it from apply_layout).
function ShopButton.set_scale(self, k: number)
	self._k = k
	self._scale.Scale = self:_k_px()
	self:set_min_size(self:size_px())
end

function ShopButton.size_px(self): Vector2
	return ShopButton.SIZE * self._k
end

--- Shown while the shop sells something here; today's flags (the set's first) take turns on it.
function ShopButton.refresh(self)
	local on = FlagShop.on_sale()
	if on ~= self.visible then
		self:set_visible(on)
		if on then
			self._scale.Scale = self:_k_px() * 0.5
			tween(self._scale, 0.35, { Scale = self:_k_px() }, Enum.EasingStyle.Back)
		end
	end
	local t = FlagShop.now()
	local c = FlagShop.contents(t)
	self._day = c.day
	local keys = {}
	for _, s in c.sets do
		for _, k in s.keys do
			table.insert(keys, k)
		end
	end
	for _, k in c.daily do
		table.insert(keys, k)
	end
	self._keys = keys
	self._what.Text = if #c.sets > 0 then string.upper(c.sets[1].name) .. " FLAGS" else "NEW FLAGS DAILY"
	self._what.TextColor3 = if #c.sets > 0 then PUMPKIN else LILAC
	self._sticker.Visible = self.ctx:setting("shop_seen_day", -1) ~= c.day
	self:_show_flag()
end

function ShopButton._show_flag(self)
	local key = self._keys[(self._turn % math.max(1, #self._keys)) + 1]
	local it = if key ~= nil then Cosmetics.item(Shop.item_id(key)) else nil
	if it == nil then
		self._flag.Image = ""
		return
	end
	local image, x, y, w, h = Cosmetics.flag_big(it)
	self._flag.Image = image
	self._flag.ImageRectOffset = Vector2.new(x, y)
	self._flag.ImageRectSize = Vector2.new(w, h)
end

function ShopButton._process(self, dt: number)
	if not self.visible then
		return
	end
	local t = FlagShop.now()
	if Shop.day(t) ~= self._day then
		self:refresh()
	end
	self._clock.Text = "NEW IN " .. FlagShop.clock(Shop.next_in(t))
	self._turn_t += dt
	if self._turn_t >= ShopButton.TURN_S and #self._keys > 1 then
		self._turn_t = 0
		self._turn += 1
		self:_show_flag()
		self._flag_scale.Scale = 0.6
		tween(self._flag_scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	self._flag.Rotation = -4 + math.sin(os.clock() * 1.6) * 2
end

return ShopButton
