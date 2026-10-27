--!nonstrict
-- RoWorld General's window (Data/Subscription; 2026-10-27): what the monthly subscription gives, and
-- SUBSCRIBE, which opens Roblox's own prompt (MarketplaceService:PromptSubscriptionPurchase). Roblox
-- bills and renews it; the server hears of it (server/General, OP.GENERAL) and the window then says
-- the player is a General. Opened from the title's General button.
--
--   GeneralOffer.new(ctx)   :bind(session)   :open(from)   :close()   .closed (Signal)   .is_open
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Locker = require("./Locker")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local Subscription = UICtx.data("Subscription")
local Cosmetics = UICtx.data("Cosmetics")

local GeneralOffer = W.class(W.Control)

--- The window's width (logical px; phones: COMPACT_W).
GeneralOffer.W = 430
GeneralOffer.COMPACT_W = 360
--- After a try to subscribe, the server's word is waited for this long before the button comes back.
GeneralOffer.WAIT_S = 30.0

function GeneralOffer.new(c: any)
	local self = setmetatable({}, GeneralOffer.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.is_open = false
	--- after Roblox's prompt closed with a try to buy: os.clock() then (the server's word is due)
	self._waiting = nil :: number?
	--- Roblox's price for this player: { robux = n } or { text = "..." } (nil: not known yet)
	self._price = nil
	self._price_asked = false
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self._dim = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.78))
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._dim.gui_input:Connect(function(e)
		if e.pressed and not self._panel:has_global_point(e.global_position) then
			self:close()
		end
	end)
	self:add_child(self._dim)
	self:_build()
	if IS_ROBLOX then
		pcall(function()
			game:GetService("MarketplaceService").PromptSubscriptionPurchaseFinished:Connect(function(_u, sid, tried)
				if sid == Subscription.id() then
					self:_on_prompt_done(tried == true)
				end
			end)
		end)
	end
	self:set_process(true)
	return self
end

function GeneralOffer._build(self)
	self._panel = GlassPanel.new(24.0, 20.0, 18, true, 34)
	self._panel:set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.97))
	self._panel:set_border(UITheme.c(UITheme.GOLD, 0.45))
	self:add_child(self._panel)
	local v = UITheme.vbox(14)
	self._v = v
	self._panel:add_child(v)
	-- head: what it is, close
	local head = UITheme.hbox(10)
	local cap = UITheme.caption("MONTHLY SUBSCRIPTION", 11, UITheme.GOLD)
	cap.size_flags_horizontal = W.EXPAND_FILL
	cap.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(cap)
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
	self._title = UITheme.label("ROWORLD GENERAL", 26, 800, UITheme.GOLD, 2)
	v:add_child(self._title)
	self._sub =
		UITheme.label("Every perk below, every month. Cancel any time in Roblox's settings.", 13, 500, UITheme.TEXT_2)
	self._sub:set_autowrap(true)
	v:add_child(self._sub)
	-- the perks
	self._perk_daily = self:_perk(v, UITheme.icon_rect("crate", 20, UITheme.GOLD))
	self._perk_stars = self:_perk(v, UITheme.icon_rect("star", 20, UITheme.GOLD))
	local sw = W.Control.new()
	sw:set_min_size(Vector2.new(24, 24))
	sw:set_mouse_filter(W.MOUSE_IGNORE)
	if IS_ROBLOX then
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(1, 1)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = img
		img.Parent = sw.gui
		self._skin_img = img
	end
	self._perk_skin = self:_perk(v, sw)
	-- subscribe
	self._buy = UITheme.button("", "PrimaryButton", "robux", 48.0)
	self._buy.pressed:Connect(function()
		self:_subscribe()
	end)
	v:add_child(self._buy)
	self._note = UITheme.label("", 11, 500, UITheme.TEXT_3)
	self._note:set_alignment(W.ALIGN_CENTER)
	self._note:set_autowrap(true)
	v:add_child(self._note)
end

--- A perk's row: `glyph` in a gold disc, a bold line and a muted one under it.
function GeneralOffer._perk(_self, parent: any, glyph: any): any
	local row = UITheme.hbox(12)
	local disc = W.Panel.new()
	disc:set_mouse_filter(W.MOUSE_IGNORE)
	disc:set_min_size(Vector2.new(40, 40))
	disc.size_flags_vertical = W.SHRINK_CENTER
	disc:add_theme_stylebox_override(
		"panel",
		UITheme.flat(UITheme.c(UITheme.GOLD, 0.14), 20, UITheme.c(UITheme.GOLD, 0.5), 1)
	)
	glyph.size_flags_horizontal = W.SHRINK_CENTER
	glyph.size_flags_vertical = W.SHRINK_CENTER
	disc:add_child(glyph)
	row:add_child(disc)
	local col = UITheme.vbox(2)
	col.size_flags_horizontal = W.EXPAND_FILL
	col.size_flags_vertical = W.SHRINK_CENTER
	local head = UITheme.label("", 15, 700, UITheme.TEXT)
	local body = UITheme.label("", 12, 500, UITheme.TEXT_2)
	body:set_autowrap(true)
	col:add_child(head)
	col:add_child(body)
	row:add_child(col)
	parent:add_child(row)
	return { head = head, body = body }
end

function GeneralOffer.bind(self, s: any)
	self.session = s
	if s ~= nil and s.general_changed ~= nil then
		self:_connect(s.general_changed:Connect(function(on: boolean)
			if on then
				self._waiting = nil
			end
			if self.is_open then
				self:refresh()
			end
		end))
	end
end

function GeneralOffer._report(self, kind: string, a: any?)
	local s = self.ctx.session
	if s ~= nil and type(s.report) == "function" then
		s:report("general", kind, a)
	end
end

--- Subscribed, as the server last said.
function GeneralOffer.subscribed(self): boolean
	local s = self.ctx.session
	return s ~= nil and s.general == true
end

--- Roblox's price for this player (MarketplaceService:GetSubscriptionProductInfoAsync), asked once.
function GeneralOffer._fetch_price(self)
	if self._price_asked or not IS_ROBLOX or Subscription.id() == "" then
		return
	end
	self._price_asked = true
	task.spawn(function()
		local ok, info = pcall(function()
			return (game:GetService("MarketplaceService") :: any):GetSubscriptionProductInfoAsync(Subscription.id())
		end)
		if ok and type(info) == "table" then
			local robux = tonumber(info.PriceInRobux)
			if robux ~= nil and robux > 0 then
				self._price = { robux = robux }
			elseif type(info.DisplayPrice) == "string" and info.DisplayPrice ~= "" then
				self._price = { text = info.DisplayPrice }
			end
			if self.is_open then
				self:refresh()
			end
		else
			self._price_asked = false -- (asked again next time it opens)
		end
	end)
end

function GeneralOffer.refresh(self)
	local inv = if self.ctx.session ~= nil then self.ctx.session.inventory else nil
	local crates = type(inv) == "table" and inv.crates_allowed == true
	local daily = self._perk_daily
	if crates then
		daily.head:set_text("A free crate every day")
		daily.body:set_text("Play on any day to get it. Never a duplicate.")
	else
		daily.head:set_text(string.format("%s Stars every day", UICtx.commas(Subscription.DAILY_STARS)))
		daily.body:set_text("Play on any day to get them.")
	end
	self._perk_stars.head:set_text(
		string.format("+%d%% Stars every match", math.floor(Subscription.STARS_BONUS * 100 + 0.5))
	)
	self._perk_stars.body:set_text("On top of 2x Stars.")
	local skin = Cosmetics.item(Subscription.skin_for(os.time()))
	self._perk_skin.head:set_text("This month's General skin")
	self._perk_skin.body:set_text(
		(if skin ~= nil then skin.name .. ". " else "") .. "A new one every month, yours to keep."
	)
	if self._skin_img ~= nil and skin ~= nil then
		Locker.show_item(self._skin_img, skin)
	end
	local on = self:subscribed()
	if on then
		self._buy:set_icon("")
		self._buy:set_text("YOU'RE A GENERAL")
		self._buy:set_disabled(true)
		self._note:set_text("Thank you! It renews every month. Cancel any time in Roblox's settings.")
	elseif self._waiting ~= nil then
		self._buy:set_icon("")
		self._buy:set_text("WAITING FOR ROBLOX…")
		self._buy:set_disabled(true)
		self._note:set_text("")
	else
		local p = self._price
		if p ~= nil and p.text ~= nil then
			self._buy:set_icon("")
			self._buy:set_text(string.format("SUBSCRIBE  ·  %s / MONTH", p.text))
		else
			self._buy:set_icon("robux")
			self._buy:set_text(
				string.format("%d / MONTH  ·  SUBSCRIBE", if p ~= nil then p.robux else Subscription.ROBUX)
			)
		end
		self._buy:set_disabled(Subscription.id() == "")
		self._note:set_text("Renews every month until you cancel.")
	end
end

function GeneralOffer._subscribe(self)
	if self:subscribed() or self._waiting ~= nil or Subscription.id() == "" or not IS_ROBLOX then
		return
	end
	self:_report("clicked")
	local ok = pcall(function()
		(game:GetService("MarketplaceService") :: any):PromptSubscriptionPurchase(
			game:GetService("Players").LocalPlayer,
			Subscription.id()
		)
	end)
	if not ok then
		self._note:set_text("Subscriptions aren't available right now.")
	end
end

--- Roblox's prompt closed; `tried`: the player went ahead (the server's word follows: OP.GENERAL).
function GeneralOffer._on_prompt_done(self, tried: boolean)
	if not tried or self:subscribed() then
		return
	end
	self:_report("prompt_done")
	self._waiting = os.clock()
	if self.is_open then
		self:refresh()
	end
end

function GeneralOffer._process(self, _dt: number)
	if self._waiting ~= nil and os.clock() - self._waiting > GeneralOffer.WAIT_S then
		self._waiting = nil
		if self.is_open then
			self:refresh()
		end
	end
end

function GeneralOffer.open(self, from: string?)
	if self.is_open then
		return
	end
	self.is_open = true
	self:_report("opened", from or "button")
	self:_fetch_price()
	self:refresh()
	self:set_visible(true)
	self:apply_layout()
	self._panel:set_modulate_a(1.0)
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.2)
	UICtx.pop_in(self._panel, 0.0, 0.94, 0.3)
	self.ctx:sfx("open")
end

function GeneralOffer.close(self)
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
		end
	end)
	self.closed:Fire()
end

function GeneralOffer.apply_layout(self)
	local ctx = self.ctx
	local compact = ctx.compact
	local w = if compact then GeneralOffer.COMPACT_W else GeneralOffer.W
	self._v:set_separation(if compact then 9 else 14)
	self._title:set_font_size(if compact then 21 else 26)
	for _, l in { self._sub, self._note } do
		l:set_min_size(Vector2.new(w, 0))
	end
	for _, p in { self._perk_daily, self._perk_stars, self._perk_skin } do
		p.body:set_min_size(Vector2.new(w - 52, 0))
	end
	self._buy:set_min_size(Vector2.new(w, if compact then 42 else 48))
	local area = ctx:clear_rect()
	local pn = self._panel
	pn:reset_size()
	local sz = pn:get_combined_minimum_size()
	local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(math.max(p.Y, area.Min.Y + 4.0) + 0.5))
	pn:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
	pn:reset_size()
end

return GeneralOffer
