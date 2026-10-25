--!nonstrict
-- The Locker (2026-09-29: cosmetic loot boxes of territory skins and flags to unlock):
-- a modal from the title with the crate card on the left and what you own on the right.
--   crate card  the crate art, "a territory skin or a flag you don't own yet", the player's own odds
--               per rarity (Cosmetics.odds, shown before every purchase: Roblox's paid random items
--               rules), how many items they own, and the button: 15 Robux for the first crate, 49
--               after (Data/Products), "Open" while a bought crate waits; under it three crates for
--               less (Data/Products crate3, _pack_saving). Hidden where paid random
--               items are restricted (Session.inventory.crates_allowed, PolicyService on the server).
--   grid        Skins / Flags tabs: every item (owned bright, the rest dimmed as a preview of what a
--               crate can give); press an owned one to wear it, "None" to wear nothing. An exclusive
--               skin (Cosmetics.exclusives) shows only to its owner, first, "EXCLUSIVE" in pink.
--   reveal      after a crate opens: the item in its rarity's colour, Equip / Open another / Done.
-- The purchase goes like the takeover's (Takeover.luau): Roblox's prompt, the server stores the crate
-- (server/Purchases), the client opens it (Session.open_crate), the server rolls it.
-- Signals: closed.
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local ChestView = require("./ChestView")
local UICtx = require("./UICtx")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local function shared(name: string): any
	if IS_ROBLOX then
		return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data[name]) :: any
	end
	return (require :: any)("../../shared/Data/" .. name)
end
local Cosmetics = shared("Cosmetics")
local Products = shared("Products")
local Prices = require("./Prices")
local SkinPreviews: any = (function()
	local ok, m = pcall(function()
		if IS_ROBLOX then
			return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Assets.SkinPreviews)
		end
		return (require :: any)("../../shared/Assets/SkinPreviews")
	end)
	return if ok and type(m) == "table" then m else {}
end)()

local Locker = W.class(W.Control)

Locker.TABS = { { "Skins", "skin" }, { "Flags", "flag" } }
Locker.SKIN_CARD = Vector2.new(116, 128)
Locker.FLAG_CARD = Vector2.new(104, 96)
Locker.GRID_SIZE = Vector2.new(560, 430)
Locker.CRATE_W = 250
--- the colour skins are previewed in (the player's own varies by match)
Locker.PREVIEW_COLOR = Color3.fromRGB(64, 132, 230)
Locker.PREVIEW_TILES = 24
Locker.CREDIT_WAIT_S = 30

local FONT = Font.fromId(12187365977, Enum.FontWeight.Bold)
local FONT_M = Font.fromId(12187365977, Enum.FontWeight.Medium)

local function c3(hex: number): Color3
	return Color3.fromRGB((hex // 65536) % 256, (hex // 256) % 256, hex % 256)
end

-- A skin's preview: its pattern in PREVIEW_COLOR over sand, the way the map draws it
-- (MapSurface: fill alpha 150, secondary Cosmetics.SECONDARY_ALPHA, a darker edge). Cached per skin.
local previews: { [string]: any } = {}
local function skin_preview(skin: any): any
	local cached = previews[skin.id]
	if cached ~= nil then
		return cached or nil
	end
	if not IS_ROBLOX then
		return nil
	end
	-- (a skin with several colours shows twice the tiles: its pattern is larger, as in the atlas)
	local n = if skin.colors ~= nil then Locker.PREVIEW_TILES * 2 else Locker.PREVIEW_TILES
	local ok, img = pcall(function()
		return game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(n, n) })
	end)
	if not ok or img == nil then
		previews[skin.id] = false
		return nil
	end
	local mask, mw, mh = Cosmetics.mask(skin)
	local c = Locker.PREVIEW_COLOR
	local r, g, b = c.R, c.G, c.B
	local sr, sg, sb = Cosmetics.secondary(skin, r, g, b)
	local tr, tg, tb = 221 / 255, 205 / 255, 160 / 255
	local a1, a2 = 150 / 255, Cosmetics.SECONDARY_ALPHA / 255
	local buf = buffer.create(n * n * 4)
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			local cr, cg, cb, a
			if x == 0 or y == 0 or x == n - 1 or y == n - 1 then
				cr, cg, cb, a = r * 0.875, g * 0.875, b * 0.875, 1
			else
				local mx = bit32.rshift(x, skin.scale or 0) % mw
				local my = bit32.rshift(y, skin.scale or 0) % mh
				local k = buffer.readu8(mask, my * mw + mx)
				local kr, kg, kb
				if skin.colors ~= nil and k ~= 0 then
					kr, kg, kb = Cosmetics.color(skin, k)
				end
				if kr ~= nil then
					cr, cg, cb, a = kr, kg :: number, kb :: number, Cosmetics.skin_alpha(skin) / 255
				elseif k ~= 0 and skin.colors == nil then
					cr, cg, cb, a = sr, sg, sb, a2
				else
					cr, cg, cb, a = r, g, b, a1
				end
			end
			local k = (y * n + x) * 4
			buffer.writeu8(buf, k, math.floor((tr * (1 - a) + cr * a) * 255 + 0.5))
			buffer.writeu8(buf, k + 1, math.floor((tg * (1 - a) + cg * a) * 255 + 0.5))
			buffer.writeu8(buf, k + 2, math.floor((tb * (1 - a) + cb * a) * 255 + 0.5))
			buffer.writeu8(buf, k + 3, 255)
		end
	end
	local wrote = pcall(function()
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(n, n), buf)
	end)
	previews[skin.id] = if wrote then img else false
	return if wrote then img else nil
end

--- Show item `it` in ImageLabel `img` (a skin's preview or a flag from its atlas).
local function show_item(img: ImageLabel, it: any)
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
	else
		img.ResampleMode = Enum.ResamplerMode.Pixelated
		-- the uploaded atlas (Assets/SkinPreviews); a runtime EditableImage only without it (phones can
		-- run out of EditableImage budget: an Epic reveal card came out empty live, 2026-09-29)
		local cell = SkinPreviews.cells and SkinPreviews.cells[it.id]
		if cell ~= nil and SkinPreviews.image then
			img.Image = SkinPreviews.image
			img.ImageRectOffset = Vector2.new(cell[1], cell[2])
			img.ImageRectSize = Vector2.new(cell[3], cell[4])
			return
		end
		local ed = skin_preview(it)
		if ed ~= nil then
			img.ImageContent = Content.fromObject(ed)
		end
	end
end
Locker.show_item = show_item

function Locker.new(c: any)
	local self = setmetatable({}, Locker.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.is_open = false
	-- (Roblox's price of the crate arrives a moment after the first look: UI/Prices)
	self:_connect(Prices.changed:Connect(function()
		if self.is_open then
			self:_refresh_crate()
		end
	end))
	self._tab = 1
	self._pending = nil
	self._cards = {}
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self._dim = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.78))
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._dim.gui_input:Connect(function(e)
		-- (a press on the window's own ground reaches the dim too: only one outside it closes)
		if
			e.pressed
			and not (self.opening ~= nil and self.opening.is_open)
			and not self._panel:has_global_point(e.global_position)
		then
			self:close()
		end
	end)
	self:add_child(self._dim)
	self._panel = GlassPanel.new(22.0, 20.0, 18, true, 34)
	self._panel:set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.96))
	self:add_child(self._panel)
	local v = UITheme.vbox(12)
	self._v = v
	self._panel:add_child(v)
	-- head: title, owned count, close
	local head = UITheme.hbox(12)
	local title = UITheme.label("LOCKER", 20, 800, UITheme.TEXT, 3)
	title.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(title)
	self._count = UITheme.label("", 13, 600, UITheme.TEXT_2)
	self._count.size_flags_horizontal = W.EXPAND_FILL
	self._count.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._count)
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
	-- body: crate card | tabs + grid
	local body = UITheme.hbox(16)
	self._body = body
	v:add_child(body)
	self:_build_crate(body)
	local right = UITheme.vbox(10)
	self._right = right
	body:add_child(right)
	local tabs = UITheme.hbox(6)
	self._tabs = {}
	for i, t in ipairs(Locker.TABS) do
		local chip = UITheme.button(t[1], "ChipButton", "", 32.0)
		chip.toggle_mode = true
		chip:set_font_size(12)
		chip:set_pressed_no_signal(i == self._tab)
		chip.pressed:Connect(function()
			self._tab = i
			for j, ch in ipairs(self._tabs) do
				ch:set_pressed_no_signal(j == i)
			end
			self:_rebuild()
		end)
		table.insert(self._tabs, chip)
		tabs:add_child(chip)
	end
	right:add_child(tabs)
	local host = W.Control.new()
	host:set_min_size(Locker.GRID_SIZE)
	host:set_mouse_filter(W.MOUSE_PASS)
	self._host = host
	right:add_child(host)
	local sf = Instance.new("ScrollingFrame")
	sf.Name = "LockerGrid"
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.Size = UDim2.fromScale(1, 1)
	sf.ScrollBarThickness = 6
	sf.ScrollBarImageColor3 = Color3.new(1, 1, 1)
	sf.ScrollBarImageTransparency = 0.6
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.CanvasSize = UDim2.new(0, 0, 0, 0)
	sf.ScrollingDirection = Enum.ScrollingDirection.Y
	sf.ZIndex = 40
	sf.Parent = host.gui
	host:_part(sf, "ScrollBarImageTransparency", 0.4)
	self._sf = sf
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = sf
	self._grid = grid
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 2)
	pad.PaddingLeft = UDim.new(0, 2)
	pad.Parent = sf
	self._foot = UITheme.label("Flags from OpenFront (CC BY-SA 4.0)", 11, 500, UITheme.TEXT_3)
	v:add_child(self._foot)
	-- Roblox: the purchase prompt (the session's signals: bind, once UIRoot has one)
	if IS_ROBLOX then
		game:GetService("MarketplaceService").PromptProductPurchaseFinished:Connect(function(_u, product_id, purchased)
			self:_on_prompt_done(product_id, purchased)
		end)
	end
	return self
end

--- The session's inventory, credits and crate answers (UIRoot.setup, when the session exists).
function Locker.bind(self, s: any)
	if s == nil or self._bound == s then
		return
	end
	self._bound = s
	if s.inventory_changed then
		s.inventory_changed:Connect(function()
			self:_on_inventory()
		end)
	end
	if s.credits_changed then
		s.credits_changed:Connect(function()
			self:_on_credits()
		end)
	end
	if s.crate_result then
		s.crate_result:Connect(function(ok, res)
			self:_on_result(ok, res)
		end)
	end
end

-- ---------------------------------------------------------------------------------------------
-- The crate card
-- ---------------------------------------------------------------------------------------------

function Locker._build_crate(self, parent: any)
	local card = W.Panel.new()
	card:set_mouse_filter(W.MOUSE_IGNORE)
	card:add_theme_stylebox_override(
		"panel",
		UITheme.flat(UITheme.c(UITheme.GOLD, 0.07), 16, UITheme.c(UITheme.GOLD, 0.45), 1, 16.0, 14.0)
	)
	self._crate = card
	parent:add_child(card)
	local v = UITheme.vbox(8)
	self._crate_v = v
	card:add_child(v)
	-- the 3D chest (ChestView: the opening's chest), bobbing and wiggling while the Locker is open
	local vpf = Instance.new("ViewportFrame")
	vpf.BackgroundTransparency = 1
	self._chest_view = ChestView.build(vpf)
	self._chest_P = ChestView.rest()
	self._chest_t = 0.0
	ChestView.pose(self._chest_view, self._chest_P)
	self._art = W.wrap(vpf)
	self._art:_part(vpf, "ImageTransparency", 1.0)
	self._art:set_min_size(Vector2.new(Locker.CRATE_W - 32, 150))
	self._art:set_mouse_filter(W.MOUSE_IGNORE)
	self._art.size_flags_horizontal = W.SHRINK_CENTER
	v:add_child(self._art)
	self._crate_title = UITheme.label("COSMETIC CRATE", 16, 800, UITheme.TEXT, 2)
	self._crate_title:set_alignment(W.ALIGN_CENTER)
	v:add_child(self._crate_title)
	self._crate_sub = UITheme.label("A territory skin or a flag you don't own yet", 12, 500, UITheme.TEXT_2)
	self._crate_sub:set_alignment(W.ALIGN_CENTER)
	self._crate_sub:set_autowrap(true)
	self._crate_sub:set_min_size(Vector2.new(Locker.CRATE_W - 32, 0))
	v:add_child(self._crate_sub)
	-- the odds (the player's own; shown before any purchase)
	local odds = UITheme.vbox(3)
	self._odds_box = odds
	self._odds = {}
	self._odds_labels = {}
	for _, r in Cosmetics.RARITIES do
		local row = UITheme.hbox(8)
		local sw = UITheme.swatch(c3(r.color), 10.0, 3)
		sw.size_flags_vertical = W.SHRINK_CENTER
		row:add_child(sw)
		local name = UITheme.label(r.name, 12, 600, UITheme.TEXT)
		name.size_flags_horizontal = W.EXPAND_FILL
		row:add_child(name)
		local pct = UITheme.label("", 12, 700, UITheme.TEXT)
		row:add_child(pct)
		self._odds[r.id] = pct
		table.insert(self._odds_labels, name)
		table.insert(self._odds_labels, pct)
		odds:add_child(row)
	end
	v:add_child(odds)
	self._buy = UITheme.button("49", "PrimaryButton", "robux", 48.0)
	self._buy:set_min_size(Vector2.new(Locker.CRATE_W - 32, 48))
	self._buy.pressed:Connect(function()
		self:_buy_pressed()
	end)
	v:add_child(self._buy)
	-- three crates at once, for less than three (Data/Products crate3; 2026-10-19)
	self._buy3 = UITheme.button("", "GlassButton", "robux", 42.0)
	self._buy3:set_min_size(Vector2.new(Locker.CRATE_W - 32, 42))
	self._buy3:set_font_size(13)
	self._buy3:set_visible(false)
	self._buy3.pressed:Connect(function()
		self:_buy_pressed(Products.crate3)
	end)
	v:add_child(self._buy3)
	self._note = UITheme.label("", 11, 500, UITheme.TEXT_3)
	self._note:set_alignment(W.ALIGN_CENTER)
	self._note:set_autowrap(true)
	self._note:set_min_size(Vector2.new(Locker.CRATE_W - 32, 0))
	v:add_child(self._note)
end

function Locker._inv(self): any
	local s = self.ctx.session
	return if s ~= nil and s.inventory ~= nil
		then s.inventory
		else { owned = {}, equipped = {}, crates_bought = 0, crates_allowed = false }
end

function Locker._crates(self): number
	local s = self.ctx.session
	local c = if s ~= nil then s.credits else nil
	return if type(c) == "table" then (tonumber(c.crate) or 0) else 0
end

--- The crate product to sell now: the first crate's price until one was bought.
function Locker._product(self): any
	local inv = self:_inv()
	if (inv.crates_bought or 0) <= 0 and Products.crate_first and Products.crate_first.id ~= 0 then
		return Products.crate_first
	end
	return Products.crate
end

--- Its price in Robux: Roblox's for this player (UI/Prices).
function Locker._price(self): number
	return Prices.robux(if self:_product() == Products.crate_first then "crate_first" else "crate")
end

--- The 3-crate pack's Robux saved against three crates at Roblox's price for this player; nil when
--- it isn't offered: not created here, not cheaper (Managed Pricing moves each price on its own), or
--- fewer than its crates' worth of items left to find (a crate never gives a duplicate).
function Locker._pack_saving(self, left: number): number?
	local p = Products.crate3
	if p == nil or p.id == 0 then
		return nil
	end
	local n = math.max(1, tonumber(p.count) or 3)
	local save = n * Prices.robux("crate") - Prices.robux("crate3")
	if save <= 0 or left - self:_crates() < n then
		return nil
	end
	return save
end

function Locker._refresh_crate(self)
	local inv = self:_inv()
	local total = #Cosmetics.all()
	local owned = Cosmetics.crate_owned(inv.owned)
	self._count:set_text(string.format("%d of %d unlocked", owned, total))
	for _, e in Cosmetics.odds(inv.owned) do
		local l = self._odds[e.rarity.id]
		if l then
			l:set_text(if e.left > 0 then string.format("%.0f%%", e.odds * 100) else "all owned")
		end
	end
	local all_owned = owned >= total
	local waiting = self:_crates()
	local busy = self._pending ~= nil
	local prod = self:_product()
	local allowed = inv.crates_allowed == true
	self._buy:set_visible(allowed and not all_owned)
	self._odds_box:set_visible(allowed and not all_owned)
	self._buy:set_disabled(busy)
	local save = if allowed and not busy and waiting <= 0 then self:_pack_saving(total - owned) else nil
	self._buy3:set_visible(save ~= nil and (self._tight or 0) < 2)
	if save ~= nil then
		self._buy3:set_text(string.format("%d  ·  %d CRATES", Prices.robux("crate3"), Products.crate3.count or 3))
	end
	if busy then
		self._buy:set_icon("")
		self._buy:set_text("OPENING…")
	elseif waiting > 0 then
		self._buy:set_icon("crate")
		self._buy:set_text(if waiting > 1 then string.format("OPEN CRATE (%d)", waiting) else "OPEN CRATE")
	else
		self._buy:set_icon("robux")
		self._buy:set_text(tostring(self:_price()))
	end
	if not allowed then
		self._note:set_text("Crates aren't available in your country. What you own stays yours.")
	elseif all_owned then
		self._note:set_text("You own every skin and flag.")
	elseif waiting <= 0 and prod == Products.crate_first then
		self._note:set_text(string.format("Your first crate: %d instead of %d", self:_price(), Prices.robux("crate")))
	elseif save ~= nil then
		-- (phones: one line; the crate card is all the height a phone has)
		self._note:set_text(
			if self.ctx.compact
				then string.format("%d crates save %d", Products.crate3.count or 3, save)
				else string.format("%d crates save %d  ·  Never a duplicate", Products.crate3.count or 3, save)
		)
	else
		self._note:set_text("Never a duplicate")
	end
end

-- ---------------------------------------------------------------------------------------------
-- Buying and opening
-- ---------------------------------------------------------------------------------------------

--- A short notice (UIRoot sets this to its toasts).
function Locker._toast(_self, _text: string) end

function Locker._report(self, kind: string)
	local s = self.ctx.session
	if s ~= nil and type(s.report) == "function" then
		s:report(kind)
	end
end

--- `pack`: the 3-crate pack's button (Products.crate3); otherwise the main button (or OPEN ANOTHER).
function Locker._buy_pressed(self, pack: any?)
	local inv = self:_inv()
	if self._pending ~= nil or inv.crates_allowed ~= true then
		return
	end
	self:_report("crate_click")
	if self:_crates() > 0 then
		self:_open()
		return
	end
	local prod = pack or self:_product()
	if prod == nil or prod.id == 0 or not IS_ROBLOX then
		return
	end
	self._pending = { phase = "prompt", product = prod.id, since = os.clock() }
	self:_refresh_crate()
	local ok = pcall(function()
		game:GetService("MarketplaceService"):PromptProductPurchase(game:GetService("Players").LocalPlayer, prod.id)
	end)
	if not ok then
		self:_cancel("Purchases aren't available right now.")
	end
end

function Locker._open(self)
	self._pending = { phase = "opening", since = os.clock() }
	self:_refresh_crate()
	-- the show starts at once: the server's roll lands while the chest drops / shakes
	if self.opening ~= nil then
		self.opening:play(self:_offer())
	end
	local s = self.ctx.session
	if s == nil or not s:open_crate() then
		if self.opening ~= nil then
			self.opening:fail("Couldn't reach the server. Try again in a moment.")
		end
		self:_cancel("Couldn't reach the server. Try again in a moment.")
	end
end

--- What the opening show offers next: waiting crates, the next price, whether more can come, and
--- what the player wears.
function Locker._offer(self): any
	local inv = self:_inv()
	local owned = Cosmetics.crate_owned(inv.owned)
	return {
		crates = self:_crates(),
		price = self:_price(),
		can_more = inv.crates_allowed == true and owned < #Cosmetics.all(),
		wearing = function(slot: string): string?
			return self:_equipped(slot)
		end,
	}
end

--- The opening show (UIRoot makes it, above the Locker).
function Locker.set_opening(self, o: any)
	self.opening = o
	o.preview_of = skin_preview
	o.show_item = show_item
	o.info_of = function()
		return self:_offer()
	end
	o.wear:Connect(function(id: string)
		local it = Cosmetics.item(id)
		local se = self.ctx.session
		if it ~= nil and se ~= nil then
			self.ctx:sfx("click")
			se:equip(it.kind, it.id)
		end
	end)
	o.again:Connect(function()
		self:_buy_pressed()
	end)
	o.closed:Connect(function(fail_text: string?)
		if fail_text then
			self:_toast(fail_text)
		end
		if self.is_open then
			self:_refresh_crate()
			self:_rebuild()
		end
	end)
end

function Locker._cancel(self, message: string?)
	self._pending = nil
	if message then
		self:_toast(message)
	end
	self:_refresh_crate()
end

function Locker._on_prompt_done(self, product_id: number, purchased: boolean)
	local p = self._pending
	if p == nil or p.phase ~= "prompt" or product_id ~= p.product then
		return
	end
	if not purchased then
		self:_cancel(nil)
		return
	end
	-- bought: the server stores the crate and says so (credits); then it opens
	p.phase = "credit"
	p.since = os.clock()
	if self:_crates() > 0 then
		self:_open()
	end
end

function Locker._on_credits(self)
	local p = self._pending
	if p ~= nil and p.phase == "credit" and self:_crates() > 0 then
		self:_open()
	end
	if self.is_open then
		self:_refresh_crate()
	end
end

function Locker._on_inventory(self)
	if self.is_open then
		self:_refresh_crate()
		self:_rebuild()
	end
	if self.opening ~= nil and self.opening.is_open then
		self.opening:refresh_buttons()
	end
end

function Locker._on_result(self, ok: boolean, res: string)
	local p = self._pending
	if p == nil or p.phase ~= "opening" then
		return
	end
	self._pending = nil
	self:_refresh_crate()
	local o = self.opening
	if ok then
		local it = Cosmetics.item(res)
		if it ~= nil then
			-- the grid behind shows the new item's tab
			self._tab = if it.kind == "flag" then 2 else 1
			for j, ch in ipairs(self._tabs) do
				ch:set_pressed_no_signal(j == self._tab)
			end
		end
		if o ~= nil then
			o:resolve(res)
		end
	elseif o ~= nil then
		o:fail(
			if res == "everything owned"
				then "You own every skin and flag already."
				else "Couldn't open the crate right now. It's saved: try again."
		)
	end
end

--- Once a second while open: a purchase that never came back gives up (a crate bought stays saved).
function Locker.tick(self)
	local p = self._pending
	if p ~= nil then
		local limit = if p.phase == "prompt" then 180 else Locker.CREDIT_WAIT_S
		if os.clock() - p.since > limit then
			self:_cancel(if p.phase == "prompt" then nil else "Your crate is saved: open it in a moment.")
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- The grid
-- ---------------------------------------------------------------------------------------------

function Locker._equipped(self, slot: string): string?
	local inv = self:_inv()
	return inv.equipped and inv.equipped[slot] or nil
end

function Locker._card(self, it: any, order: number, slot: string): TextButton
	local s = UITheme.scale
	local inv = self:_inv()
	local owned = it == nil or inv.owned[it.id] == true
	local equipped = if it == nil then self:_equipped(slot) == nil else self:_equipped(slot) == it.id
	local rar = if it ~= nil then Cosmetics.rarity(it.rarity) else nil
	local b = Instance.new("TextButton")
	b.Name = if it then it.id else "none"
	b.Text = ""
	b.AutoButtonColor = false
	b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	b.BackgroundTransparency = 0.94
	b.LayoutOrder = order
	b.ZIndex = 41
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, math.floor(10 * s))
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = if equipped then UITheme.color3(UITheme.to_rgba(UITheme.AMBER)) else Color3.new(1, 1, 1)
	stroke.Transparency = if equipped then 0 else 0.88
	stroke.Thickness = if equipped then 2 else 1
	stroke.Parent = b
	local img = Instance.new("ImageLabel")
	img.Name = "Preview"
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Fit
	img.Position = UDim2.fromOffset(math.floor(10 * s), math.floor(10 * s))
	img.Size = UDim2.new(1, -math.floor(20 * s), 1, -math.floor(46 * s))
	img.ZIndex = 42
	img.Parent = b
	show_item(img, it)
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.FontFace = FONT
	name.TextSize = math.floor(12 * s)
	name.TextColor3 = Color3.new(1, 1, 1)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = if it then it.name else "None"
	name.Position = UDim2.new(0, math.floor(8 * s), 1, -math.floor(34 * s))
	name.Size = UDim2.new(1, -math.floor(16 * s), 0, math.floor(16 * s))
	name.ZIndex = 42
	name.Parent = b
	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.FontFace = FONT_M
	sub.TextSize = math.floor(10 * s)
	sub.TextColor3 = if equipped
		then UITheme.color3(UITheme.to_rgba(UITheme.AMBER))
		elseif rar and owned then c3(rar.color)
		else Color3.fromRGB(150, 158, 180)
	sub.Text = if equipped then "WEARING" elseif not owned then "LOCKED" elseif rar then string.upper(rar.name) else ""
	sub.Position = UDim2.new(0, math.floor(8 * s), 1, -math.floor(18 * s))
	sub.Size = UDim2.new(1, -math.floor(16 * s), 0, math.floor(12 * s))
	sub.ZIndex = 42
	sub.Parent = b
	local host = self._host
	host:_part(b, "BackgroundTransparency", 0.06)
	host:_part(stroke, "Transparency", 1 - stroke.Transparency)
	host:_part(img, "ImageTransparency", if owned then 1.0 else 0.3)
	host:_part(name, "TextTransparency", if owned then 1.0 else 0.45)
	host:_part(sub, "TextTransparency", 1.0)
	b.MouseEnter:Connect(function()
		host:_part(b, "BackgroundTransparency", 0.12)
	end)
	b.MouseLeave:Connect(function()
		host:_part(b, "BackgroundTransparency", 0.06)
	end)
	b.Activated:Connect(function()
		if not owned then
			self.ctx:sfx("deny", -6.0)
			return
		end
		local se = self.ctx.session
		if se ~= nil then
			self.ctx:sfx("click")
			se:equip(slot, if it then it.id else false)
		end
	end)
	b.Parent = self._sf
	return b
end

function Locker._rebuild(self)
	for _, b in self._cards do
		self._host:_drop_part(b)
		for _, d in b:GetDescendants() do
			self._host:_drop_part(d)
		end
		b:Destroy()
	end
	table.clear(self._cards)
	local s = UITheme.scale
	local slot = Locker.TABS[self._tab][2]
	local cell = if slot == "skin" then Locker.SKIN_CARD else Locker.FLAG_CARD
	if self.ctx.compact then
		cell *= 0.82
	end
	self._grid.CellSize = UDim2.fromOffset(math.floor(cell.X * s), math.floor(cell.Y * s))
	self._grid.CellPadding = UDim2.fromOffset(math.floor(8 * s), math.floor(8 * s))
	local inv = self:_inv()
	-- None first, then owned (by rarity, rarest first), then the rest
	local list = {}
	for _, it in Cosmetics.all() do
		if it.kind == slot then
			table.insert(list, it)
		end
	end
	-- (an exclusive only for whoever owns it: nobody else can get one; a shop flag once bought, the
	-- crate can't give one)
	for _, it in Cosmetics.exclusives() do
		if it.kind == slot and inv.owned[it.id] == true then
			table.insert(list, it)
		end
	end
	for _, it in Cosmetics.shop_items() do
		if it.kind == slot and inv.owned[it.id] == true then
			table.insert(list, it)
		end
	end
	local rank = { exclusive = 0, legendary = 1, epic = 2, rare = 3, common = 4 }
	table.sort(list, function(a, b)
		local oa, ob = inv.owned[a.id] == true, inv.owned[b.id] == true
		if oa ~= ob then
			return oa
		end
		local ra, rb = rank[a.rarity] or 9, rank[b.rarity] or 9
		if ra ~= rb then
			return ra < rb
		end
		return a.name < b.name
	end)
	table.insert(self._cards, self:_card(nil, 0, slot))
	for i, it in list do
		table.insert(self._cards, self:_card(it, i, slot))
	end
end

-- ---------------------------------------------------------------------------------------------
-- Open / close / layout
-- ---------------------------------------------------------------------------------------------

function Locker.open(self)
	if self.is_open then
		return
	end
	self.is_open = true
	self:_report("crate_shop")
	Prices.fetch()
	self:_refresh_crate()
	self:_rebuild()
	self:set_visible(true)
	self:apply_layout()
	self._panel:set_modulate_a(1.0)
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.2)
	UICtx.pop_in(self._panel, 0.0, 0.94, 0.3)
	self.ctx:sfx("open")
	if self._chest_conn == nil and IS_ROBLOX then
		self._chest_conn = game:GetService("RunService").RenderStepped:Connect(function(dt)
			self._chest_t += dt
			ChestView.idle(self._chest_P, self._chest_t, 2.4)
			ChestView.pose(self._chest_view, self._chest_P)
		end)
	end
end

function Locker.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self.ctx:sfx("close")
	local t = self:create_tween():set_parallel(true)
	t:tween_property(self._dim, "modulate:a", 0.0, 0.15)
	t:tween_property(self._panel, "modulate:a", 0.0, 0.15)
	t:chain():tween_callback(function()
		if not self.is_open then
			self:set_visible(false)
			if self._chest_conn then
				self._chest_conn:Disconnect()
				self._chest_conn = nil
			end
		end
	end)
	self.closed:Fire()
end

function Locker.apply_layout(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local compact = ctx.compact
	-- phones (landscape: wide, short): the same side-by-side layout with a slim crate card (no art,
	-- smaller type) so the grid keeps the height
	local cw = if compact then 196 else Locker.CRATE_W
	self._art:set_visible(not compact)
	-- phones (2026-10-22, from a phone's screenshot: the crates menu overflowed vertically, as the
	-- window ran past the screen's foot): no line under the title (the odds name the rarities), no
	-- footer (the title screen credits the flags), slimmer edges, tighter odds, a one-line note
	self._crate_sub:set_visible(not compact)
	self._foot:set_visible(not compact)
	self._panel:set_padding(if compact then 14 else 22, if compact then 10 else 20, if compact then 14 else 22, if compact then 10 else 20)
	self._v:set_separation(if compact then 8 else 12)
	self._odds_box:set_separation(if compact then 1 else 3)
	for _, l in self._odds_labels do
		l:set_font_size(if compact then 11 else 12)
	end
	self._crate_title:set_font_size(if compact then 13 else 16)
	self._crate_sub:set_font_size(if compact then 11 else 12)
	self._crate_sub:set_min_size(Vector2.new(cw - 32, 0))
	self._note:set_min_size(Vector2.new(cw - 32, 0))
	self._buy:set_min_size(Vector2.new(cw - 32, if compact then 40 else 48))
	self._buy3:set_min_size(Vector2.new(cw - 32, if compact then 34 else 42))
	self._buy3:set_font_size(if compact then 12 else 13)
	self._crate_v:set_separation(if compact then 5 else 8)
	local gw = math.clamp(area.Width - cw - 110, 300, Locker.GRID_SIZE.X)
	local gh = math.clamp(area.Height - (if compact then 120 else 170), 120, Locker.GRID_SIZE.Y)
	self._host:set_min_size(Vector2.new(gw, gh))
	-- still taller than the screen (a short phone): the grid gives up what it can, then the card its
	-- note (the price is on the button), then the 3-crate button
	self._tight = 0
	self._note:set_visible(true)
	if self.is_open then
		self:_refresh_crate()
	end
	local function over(): number
		return self._panel:get_combined_minimum_size().Y - (area.Height - 4)
	end
	if over() > 0 then
		self._host:set_min_size(Vector2.new(gw, math.max(100, gh - over())))
	end
	if compact and over() > 0 then
		self._tight = 1
		self._note:set_visible(false)
	end
	if compact and over() > 0 then
		self._tight = 2
		self._buy3:set_visible(false)
	end
	if self.is_open then
		self:_refresh_crate()
		self:_rebuild()
	end
	self:_center()
end

function Locker._center(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	for _, pn in { self._panel } do
		local sz = pn:get_combined_minimum_size()
		local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
		local y = math.max(p.Y, area.Min.Y + 4.0)
		local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(y + 0.5))
		pn:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
		pn:reset_size()
	end
end

return Locker
