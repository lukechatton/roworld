--!nonstrict
-- The flag shop (2026-10-22: a daily rotating shop of flags for sale; Data/Shop,
-- docs/flag-shop.md): a modal from the title's shop button. A running limited set first (Halloween:
-- the whole set, ENDS IN its clock), then today's flags (Data/Shop.daily, NEW IN the clock to 00:00 UTC).
-- Each card: the flag, its name and rarity, and its button: the price (Roblox's for this player:
-- UI/Prices), WEAR for one owned, WEARING for the one on. A purchase goes like the Locker's: Roblox's
-- prompt, the server stores the flag and puts it on (server/Purchases), the card turns to WEARING.
-- 2026-10-24 (from the analytics suggestions): a section's Legendary gets a FEATURED card two
-- cards wide and two tall, and a set with a bundle (Data/Shop.SETS `bundle`) a banner under its head:
-- all of it for one price, what that saves, flags already owned paying back Stars.
-- Signals: closed.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Prices = require("./Prices")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local function shared(name: string): any
	if IS_ROBLOX then
		return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data[name]) :: any
	end
	return (require :: any)("../../shared/Data/" .. name)
end
local Shop = shared("Shop")
local Cosmetics = shared("Cosmetics")
local ShopLayout = require("./ShopLayout")
local Products = shared("Products")

local FlagShop = W.class(W.Control)

--- A card, logical px (phones: CARD_PHONE).
FlagShop.CARD = Vector2.new(150, 178)
FlagShop.CARD_PHONE = Vector2.new(124, 152)
FlagShop.GAP = 10
--- Cards in a row on desktop (the window is as wide as that).
FlagShop.COLS = 4
--- After a purchase, how long the card waits for the server's word before saying it's on its way.
FlagShop.GRANT_WAIT_S = 30
--- The bundle banner's height (logical px).
FlagShop.BANNER_H = 46

local FONT = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Bold)
local FONT_H = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Heavy)
local FONT_M = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Medium)
local ROBUX = "rbxasset://textures/ui/common/robux@3x.png"
local WHITE = Color3.new(1, 1, 1)
local GOLD = Color3.fromRGB(255, 200, 61)
local PUMPKIN = Color3.fromRGB(255, 140, 40)
local MUTED = Color3.fromRGB(160, 168, 190)

local function c3(hex: number): Color3
	return Color3.fromRGB((hex // 65536) % 256, (hex // 256) % 256, hex % 256)
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

--- "5:12:09" under a day, "3d 4h" past it.
function FlagShop.clock(s: number): string
	s = math.max(0, math.floor(s))
	if s >= 86400 then
		return string.format("%dd %dh", s // 86400, (s % 86400) // 3600)
	end
	return string.format("%d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60)
end

--- Unix time as the server has it (every client agrees on the day).
function FlagShop.now(): number
	if IS_ROBLOX then
		local ok, t = pcall(function()
			return workspace:GetServerTimeNow()
		end)
		if ok and type(t) == "number" then
			return t
		end
	end
	return os.time()
end

--- What the shop shows at `t`: { day, sets = Shop.sets(t), daily = { keys } }.
function FlagShop.contents(t: number): any
	return { day = Shop.day(t), sets = Shop.sets(t), daily = Shop.daily(Shop.day(t)) }
end

--- The shop has something to sell here: a flag whose product exists (Studio: always).
function FlagShop.on_sale(): boolean
	if IS_ROBLOX and game:GetService("RunService"):IsStudio() then
		return #Shop.flags() > 0
	end
	for _, f in Shop.flags() do
		local p = Products["shop_" .. f.key]
		if p ~= nil and p.id ~= 0 then
			return true
		end
	end
	return false
end

function FlagShop.new(c: any)
	local self = setmetatable({}, FlagShop.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.is_open = false
	self._cards = {}
	self._clocks = {}
	self._pending = nil
	self._day = -1
	self:_connect(Prices.changed:Connect(function()
		if self.is_open then
			self:_rebuild()
		end
	end))
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self._dim = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.78))
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._dim.gui_input:Connect(function(e)
		-- (a press on the window's own ground reaches the dim too: only one outside it closes)
		if e.pressed and not self._panel:has_global_point(e.global_position) then
			self:close()
		end
	end)
	self:add_child(self._dim)
	self._panel = GlassPanel.new(22.0, 18.0, 18, true, 34)
	self._panel:set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.96))
	self:add_child(self._panel)
	local v = UITheme.vbox(10)
	self._v = v
	self._panel:add_child(v)
	local head = UITheme.hbox(12)
	local title = UITheme.label("FLAG SHOP", 20, 800, UITheme.TEXT, 3)
	title.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(title)
	self._sub = UITheme.label("New flags every day", 13, 600, UITheme.TEXT_2)
	self._sub.size_flags_horizontal = W.EXPAND_FILL
	self._sub.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._sub)
	local close = W.Button.new("", "GhostButton")
	close:set_icon("close")
	close.expand_icon = true
	close:set_min_size(Vector2.new(34, 34))
	close:add_theme_constant_override("icon_max_width", 13)
	close:add_theme_stylebox_override("normal", UITheme.empty_box(8, 8))
	close:add_theme_stylebox_override("hover", UITheme.flat(UITheme.FILL, 8, UITheme.CLEAR, 0, 8, 8))
	close.size_flags_vertical = W.SHRINK_CENTER
	close.pressed:Connect(function()
		self:close()
	end)
	head:add_child(close)
	v:add_child(head)
	local host = W.Control.new()
	host:set_mouse_filter(W.MOUSE_PASS)
	self._host = host
	v:add_child(host)
	local sf = Instance.new("ScrollingFrame")
	sf.Name = "FlagShopList"
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.Size = UDim2.fromScale(1, 1)
	sf.ScrollBarThickness = 6
	sf.ScrollBarImageColor3 = WHITE
	sf.ScrollBarImageTransparency = 0.6
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.CanvasSize = UDim2.new(0, 0, 0, 0)
	sf.ScrollingDirection = Enum.ScrollingDirection.Y
	sf.ZIndex = 40
	sf.Parent = host.gui
	host:_part(sf, "ScrollBarImageTransparency", 0.4)
	self._sf = sf
	self._list = new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, sf)
	new("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingLeft = UDim.new(0, 2) }, sf)
	if IS_ROBLOX then
		game:GetService("MarketplaceService").PromptProductPurchaseFinished:Connect(function(_u, product_id, purchased)
			self:_on_prompt_done(product_id, purchased)
		end)
	end
	return self
end

--- The session's inventory (UIRoot.setup, when the session exists).
function FlagShop.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	if s.inventory_changed then
		s.inventory_changed:Connect(function()
			self:_on_inventory()
		end)
	end
end

--- A short notice (UIRoot sets this to its toasts).
function FlagShop._toast(_self, _text: string) end

function FlagShop._report(self, a: string, b: any?)
	local s = self.ctx.session
	if s ~= nil and type(s.report) == "function" then
		s:report("flag_shop", a, b)
	end
end

function FlagShop._inv(self): any
	local s = self.ctx.session
	return if s ~= nil and s.inventory ~= nil then s.inventory else { owned = {}, equipped = {} }
end

-- ---------------------------------------------------------------------------------------------
-- Buying and wearing
-- ---------------------------------------------------------------------------------------------

function FlagShop._pressed(self, key: string)
	local id = Shop.item_id(key)
	local inv = self:_inv()
	local se = self.ctx.session
	if inv.owned[id] == true then
		if inv.equipped.flag ~= id and se ~= nil then
			self.ctx:sfx("click")
			se:equip("flag", id)
		end
		return
	end
	if self._pending ~= nil then
		return
	end
	local p = Products["shop_" .. key]
	if p == nil or p.id == 0 or not IS_ROBLOX then
		self.ctx:sfx("deny", -6.0)
		return
	end
	self:_report("clicked", key)
	self.ctx:sfx("click")
	self._pending = { key = key, product = p.id, phase = "prompt", since = os.clock() }
	self:_rebuild()
	local ok = pcall(function()
		game:GetService("MarketplaceService"):PromptProductPurchase(game:GetService("Players").LocalPlayer, p.id)
	end)
	if not ok then
		self:_cancel("Purchases aren't available right now.")
	end
end

--- A set's bundle (Products "shopset_<id>").
function FlagShop._pressed_set(self, sid: string)
	if self._pending ~= nil then
		return
	end
	local p = Products["shopset_" .. sid]
	if p == nil or p.id == 0 or not IS_ROBLOX then
		self.ctx:sfx("deny", -6.0)
		return
	end
	self:_report("clicked_pack", sid)
	self.ctx:sfx("click")
	self._pending = { set = sid, product = p.id, phase = "prompt", since = os.clock() }
	self:_rebuild()
	local ok = pcall(function()
		game:GetService("MarketplaceService"):PromptProductPurchase(game:GetService("Players").LocalPlayer, p.id)
	end)
	if not ok then
		self:_cancel("Purchases aren't available right now.")
	end
end

--- How many of set `sid`'s flags the player owns, of how many.
function FlagShop._set_owned(self, sid: string): (number, number)
	local inv = self:_inv()
	local keys = Shop.set_keys(sid)
	local n = 0
	for _, k in keys do
		if inv.owned[Shop.item_id(k)] == true then
			n += 1
		end
	end
	return n, #keys
end

function FlagShop._cancel(self, message: string?)
	self._pending = nil
	if message then
		self:_toast(message)
	end
	if self.is_open then
		self:_rebuild()
	end
end

function FlagShop._on_prompt_done(self, product_id: number, purchased: boolean)
	local p = self._pending
	if p == nil or p.phase ~= "prompt" or product_id ~= p.product then
		return
	end
	if not purchased then
		self:_cancel(nil)
		return
	end
	-- bought: the server stores the flag and says so (the inventory)
	p.phase = "grant"
	p.since = os.clock()
	self:_on_inventory()
end

function FlagShop._on_inventory(self)
	local p = self._pending
	if p ~= nil and p.phase == "grant" and p.set ~= nil then
		local n, of = self:_set_owned(p.set)
		if n >= of then
			self._pending = nil
			local set = Shop.SETS[p.set]
			self.ctx:sfx("confirm")
			self:_toast(string.format("All %d %s flags are yours.", of, if set then set.name else ""))
		end
	elseif p ~= nil and p.phase == "grant" and self:_inv().owned[Shop.item_id(p.key)] == true then
		self._pending = nil
		local f = Shop.flag(p.key)
		self.ctx:sfx("confirm")
		self:_toast((if f then f.name else "Your flag") .. " is yours: you're wearing it now.")
	end
	if self.is_open then
		self:_rebuild()
	end
end

function FlagShop.tick(self)
	local p = self._pending
	if p ~= nil then
		local limit = if p.phase == "prompt" then 180 else FlagShop.GRANT_WAIT_S
		if os.clock() - p.since > limit then
			self:_cancel(if p.phase == "prompt" then nil else "Your flag is on its way: it shows up in a moment.")
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------------------------

function FlagShop._card_size(self): Vector2
	return if self.ctx.compact then FlagShop.CARD_PHONE else FlagShop.CARD
end

function FlagShop._section(self, order: number, title: string, color: Color3, ends: number, label: string)
	local s = UITheme.scale
	local row = new("Frame", {
		Name = "Head",
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, -math.floor(12 * s), 0, math.floor(30 * s)),
		ZIndex = 41,
	}, self._sf)
	local t = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT_H,
		Text = title,
		TextColor3 = color,
		TextSize = math.floor(15 * s),
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromScale(0.62, 1),
		ZIndex = 42,
	}, row)
	local clock = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT,
		Text = "",
		TextColor3 = MUTED,
		TextSize = math.floor(12 * s),
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.38, 1),
		ZIndex = 42,
	}, row)
	table.insert(self._clocks, { label = clock, ends = ends, prefix = label })
	self._host:_part(t, "TextTransparency", 1.0)
	self._host:_part(clock, "TextTransparency", 1.0)
	table.insert(self._cards, row)
end

function FlagShop._grid(self, order: number, keys: { string })
	local s = UITheme.scale
	local cs = self:_card_size()
	local gap = FlagShop.GAP
	local list, hero = ShopLayout.order(keys)
	local cells, rows = ShopLayout.place(#list, hero, self._cols or FlagShop.COLS)
	local g = new("Frame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, -math.floor(12 * s), 0, math.floor((rows * cs.Y + (rows - 1) * gap + 14) * s)),
		ZIndex = 41,
	}, self._sf)
	for i, key in list do
		local c = cells[i]
		local big = hero and i == 1
		local size = if big then Vector2.new(cs.X * 2 + gap, cs.Y * 2 + gap) else cs
		self:_card(g, key, Vector2.new(c[1] * (cs.X + gap), c[2] * (cs.Y + gap)), size, big)
	end
	table.insert(self._cards, g)
end

--- A set's bundle under its head: ALL 6 HALLOWEEN FLAGS, what it saves at this player's prices, and
--- its price (shown while the player is missing any of the set and its product exists here).
--- Set `sid`'s bundle banner shows: it has a bundle, its product exists here (Studio: always), and the
--- player is missing some of the set.
function FlagShop._bundle_shown(self, sid: string): boolean
	local set = Shop.SETS[sid]
	local p = Products["shopset_" .. sid]
	if set == nil or set.bundle == nil or p == nil then
		return false
	end
	if p.id == 0 and not (IS_ROBLOX and game:GetService("RunService"):IsStudio()) then
		return false
	end
	local have, of = self:_set_owned(sid)
	return have < of
end

function FlagShop._bundle(self, order: number, sid: string)
	if not self:_bundle_shown(sid) then
		return
	end
	local set = Shop.SETS[sid]
	local key = "shopset_" .. sid
	local have, of = self:_set_owned(sid)
	local s = UITheme.scale
	local px = function(v: number): number
		return math.floor(v * s + 0.5)
	end
	local each = 0
	for _, k in Shop.set_keys(sid) do
		each += Prices.robux("shop_" .. k)
	end
	local price = Prices.robux(key)
	local off = if each > 0 then math.floor((1 - price / each) * 100 + 0.5) else 0
	local pending = self._pending ~= nil and self._pending.set == sid
	local h = FlagShop.BANNER_H
	local row = new("Frame", {
		Name = "Bundle",
		BackgroundColor3 = WHITE,
		LayoutOrder = order,
		Size = UDim2.new(1, -px(12), 0, px(h + 10)),
		BackgroundTransparency = 1,
		ZIndex = 41,
	}, self._sf)
	local box = new("Frame", {
		Name = "Box",
		BackgroundColor3 = WHITE,
		Size = UDim2.new(1, 0, 0, px(h)),
		ZIndex = 41,
	}, row)
	new("UICorner", { CornerRadius = UDim.new(0, px(10)) }, box)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(120, 52, 10), Color3.fromRGB(40, 18, 60)),
		Rotation = 0,
	}, box)
	local stroke =
		new("UIStroke", { Color = PUMPKIN, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, box)
	local title = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT_H,
		Text = string.format("ALL %d %s FLAGS", of, string.upper(set.name)),
		TextColor3 = WHITE,
		TextSize = px(14),
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(px(14), px(6)),
		Size = UDim2.new(1, -px(150), 0, px(18)),
		ZIndex = 42,
	}, box)
	local sub = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT,
		Text = (if off > 0 then string.format("Save %d%%", off) else "One price")
			.. (if have > 0 then "  ·  ones you own pay back Stars" else ""),
		TextColor3 = Color3.fromRGB(120, 230, 150),
		TextSize = px(11),
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(px(14), px(25)),
		Size = UDim2.new(1, -px(150), 0, px(14)),
		ZIndex = 42,
	}, box)
	local btn = new("TextButton", {
		Name = "BuyAll",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Color3.fromRGB(46, 160, 92),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -px(8), 0.5, 0),
		Size = UDim2.fromOffset(px(124), px(h - 14)),
		ZIndex = 43,
	}, box)
	new("UICorner", { CornerRadius = UDim.new(0, px(8)) }, btn)
	local inner = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 44 }, btn)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, px(4)),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, inner)
	local icon = new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = ROBUX,
		Size = UDim2.fromOffset(px(15), px(15)),
		LayoutOrder = 1,
		Visible = not pending,
		ZIndex = 45,
	}, inner)
	local label = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT_H,
		Text = if pending then "..." else tostring(price),
		TextColor3 = WHITE,
		TextSize = px(15),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, px(h - 14)),
		LayoutOrder = 2,
		ZIndex = 45,
	}, inner)
	local host = self._host
	host:_part(box, "BackgroundTransparency", 1.0)
	host:_part(stroke, "Transparency", 0.8)
	host:_part(title, "TextTransparency", 1.0)
	host:_part(sub, "TextTransparency", 1.0)
	host:_part(btn, "BackgroundTransparency", 1.0)
	host:_part(icon, "ImageTransparency", 1.0)
	host:_part(label, "TextTransparency", 1.0)
	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = Color3.fromRGB(58, 186, 110)
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = Color3.fromRGB(46, 160, 92)
	end)
	btn.Activated:Connect(function()
		self:_pressed_set(sid)
	end)
	table.insert(self._cards, row)
end

function FlagShop._card(self, parent: Instance, key: string, pos: Vector2, size: Vector2, hero: boolean)
	local f = Shop.flag(key)
	local it = Cosmetics.item(Shop.item_id(key))
	if f == nil or it == nil then
		return
	end
	local s = UITheme.scale
	local px = function(v: number): number
		return math.floor(v * s + 0.5)
	end
	local cs = size
	local inv = self:_inv()
	local owned = inv.owned[it.id] == true
	local wearing = inv.equipped.flag == it.id
	local pending = self._pending ~= nil and self._pending.key == key
	local rar = Cosmetics.rarity(f.rarity)
	local rc = c3(rar.color)
	local card = new("Frame", {
		Name = key,
		BackgroundColor3 = WHITE,
		Position = UDim2.fromOffset(px(pos.X), px(pos.Y)),
		Size = UDim2.fromOffset(px(size.X), px(size.Y)),
		ZIndex = 41,
	}, parent)
	new("UICorner", { CornerRadius = UDim.new(0, px(10)) }, card)
	local stroke = new("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = if wearing then UITheme.color3(UITheme.to_rgba(UITheme.AMBER)) else rc,
		Thickness = if wearing or hero then 2 else 1,
	}, card)
	new("UIGradient", {
		Color = ColorSequence.new(rc:Lerp(Color3.new(0, 0, 0), 0.55), Color3.fromRGB(14, 18, 34)),
		Rotation = 90,
	}, card)
	local fw = cs.X - 16
	local fh = math.floor(fw * 2 / 3)
	local img = new("ImageLabel", {
		Name = "Flag",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(px(8), px(8)),
		Size = UDim2.fromOffset(px(fw), px(fh)),
		ZIndex = 42,
	}, card)
	local image, x, y, w, h = Cosmetics.flag_big(it)
	img.Image = image
	img.ImageRectOffset = Vector2.new(x, y)
	img.ImageRectSize = Vector2.new(w, h)
	new("UICorner", { CornerRadius = UDim.new(0, px(6)) }, img)
	local name_size = if hero then (if self.ctx.compact then 15 else 18) else (if self.ctx.compact then 11 else 13)
	local name = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = if hero then FONT_H else FONT,
		Text = f.name,
		TextColor3 = WHITE,
		TextSize = px(name_size),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(px(8), px(8 + fh + 5)),
		Size = UDim2.fromOffset(px(cs.X - 16), px(name_size + 4)),
		ZIndex = 42,
	}, card)
	local sub = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT_M,
		Text = string.upper(rar.name),
		TextColor3 = rc,
		TextSize = px(if hero then 12 else 10),
		Position = UDim2.fromOffset(px(8), px(8 + fh + 9 + name_size)),
		Size = UDim2.fromOffset(px(cs.X - 16), px(14)),
		ZIndex = 42,
	}, card)
	if hero then
		-- the FEATURED chip over the flag's corner
		local chip = new("TextLabel", {
			BackgroundColor3 = GOLD,
			FontFace = FONT_H,
			Text = "FEATURED",
			TextColor3 = Color3.fromRGB(40, 24, 0),
			TextSize = px(11),
			Position = UDim2.fromOffset(px(14), px(14)),
			Size = UDim2.fromOffset(px(78), px(20)),
			ZIndex = 44,
		}, card)
		new("UICorner", { CornerRadius = UDim.new(0, px(6)) }, chip)
		self._host:_part(chip, "BackgroundTransparency", 1.0)
		self._host:_part(chip, "TextTransparency", 1.0)
	end
	-- the button: the price, WEAR / WEARING, or a moment's wait
	local bh = if hero then (if self.ctx.compact then 32 else 38) else (if self.ctx.compact then 26 else 30)
	local btn = new("TextButton", {
		Name = "Buy",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = if owned then Color3.fromRGB(46, 54, 80) else Color3.fromRGB(46, 160, 92),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -px(8)),
		Size = UDim2.fromOffset(px(cs.X - 16), px(bh)),
		ZIndex = 43,
	}, card)
	new("UICorner", { CornerRadius = UDim.new(0, px(8)) }, btn)
	local row = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 44,
	}, btn)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, px(4)),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	local text = if wearing then "WEARING" elseif owned then "WEAR" elseif pending then "..." else nil
	local parts = { btn }
	if text == nil then
		local icon = new("ImageLabel", {
			BackgroundTransparency = 1,
			Image = ROBUX,
			Size = UDim2.fromOffset(px(15), px(15)),
			LayoutOrder = 1,
			ZIndex = 45,
		}, row)
		table.insert(parts, icon)
		text = tostring(Prices.robux("shop_" .. key))
	end
	local label = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT_H,
		Text = text,
		TextColor3 = if wearing then GOLD else WHITE,
		TextSize = px(if hero then 17 else 14),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, px(bh)),
		LayoutOrder = 2,
		ZIndex = 45,
	}, row)
	local host = self._host
	host:_part(card, "BackgroundTransparency", 1.0)
	host:_part(stroke, "Transparency", if wearing then 1.0 else 0.55)
	host:_part(img, "ImageTransparency", 1.0)
	host:_part(name, "TextTransparency", 1.0)
	host:_part(sub, "TextTransparency", 1.0)
	host:_part(label, "TextTransparency", 1.0)
	for _, pt in parts do
		if pt:IsA("ImageLabel") then
			host:_part(pt, "ImageTransparency", 1.0)
		else
			host:_part(pt, "BackgroundTransparency", if wearing then 0.6 else 1.0)
		end
	end
	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = if owned then Color3.fromRGB(60, 70, 102) else Color3.fromRGB(58, 186, 110)
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = if owned then Color3.fromRGB(46, 54, 80) else Color3.fromRGB(46, 160, 92)
	end)
	btn.Activated:Connect(function()
		self:_pressed(key)
	end)
end

function FlagShop._rebuild(self)
	for _, b in self._cards do
		self._host:_drop_part(b)
		for _, d in b:GetDescendants() do
			self._host:_drop_part(d)
		end
		b:Destroy()
	end
	table.clear(self._cards)
	table.clear(self._clocks)
	local t = FlagShop.now()
	local c = FlagShop.contents(t)
	self._day = c.day
	local keys = {}
	local order = 0
	for _, set in c.sets do
		order += 1
		self:_section(order, string.upper(set.name) .. "  ·  LIMITED", PUMPKIN, set.ends, "ENDS IN ")
		order += 1
		self:_bundle(order, set.id)
		order += 1
		self:_grid(order, set.keys)
		for _, k in set.keys do
			table.insert(keys, "shop_" .. k)
		end
		table.insert(keys, "shopset_" .. set.id)
	end
	order += 1
	self:_section(order, "TODAY'S FLAGS", WHITE, (c.day + 1) * Shop.DAY_S, "NEW IN ")
	order += 1
	self:_grid(order, c.daily)
	for _, k in c.daily do
		table.insert(keys, "shop_" .. k)
	end
	Prices.fetch_keys(keys)
	self:_tick_clocks(t)
end

function FlagShop._tick_clocks(self, t: number)
	for _, cl in self._clocks do
		cl.label.Text = cl.prefix .. FlagShop.clock(cl.ends - t)
	end
end

function FlagShop._process(self, _dt: number)
	if not self.is_open then
		return
	end
	local t = FlagShop.now()
	if Shop.day(t) ~= self._day then
		self:_rebuild() -- (midnight UTC: the shop turned over)
		return
	end
	self:_tick_clocks(t)
end

-- ---------------------------------------------------------------------------------------------
-- Open / close / layout
-- ---------------------------------------------------------------------------------------------

function FlagShop.open(self)
	if self.is_open then
		return
	end
	self.is_open = true
	self:_report("opened")
	self:set_visible(true)
	self:apply_layout()
	self._panel:set_modulate_a(1.0)
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.2)
	UICtx.pop_in(self._panel, 0.0, 0.94, 0.3)
	self.ctx:sfx("open")
	self:set_process(true)
end

function FlagShop.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self:set_process(false)
	self.ctx:sfx("close")
	local t = self:create_tween():set_parallel(true)
	t:tween_property(self._dim, "modulate:a", 0.0, 0.15)
	t:tween_property(self._panel, "modulate:a", 0.0, 0.15)
	t:chain():tween_callback(function()
		if not self.is_open then
			self:set_visible(false)
		end
	end)
	self.closed:Fire()
end

function FlagShop.apply_layout(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local cs = self:_card_size()
	local cols = if ctx.compact
		then math.max(2, math.floor((area.Width - 90) / (cs.X + FlagShop.GAP)))
		else FlagShop.COLS
	cols = math.min(cols, if ctx.compact then 5 else FlagShop.COLS)
	self._cols = cols
	local gw = cols * cs.X + (cols - 1) * FlagShop.GAP + 14
	-- as tall as everything in it, up to the screen's height less the window's head and edges
	-- (2026-10-22, using more of the screen's height: it stopped at 560, today's flags under
	-- the fold); phones: slimmer edges
	local compact = ctx.compact
	self._panel:set_padding(
		if compact then 14 else 22,
		if compact then 10 else 18,
		if compact then 14 else 22,
		if compact then 10 else 18
	)
	self._v:set_separation(if compact then 6 else 10)
	local chrome = if compact then 34 + 6 + 20 else 34 + 10 + 36
	local gh = math.clamp(math.min(self:_content_height(cols), area.Height - chrome - 8), 140, 4000)
	self._host:set_min_size(Vector2.new(gw, gh))
	self._sub:set_visible(not compact or area.Width > 600)
	if self.is_open then
		self:_rebuild()
	end
	self:_center()
end

--- The list's height (logical px) with `cols` cards a row: each section's head, its rows, the gap
--- under them (as _section / _grid build them).
function FlagShop._content_height(self, cols: number): number
	local cs = self:_card_size()
	local c = FlagShop.contents(FlagShop.now())
	local h = 2
	local function grid(keys: { string })
		local list, hero = ShopLayout.order(keys)
		local _, rows = ShopLayout.place(#list, hero, cols)
		h += 30 + rows * cs.Y + (rows - 1) * FlagShop.GAP + 14
	end
	for _, s in c.sets do
		grid(s.keys)
		if self:_bundle_shown(s.id) then
			h += FlagShop.BANNER_H + 10
		end
	end
	grid(c.daily)
	return h
end

function FlagShop._center(self)
	local area = self.ctx:clear_rect()
	local pn = self._panel
	local sz = pn:get_combined_minimum_size()
	local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
	local y = math.max(p.Y, area.Min.Y + 4.0)
	pn:set_offsets(math.floor(p.X + 0.5), math.floor(y + 0.5), math.floor(p.X + 0.5), math.floor(y + 0.5))
	pn:reset_size()
end

return FlagShop
