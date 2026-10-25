--!nonstrict
-- The starter pack's offer (Data/Starter; 2026-10-15: the starter pack at 39 Robux, on sale for a
-- limited time only). A window over the title: LIMITED-TIME OFFER,
-- STARTER PACK, the three items it unlocks (their shop renders on a glow of their colour, name and one
-- line), the regular price struck through beside the offer's with a red "-76%" sticker (both Roblox's
-- live prices: the discount is always the real one), ENDS IN 47:59:12 counting down, "Then it's gone for
-- good." (the pack goes, not just its price), BUY NOW and NOT NOW.
--
-- It opens by itself on the title once nothing else is going on (UIRoot._starter_auto): the first time
-- (the server's clock starts then: Session.starter_seen) and once a session after that while the
-- offer runs; the title's starter button (StarterButton) opens it any time. NOT NOW or a press outside
-- the window closes it. BUY NOW opens Roblox's prompt; the server's receipt unlocks the items (server/Purchases),
-- the inventory says so and the window closes with the unlock sound.
--
-- Built at DESIGN logical px and scaled to fit (a UIScale), the same layout on phones and desktop.
-- Signals: closed.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local Signal = UITheme.core("Signal")
local Prices = require("./Prices")

local IS_ROBLOX = typeof(game) == "Instance"
local function shared(folder: string, name: string): any
	if IS_ROBLOX then
		return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront")[folder][name]) :: any
	end
	return (require :: any)("../../shared/" .. folder .. "/" .. name)
end
local Starter = shared("Data", "Starter")
local Catalog = shared("Data", "Arsenal")
local Products = shared("Data", "Products")
local Art: any = (function()
	local ok, m = pcall(shared, "Assets", "ArsenalArt")
	return if ok and type(m) == "table" then m else {}
end)()
local TweenService = if IS_ROBLOX then game:GetService("TweenService") else nil

local StarterOffer = W.class(W.Control)

--- The window as designed, logical px; it is scaled down to fit the screen (up to MAX_K on big ones).
StarterOffer.DESIGN = Vector2.new(640, 340)
StarterOffer.MAX_K = 1.25
--- A purchase whose unlock never shows up gives up waiting after this long (it is saved on the server).
StarterOffer.WAIT_S = 30.0

local GOLD = Color3.fromRGB(255, 200, 61)
local GOLD_LIGHT = Color3.fromRGB(255, 232, 160)
local RED = Color3.fromRGB(232, 46, 56)
local RED_DARK = Color3.fromRGB(150, 16, 34)
local INK = Color3.fromRGB(52, 28, 2)
local WHITE = Color3.new(1, 1, 1)
local MUTED = Color3.fromRGB(168, 182, 214)
local NIGHT = Color3.fromRGB(8, 12, 26)
local ROBUX = "rbxasset://textures/ui/common/robux@3x.png"
local FONT_H = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Heavy)
local FONT_B = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Bold)
local FONT_M = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Medium)

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

local function c3(hex: number): Color3
	return Color3.fromRGB((hex // 65536) % 256, (hex // 256) % 256, hex % 256)
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT_B
	props.TextColor3 = props.TextColor3 or WHITE
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	return new("TextLabel", props, parent)
end

--- 7 hours 5 minutes 9 seconds -> "7:05:09" (always hours, so the width holds still).
function StarterOffer.clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60)
end

--- The offer's price, the three items' regular prices added up, and the discount in whole percent:
--- Roblox's live prices (UI/Prices), Data/Products' until it answers.
function StarterOffer.prices(): (number, number, number)
	local price = Prices.robux(Starter.PRODUCT)
	local regular = 0
	for _, k in Starter.ITEMS do
		local it = Catalog.item(k)
		if it ~= nil then
			regular += Prices.robux(it.product)
		end
	end
	local off = if regular > 0 then math.floor((1 - price / regular) * 100 + 0.5) else 0
	return price, regular, math.clamp(off, 0, 99)
end

--- Prices.changed (for the title's button).
function StarterOffer.prices_changed(): any
	return Prices.changed
end

function StarterOffer.new(c: any)
	local self = setmetatable({}, StarterOffer.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.is_open = false
	--- a purchase on its way: { phase = "prompt" | "granting", since }
	self._pending = nil :: any
	self._t = 0.0
	self._sweep = 0.0
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self:_build()
	self:_connect(Prices.changed:Connect(function()
		if self.is_open then
			self:refresh()
		end
	end))
	if IS_ROBLOX then
		game:GetService("MarketplaceService").PromptProductPurchaseFinished:Connect(function(_u, product_id, purchased)
			self:_on_prompt_done(product_id, purchased)
		end)
	end
	self:set_process(true)
	return self
end

function StarterOffer._build(self)
	local root = self.gui
	root.ClipsDescendants = false
	-- the dim: a press on it (outside the window) closes
	local dim = new("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(2, 4, 12),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 60,
	}, root)
	dim.Activated:Connect(function()
		self:close()
	end)
	self._dim = dim
	local D = StarterOffer.DESIGN
	local win = new("Frame", {
		Name = "StarterWindow",
		Active = true, -- (a press on the window doesn't reach the dim)
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(16, 22, 44),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(D.X, D.Y),
		ZIndex = 61,
	}, root)
	new("UICorner", { CornerRadius = UDim.new(0, 18) }, win)
	new("UIStroke", { Color = GOLD, Thickness = 2, Transparency = 0.25, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, win)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(150, 120, 140)),
		Rotation = 90,
	}, win)
	self._scale = new("UIScale", {}, win)
	self._win = win
	local crate = UITheme.crate_art()
	-- behind the items: a warm sunburst
	self._rays = new("ImageLabel", {
		Name = "Rays",
		BackgroundTransparency = 1,
		Image = crate.rays or "",
		ImageColor3 = Color3.fromRGB(255, 120, 60),
		ImageTransparency = 0.86,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(212, 214),
		Size = UDim2.fromOffset(520, 520),
		ZIndex = 61,
	}, win)
	new("UICorner", { CornerRadius = UDim.new(0, 18) }, self._rays)
	-- head
	local tag = new("Frame", {
		Name = "Tag",
		BackgroundColor3 = RED,
		Position = UDim2.fromOffset(24, 18),
		Size = UDim2.fromOffset(176, 24),
		ZIndex = 63,
	}, win)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, tag)
	self._tag = tag
	self._tag_text = text(tag, {
		Text = "LIMITED-TIME OFFER",
		FontFace = FONT_H,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 64,
	})
	local title = text(win, {
		Text = "STARTER PACK",
		FontFace = FONT_H,
		TextSize = 40,
		Position = UDim2.fromOffset(22, 44),
		Size = UDim2.fromOffset(380, 46),
		ZIndex = 63,
	})
	new("UIGradient", { Color = ColorSequence.new(WHITE, GOLD_LIGHT), Rotation = 90 }, title)
	new("UIStroke", { Color = Color3.fromRGB(40, 12, 4), Thickness = 2, Transparency = 0.35 }, title)
	self._sub = text(win, {
		Text = "Three Arsenal unlocks, yours for good.",
		FontFace = FONT_M,
		TextSize = 14,
		TextColor3 = MUTED,
		Position = UDim2.fromOffset(24, 90),
		Size = UDim2.fromOffset(380, 20),
		ZIndex = 63,
	})
	-- the items
	self._tiles = {}
	for i, key in Starter.ITEMS do
		self._tiles[key] = self:_tile(win, Catalog.item(key), 24 + (i - 1) * 128, 120)
	end
	-- the price, right
	local sticker = new("Frame", {
		Name = "Sticker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = RED,
		Position = UDim2.fromOffset(StarterOffer.DESIGN.X - 18, 14),
		Size = UDim2.fromOffset(96, 96),
		Rotation = 12,
		ZIndex = 70,
	}, win)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, sticker)
	new("UIStroke", { Color = WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, sticker)
	new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(255, 92, 80), RED_DARK), Rotation = 90 }, sticker)
	self._sticker_scale = new("UIScale", {}, sticker)
	self._sticker = sticker
	self._off = text(sticker, {
		Text = "-76%",
		FontFace = FONT_H,
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.fromOffset(96, 32),
		ZIndex = 71,
	})
	text(sticker, {
		Text = "OFF",
		FontFace = FONT_H,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.fromOffset(96, 18),
		ZIndex = 71,
	})
	local x0 = 420
	-- the regular price, struck through
	local was = new("Frame", {
		Name = "Was",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(x0, 74),
		Size = UDim2.fromOffset(196, 26),
		ZIndex = 63,
	}, win)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, was)
	new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = ROBUX,
		ImageColor3 = MUTED,
		Size = UDim2.fromOffset(18, 18),
		LayoutOrder = 1,
		ZIndex = 63,
	}, was)
	self._was = text(was, {
		Text = "165",
		FontFace = FONT_H,
		TextSize = 24,
		TextColor3 = MUTED,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		LayoutOrder = 2,
		ZIndex = 63,
	})
	local strike = new("Frame", {
		Name = "Strike",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = RED,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(x0 + 98, 87),
		Size = UDim2.fromOffset(78, 3),
		Rotation = -8,
		ZIndex = 64,
	}, win)
	self._strike = strike
	-- the offer's price
	local now = new("Frame", {
		Name = "Now",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(x0, 100),
		Size = UDim2.fromOffset(196, 64),
		ZIndex = 63,
	}, win)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, now)
	new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = ROBUX,
		ImageColor3 = GOLD,
		Size = UDim2.fromOffset(38, 38),
		LayoutOrder = 1,
		ZIndex = 63,
	}, now)
	self._price = text(now, {
		Text = "39",
		FontFace = FONT_H,
		TextSize = 62,
		TextColor3 = GOLD,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 64),
		LayoutOrder = 2,
		ZIndex = 63,
	})
	new("UIStroke", { Color = Color3.fromRGB(60, 30, 0), Thickness = 2, Transparency = 0.3 }, self._price)
	-- the clock
	text(win, {
		Text = "ENDS  IN",
		FontFace = FONT_H,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(255, 120, 110),
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(x0, 170),
		Size = UDim2.fromOffset(196, 16),
		ZIndex = 63,
	})
	self._clock = text(win, {
		Text = "48:00:00",
		FontFace = FONT_H,
		TextSize = 30,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(x0, 186),
		Size = UDim2.fromOffset(196, 32),
		ZIndex = 63,
	})
	self._gone = text(win, {
		Text = "Then it's gone for good.",
		FontFace = FONT_M,
		TextSize = 12,
		TextColor3 = MUTED,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(x0 - 10, 218),
		Size = UDim2.fromOffset(216, 16),
		ZIndex = 63,
	})
	-- BUY NOW
	local buy = new("TextButton", {
		Name = "Buy",
		Text = "",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = WHITE,
		Position = UDim2.fromOffset(x0 + 98, 270),
		Size = UDim2.fromOffset(196, 54),
		ZIndex = 65,
	}, win)
	new("UICorner", { CornerRadius = UDim.new(0, 14) }, buy)
	new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(255, 220, 110), Color3.fromRGB(242, 150, 30)), Rotation = 90 }, buy)
	new("UIStroke", { Color = INK, Thickness = 2, Transparency = 0.2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, buy)
	self._buy_scale = new("UIScale", {}, buy)
	self._buy_text = text(buy, {
		Text = "BUY NOW",
		FontFace = FONT_H,
		TextSize = 24,
		TextColor3 = INK,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 66,
	})
	-- a light that crosses the button now and then
	local shine_clip = new("Frame", {
		Name = "Shine",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 66,
	}, buy)
	new("UICorner", { CornerRadius = UDim.new(0, 14) }, shine_clip)
	self._shine = new("Frame", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(-0.3, 0, 0.5, 0),
		Size = UDim2.new(0, 22, 1.6, 0),
		Rotation = 18,
		ZIndex = 66,
	}, shine_clip)
	self:_press_feel(buy, self._buy_scale)
	buy.Activated:Connect(function()
		self:_buy()
	end)
	-- (not `self._buy`: that is the method above, and a field of that name hid it, so every press
	-- called the button and failed: no purchase in production v86, 2026-10-16)
	self._buy_btn = buy
	-- NOT NOW
	local later = new("TextButton", {
		Name = "Later",
		Text = "NOT NOW",
		FontFace = FONT_B,
		TextSize = 14,
		TextColor3 = MUTED,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x0 + 98, 316),
		Size = UDim2.fromOffset(196, 28),
		ZIndex = 65,
	}, win)
	later.Activated:Connect(function()
		self:close()
	end)
end

--- Hover grows, a press squeezes (raw buttons: the kit's own feel isn't on them).
function StarterOffer._press_feel(_self, b: GuiButton, sc: UIScale)
	local hover = false
	b.MouseEnter:Connect(function()
		hover = true
		tween(sc, 0.12, { Scale = 1.05 })
	end)
	b.MouseLeave:Connect(function()
		hover = false
		tween(sc, 0.12, { Scale = 1 })
	end)
	b.MouseButton1Down:Connect(function()
		tween(sc, 0.08, { Scale = 0.95 })
	end)
	b.MouseButton1Up:Connect(function()
		tween(sc, 0.12, { Scale = if hover then 1.05 else 1 })
	end)
end

--- One item: its render on a glow of its colour, its name and one line (an owned one says what it pays
--- instead).
function StarterOffer._tile(_self, win: Instance, it: any, x: number, y: number): any
	local W_, H_ = 118, 196
	local top, bottom = c3(it.color[1]), c3(it.color[2])
	local tile = new("Frame", {
		Name = "Item_" .. it.key,
		BackgroundColor3 = WHITE,
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(W_, H_),
		ZIndex = 62,
	}, win)
	new("UICorner", { CornerRadius = UDim.new(0, 12) }, tile)
	new("UIGradient", { Color = ColorSequence.new(top:Lerp(NIGHT, 0.45), bottom:Lerp(NIGHT, 0.82)), Rotation = 90 }, tile)
	new("UIStroke", { Color = top:Lerp(WHITE, 0.4), Thickness = 1.5, Transparency = 0.45 }, tile)
	local crate = UITheme.crate_art()
	new("ImageLabel", {
		Name = "Glow",
		BackgroundTransparency = 1,
		Image = crate.glow or "",
		ImageColor3 = top:Lerp(WHITE, 0.25),
		ImageTransparency = 0.25,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(W_ / 2, 66),
		Size = UDim2.fromOffset(140, 130),
		ZIndex = 62,
	}, tile)
	local r = (Art.renders or {})[it.key]
	local bw, bh = 104, 112
	local iw, ih = bw, bh
	if type(r) == "table" and r.w and r.h then
		local k = math.min(bw / r.w, bh / r.h)
		iw, ih = r.w * k, r.h * k
	end
	local art = new("ImageLabel", {
		Name = "Art",
		BackgroundTransparency = 1,
		Image = if type(r) == "table" then r.id else "",
		ScaleType = Enum.ScaleType.Fit,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(W_ / 2, 66),
		Size = UDim2.fromOffset(iw, ih),
		ZIndex = 63,
	}, tile)
	text(tile, {
		Text = it.title,
		FontFace = FONT_H,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(4, 128),
		Size = UDim2.fromOffset(W_ - 8, 20),
		ZIndex = 63,
	})
	local line = text(tile, {
		Text = it.tagline,
		FontFace = FONT_M,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(214, 222, 240),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(6, 150),
		Size = UDim2.fromOffset(W_ - 12, 42),
		ZIndex = 63,
	})
	local owned = new("Frame", {
		Name = "Owned",
		BackgroundColor3 = Color3.fromRGB(38, 170, 90),
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.fromOffset(58, 18),
		Visible = false,
		ZIndex = 64,
	}, tile)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, owned)
	text(owned, {
		Text = "OWNED",
		FontFace = FONT_H,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 65,
	})
	return { tile = tile, art = art, line = line, owned = owned, it = it, y = 66 }
end

function StarterOffer.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	s.inventory_changed:Connect(function()
		self:_on_inventory()
	end)
end

function StarterOffer._offer(self): any
	local s = self.ctx.session
	local inv = if s ~= nil then s.inventory else nil
	return if inv ~= nil then inv.starter else nil
end

function StarterOffer._report(self, kind: string, a: any?, b: any?)
	local s = self.ctx.session
	if s ~= nil and type(s.report) == "function" then
		s:report(kind, a, b)
	end
end

function StarterOffer.product_id(_self): number
	local p = Products[Starter.PRODUCT]
	return if type(p) == "table" then (tonumber(p.id) or 0) else 0
end

--- `from`: "auto" (opened by itself on the title) | "button" (the title's starter button).
function StarterOffer.open(self, from: string?)
	if self.is_open then
		return
	end
	self.is_open = true
	self._pending = nil
	self:set_visible(true)
	Prices.fetch()
	self:apply_layout()
	self:refresh()
	self._dim.BackgroundTransparency = 1
	tween(self._dim, 0.2, { BackgroundTransparency = 0.25 })
	local k = self._k or 1
	self._scale.Scale = k * 0.9
	tween(self._scale, 0.3, { Scale = k }, Enum.EasingStyle.Back)
	self._sticker_scale.Scale = 0.2
	task.delay(0.15, function()
		tween(self._sticker_scale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
	self.ctx:sfx("open")
	self:_report("starter", "opened", from or "button")
end

function StarterOffer.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self.ctx:sfx("close")
	self:set_visible(false)
	self.closed:Fire()
end

--- Prices, the owned items and the button's state.
function StarterOffer.refresh(self)
	local price, regular, off = StarterOffer.prices()
	self._price.Text = tostring(price)
	self._was.Text = tostring(regular)
	self._off.Text = "-" .. tostring(off) .. "%"
	self._strike.Size = UDim2.fromOffset(28 + #tostring(regular) * 15, 3)
	local s = self.ctx.session
	local inv = if s ~= nil then s.inventory else nil
	for key, t in self._tiles do
		local have = inv ~= nil and inv.unlocks ~= nil and inv.unlocks[key] == true
		t.owned.Visible = have
		t.art.ImageTransparency = if have then 0.35 else 0
		if have then
			t.line.Text = "Owned already: you get its price in Stars"
		else
			t.line.Text = t.it.tagline
		end
	end
	local p = self._pending
	self._buy_text.Text = if p == nil then "BUY NOW" elseif p.phase == "granting" then "UNLOCKING…" else "…"
	self:_tick_clock()
end

function StarterOffer._tick_clock(self)
	local o = self:_offer()
	local left = if type(o) == "table" and o.state == "active" and o.ends_at ~= nil
		then o.ends_at - os.clock()
		else Starter.DURATION_S
	self._clock.Text = StarterOffer.clock(left)
end

function StarterOffer._buy(self)
	if self._pending ~= nil then
		return
	end
	local id = self:product_id()
	self:_report("starter", "clicked")
	if id == 0 or not IS_ROBLOX then
		self.ctx:sfx("deny", -4.0)
		return
	end
	self._pending = { phase = "prompt", since = os.clock() }
	local ok = pcall(function()
		game:GetService("MarketplaceService")
			:PromptProductPurchase(game:GetService("Players").LocalPlayer, id)
	end)
	if not ok then
		self._pending = nil
	end
	self:refresh()
end

function StarterOffer._on_prompt_done(self, product_id: number, purchased: boolean)
	local p = self._pending
	if p == nil or product_id ~= self:product_id() then
		return
	end
	if not purchased then
		if p.phase == "prompt" then
			self._pending = nil
			self:refresh()
		end
		return
	end
	-- bought: the server's receipt unlocks the items, and the inventory says so
	p.phase = "granting"
	p.since = os.clock()
	self:refresh()
	self:_on_inventory()
end

--- True when every item of the pack is unlocked.
function StarterOffer._all_unlocked(self): boolean
	local s = self.ctx.session
	local u = if s ~= nil and s.inventory ~= nil then s.inventory.unlocks else nil
	if u == nil then
		return false
	end
	for _, k in Starter.ITEMS do
		if not u[k] then
			return false
		end
	end
	return true
end

--- The inventory moved: a purchase that landed ends here (the offer is gone, its items unlocked; the
--- receipt can come before Roblox's prompt says it closed).
function StarterOffer._on_inventory(self)
	local p = self._pending
	if p ~= nil and self:_offer() == false and self:_all_unlocked() then
		self._pending = nil
		--- (UIRoot: the items' own "unlocked!" toasts give way to this one)
		self.bought_at = os.clock()
		self.ctx:sfx("unlock")
		if self.ui_notice ~= nil then
			self.ui_notice("Starter Pack unlocked! Mega Nuke, Scattershot and 2x Stars are yours.")
		end
		self:close()
		return
	end
	if self.is_open then
		local o = self:_offer()
		if (o == false or o == nil) and p == nil then
			self:close() -- (it ended, or was bought elsewhere)
			return
		end
		self:refresh()
	end
end

function StarterOffer._process(self, dt: number)
	if not self.is_open then
		return
	end
	self._t += dt
	self._rays.Rotation = (self._rays.Rotation + dt * 8) % 360
	-- the sticker breathes; the button's light crosses every few seconds
	self._sticker.Rotation = 12 + math.sin(self._t * 2.4) * 3
	self._sweep += dt
	if self._sweep >= 2.6 then
		self._sweep = 0
		self._shine.Position = UDim2.new(-0.3, 0, 0.5, 0)
		tween(self._shine, 0.6, { Position = UDim2.new(1.3, 0, 0.5, 0) })
	end
	-- the items float a little
	local i = 0
	for _, t in self._tiles do
		i += 1
		t.art.Position = UDim2.fromOffset(59, t.y + math.sin(self._t * 1.6 + i * 1.1) * 3)
	end
	self:_tick_clock()
	local p = self._pending
	local o = self:_offer()
	if p == nil and type(o) == "table" and o.ends_at ~= nil and o.ends_at - os.clock() <= 0 then
		self:close() -- (time's up while it stood open: gone for good)
		return
	end
	if p ~= nil and p.phase == "granting" and os.clock() - p.since > StarterOffer.WAIT_S then
		self._pending = nil
		if self.ui_notice ~= nil then
			self.ui_notice("Your Starter Pack is saved and will unlock in a moment.")
		end
		self:close()
	end
end

function StarterOffer.apply_layout(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local D = StarterOffer.DESIGN
	local k = math.min((area.Width - 32) / D.X, (area.Height - 24) / D.Y, StarterOffer.MAX_K)
	k = math.max(k, 0.3)
	self._k = k * UITheme.scale
	self._scale.Scale = self._k
	local u = UITheme.scale
	self._win.Position = UDim2.fromOffset(
		(area.Min.X + area.Width * 0.5) * u,
		(area.Min.Y + area.Height * 0.5) * u
	)
end

return StarterOffer
