--!nonstrict
-- Port of scripts/ui/game_over.gd (UIGameOver)
-- Victory / defeat / eliminated / time-up screen with the winner, your match stats and the next
-- steps (play again, spectate, return to title).
-- The Stars the match paid (Data/Stars; server/Rewards answers a moment after the screen opens) count
-- up in a gold pill at the head of the buttons; its card lists what they were for, and a press opens
-- the Arsenal.
-- Under the buttons, once the payout is in, stand what the Stars are for (2026-10-07, to encourage
-- more Robux spending: a day after the Arsenal shipped its unlocks had sold 11
-- times to 27,000 players a day, and the result screen said nothing of them but a number):
--   * the next unlock (Data/Arsenal.next_goal): "MEGA NUKE  4,560 / 20,000", gold and "UNLOCK" once
--     the Stars are there. A press opens the Arsenal on that item, where it sells for Stars or Robux;
--   * 2X STARS, until owned, with what this match would have paid with it.
-- They say what is true and prompt nothing by themselves; they step aside for the takeover offer and
-- on a screen too short for them.

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local TitleScreen = require("./TitleScreen")
local UIRules = require("./UIRules") :: any
local Signal = UITheme.core("Signal")
local Defs = UICtx.core("Defs")

local GameOver = W.class(W.Control)

local function spacer(h: number)
	local g = W.Control.new()
	g:set_mouse_filter(W.MOUSE_IGNORE)
	g:set_min_size(Vector2.new(0, h))
	return g
end

function GameOver.new(c: any)
	local self = setmetatable({}, GameOver.__mt)
	W.Control._init(self)
	self.ctx = c
	self.play_again = Signal.new()
	self.spectate = Signal.new()
	self.to_title = Signal.new()
	--- solo: the TAKE OVER button (Takeover.luau)
	self.take_over = Signal.new()
	--- the Stars pill was pressed
	self.open_arsenal = Signal.new()
	--- the payout shown ({ lines, total, balance }), and the count on its way up to the total
	self._award = nil :: any
	self._stars_shown = 0.0
	self._stars_done = true
	self._take_info = nil
	self.is_open = false
	self._sweep_t = -1.0
	self._kind = ""
	self._next_accum = 0.0
	--- The pill shows the live "Current leader" (not a crowned winner): refreshed while the match runs.
	self._pill_live = false
	self._pill_domination = false
	self._dominated = false
	self._pill_id = 0
	self._pill_text = ""
	self._close_tween = nil
	self._enter_tween = nil
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	local dimg = Instance.new("ImageLabel")
	dimg.BackgroundTransparency = 1
	dimg.ScaleType = Enum.ScaleType.Stretch
	dimg.Image = UICtx.shapes().over_dim or ""
	dimg.Active = true
	self._dim = W.wrap(dimg)
	self._dim:set_mouse_filter(W.MOUSE_STOP)
	self._dim:_part(dimg, "ImageTransparency", 1.0)
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:add_child(self._dim)

	self._center = UITheme.vbox(0)
	self._center:set_alignment(W.ALIGN_CENTER)
	self:add_child(self._center)
	self._kicker = UITheme.label("MATCH COMPLETE", 14, 700, UITheme.TEXT_2, 6)
	self._kicker:set_alignment(W.ALIGN_CENTER)
	self._center:add_child(self._kicker)
	local title = TitleScreen.GradientText.new("GAME OVER", 110, 900)
	title.spacing = 10
	title.shadow = { color = Color3.new(0, 0, 0), alpha = 0.5, offset_y = 6, outline = 12 }
	title.shine = 0.35
	title.size_flags_horizontal = W.SHRINK_CENTER
	self._title = title
	self._center:add_child(title)
	self._sub = UITheme.label("", 18, 500, UITheme.TEXT)
	self._sub:set_alignment(W.ALIGN_CENTER)
	self._center:add_child(self._sub)
	self._center:add_child(spacer(14))

	self._winner = W.Panel.new()
	self._winner:set_mouse_filter(W.MOUSE_IGNORE)
	self._winner.size_flags_horizontal = W.SHRINK_CENTER
	self._winner:add_theme_stylebox_override(
		"panel",
		UITheme.flat(UITheme.c(UITheme.GOLD, 0.1), 999, UITheme.c(UITheme.GOLD, 0.45), 1, 16.0, 6.0)
	)
	local wr = UITheme.hbox(8)
	self._crown = UITheme.icon_rect("crown", 16.0, UITheme.GOLD)
	self._crown.size_flags_vertical = W.SHRINK_CENTER
	wr:add_child(self._crown)
	self._winner_sw = UITheme.swatch(UITheme.TEXT, 12.0, 3)
	wr:add_child(self._winner_sw)
	self._winner_name = UITheme.label("", 15, 700)
	wr:add_child(self._winner_name)
	self._winner:add_child(wr)
	self._center:add_child(self._winner)
	self._gap2 = spacer(26)
	self._center:add_child(self._gap2)

	self._stats = UITheme.hbox(12)
	self._stats:set_alignment(W.ALIGN_CENTER)
	self._center:add_child(self._stats)
	self._gap3 = spacer(28)
	self._center:add_child(self._gap3)

	-- take over the nation that conquered you (Takeover.luau; hidden without an offer). 2026-09-29: the
	-- eliminated screen advertised the revive purchase badly, so the offer is the
	-- screen's centrepiece while it shows (the stat cards step aside): the nation's flag (or colour),
	-- TAKE OVER <NATION>, what you get (its land, troops and gold, live), one big gold button with the
	-- price, a glow and a shine sweeping over the button
	self._take = W.Panel.new()
	self._take:set_mouse_filter(W.MOUSE_IGNORE)
	self._take.size_flags_horizontal = W.SHRINK_CENTER
	self._take:add_theme_stylebox_override(
		"panel",
		UITheme.flat(UITheme.rgba(0.11, 0.09, 0.055, 0.96), 18, UITheme.c(UITheme.GOLD, 0.85), 2, 22.0, 18.0)
	)
	local tv = UITheme.vbox(12)
	self._take_v = tv
	self._take:add_child(tv)
	local head = UITheme.hbox(14)
	-- the nation's flag when a flag carries its name (the AI nations are the world's countries), else
	-- its colour
	local flag = Instance.new("ImageLabel")
	flag.BackgroundTransparency = 1
	flag.ScaleType = Enum.ScaleType.Fit
	self._take_flag_img = flag
	self._take_flag = W.wrap(flag)
	self._take_flag:set_mouse_filter(W.MOUSE_IGNORE)
	self._take_flag:_part(flag, "ImageTransparency", 1.0)
	self._take_flag.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._take_flag)
	self._take_sw = UITheme.swatch(UITheme.TEXT, 30.0, 8)
	self._take_sw.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._take_sw)
	local hv = UITheme.vbox(0)
	hv.size_flags_vertical = W.SHRINK_CENTER
	self._take_kicker = UITheme.label("DON'T GIVE UP", 11, 800, UITheme.GOLD, 3)
	hv:add_child(self._take_kicker)
	self._take_title = UITheme.label("TAKE OVER", 26, 900, UITheme.TEXT, 1)
	hv:add_child(self._take_title)
	-- (phones: what you get as one line here instead of the chips)
	self._take_line = UITheme.label("", 12, 700, UITheme.GOLD, 1)
	self._take_line:set_visible(false)
	hv:add_child(self._take_line)
	head:add_child(hv)
	tv:add_child(head)
	self._take_sub = UITheme.label("", 13, 500, UITheme.TEXT_2)
	self._take_sub:set_autowrap(true)
	tv:add_child(self._take_sub)
	-- what you get
	local chips = UITheme.hbox(8)
	self._take_chips = chips
	self._chip = {}
	self._chip_panels = {}
	for _, c in { { "land", "globe", "LAND", UITheme.AMBER }, { "troops", "troops", "TROOPS", UITheme.CYAN }, { "gold", "gold", "GOLD", UITheme.GOLD } } do
		local chip = W.Panel.new()
		chip:set_mouse_filter(W.MOUSE_IGNORE)
		chip.size_flags_horizontal = W.EXPAND_FILL
		chip:add_theme_stylebox_override("panel", UITheme.flat(UITheme.rgba(1, 1, 1, 0.06), 10, UITheme.rgba(1, 1, 1, 0.1), 1, 10.0, 7.0))
		local ch = UITheme.hbox(8)
		local ic = UITheme.icon_rect(c[2], 18.0, c[4])
		ic.size_flags_vertical = W.SHRINK_CENTER
		ch:add_child(ic)
		local cv = UITheme.vbox(0)
		local value = UITheme.label("", 18, 800)
		cv:add_child(value)
		cv:add_child(UITheme.caption(c[3], 9, UITheme.TEXT_3))
		ch:add_child(cv)
		chip:add_child(ch)
		chips:add_child(chip)
		self._chip[c[1]] = value
		table.insert(self._chip_panels, chip)
	end
	tv:add_child(chips)
	-- the button: TAKE OVER, and the price in a tag on its right
	self._take_btn = UITheme.button("TAKE OVER", "PrimaryButton", "", 60.0)
	self._take_btn:set_font_size(20)
	self._take_btn.pressed:Connect(function()
		self.take_over:Fire()
	end)
	local bg = self._take_btn.gui
	local tag = Instance.new("Frame")
	tag.Name = "Price"
	tag.AnchorPoint = Vector2.new(1, 0.5)
	tag.BackgroundColor3 = Color3.fromRGB(60, 34, 4)
	tag.AutomaticSize = Enum.AutomaticSize.X
	tag.ZIndex = 40
	UICtx.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, tag)
	local pad = UICtx.make("UIPadding", {}, tag)
	self._take_tag_list = UICtx.make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, tag)
	local rbx = Instance.new("ImageLabel")
	rbx.BackgroundTransparency = 1
	rbx.Image = UITheme.icon("robux") or ""
	rbx.ImageColor3 = Color3.fromRGB(255, 226, 150)
	rbx.LayoutOrder = 1
	rbx.ZIndex = 41
	rbx.Parent = tag
	local price = Instance.new("TextLabel")
	price.BackgroundTransparency = 1
	price.AutomaticSize = Enum.AutomaticSize.X
	price.FontFace = Font.fromId(12187365977, Enum.FontWeight.Heavy)
	price.TextColor3 = Color3.fromRGB(255, 226, 150)
	price.LayoutOrder = 2
	price.ZIndex = 41
	price.Parent = tag
	tag.Parent = bg
	self._take_tag, self._take_tag_pad, self._take_rbx, self._take_price = tag, pad, rbx, price
	self._take_btn:_part(tag, "BackgroundTransparency", 1.0)
	self._take_btn:_part(rbx, "ImageTransparency", 1.0)
	self._take_btn:_part(price, "TextTransparency", 1.0)
	-- a shine sweeping over the button now and then
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.Size = UDim2.fromScale(1, 1)
	shine.ZIndex = 39
	self._take_corner = UICtx.make("UICorner", { CornerRadius = UDim.new(0, 12) }, shine)
	self._take_shine = UICtx.make("UIGradient", {
		Rotation = 20,
		Offset = Vector2.new(-1, 0),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 1),
			NumberSequenceKeypoint.new(0.5, 0.55),
			NumberSequenceKeypoint.new(0.6, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, shine)
	shine.Parent = bg
	self._take_btn:_part(shine, "BackgroundTransparency", 1.0)
	tv:add_child(self._take_btn)
	self._take:set_visible(false)
	self._center:add_child(self._take)
	-- the card's gold glow (a raw image in the column, under the card)
	local glow = Instance.new("ImageLabel")
	glow.Name = "TakeGlow"
	glow.BackgroundTransparency = 1
	glow.Image = UITheme.crate_art().glow or ""
	glow.ImageColor3 = UITheme.color3(UITheme.GOLD)
	glow.ImageTransparency = 1
	glow.ZIndex = 1
	glow.Parent = self._center.gui
	self._take_glow = glow
	self._take_t = 0.0
	self._gap4 = spacer(16)
	self._gap4:set_visible(false)
	self._center:add_child(self._gap4)

	self._buttons = UITheme.hbox(12)
	self._buttons:set_alignment(W.ALIGN_CENTER)
	self._center:add_child(self._buttons)
	-- the Stars this match paid (hidden until the payout arrives)
	local sb = UITheme.button("+0", "GlassButton", "star", 52.0)
	sb:set_min_size(Vector2.new(150, 52))
	sb:add_theme_constant_override("icon_max_width", 18)
	sb:add_theme_color_override("font_color", UITheme.GOLD)
	sb:add_theme_color_override("font_hover_color", UITheme.GOLD)
	sb:add_theme_color_override("icon_normal_color", UITheme.GOLD)
	sb:add_theme_color_override("icon_hover_color", UITheme.GOLD)
	for _, st in ipairs({ "normal", "disabled" }) do
		sb:add_theme_stylebox_override(st, UITheme.flat(UITheme.c(UITheme.GOLD, 0.1), UITheme.R_MD, UITheme.c(UITheme.GOLD, 0.5), 1, 14.0, 8.0))
	end
	sb:add_theme_stylebox_override("hover", UITheme.flat(UITheme.c(UITheme.GOLD, 0.18), UITheme.R_MD, UITheme.GOLD, 1, 14.0, 8.0))
	sb:add_theme_stylebox_override("pressed", UITheme.flat(UITheme.c(UITheme.GOLD, 0.26), UITheme.R_MD, UITheme.GOLD, 1, 14.0, 8.0))
	sb:set_visible(false)
	sb.pressed:Connect(function()
		self.ctx:hide_hint(sb)
		self.open_arsenal:Fire()
	end)
	sb.mouse_entered:Connect(function()
		if self._award ~= nil then
			self.ctx:show_hint(sb, self:_stars_spec())
		end
	end)
	sb.mouse_exited:Connect(function()
		self.ctx:hide_hint(sb)
	end)
	self._stars_btn = sb
	self._buttons:add_child(sb)
	self._again = UITheme.button("PLAY AGAIN", "PrimaryButton", "play", 52.0)
	self._again:set_min_size(Vector2.new(200, 52))
	self._again.pressed:Connect(function()
		self.play_again:Fire()
	end)
	self._buttons:add_child(self._again)
	self._spec = UITheme.button("Spectate", "GlassButton", "eye", 52.0)
	self._spec:set_min_size(Vector2.new(170, 52))
	self._spec.pressed:Connect(function()
		self:close()
		self.spectate:Fire()
	end)
	self._buttons:add_child(self._spec)
	self._home = UITheme.button("Return to title", "GlassButton", "exit", 52.0)
	self._home:set_min_size(Vector2.new(200, 52))
	self._home.pressed:Connect(function()
		self.to_title:Fire()
	end)
	self._buttons:add_child(self._home)
	-- what the Stars are for: the next unlock and 2x Stars (see the header)
	self._gap_offers = spacer(10)
	self._gap_offers:set_visible(false)
	self._center:add_child(self._gap_offers)
	self._offers = UITheme.hbox(10)
	self._offers:set_alignment(W.ALIGN_CENTER)
	self._offers:set_visible(false)
	self._center:add_child(self._offers)
	local function offer_button(icon: string): any
		local b = UITheme.button("", "GlassButton", icon, 40.0)
		b:set_font_size(13)
		b:add_theme_constant_override("icon_max_width", 16)
		b:add_theme_color_override("font_color", UITheme.GOLD)
		b:add_theme_color_override("font_hover_color", UITheme.GOLD)
		b:add_theme_color_override("icon_normal_color", UITheme.GOLD)
		b:add_theme_color_override("icon_hover_color", UITheme.GOLD)
		for _, st in ipairs({ "normal", "disabled" }) do
			b:add_theme_stylebox_override(st, UITheme.flat(UITheme.c(UITheme.GOLD, 0.06), UITheme.R_MD, UITheme.c(UITheme.GOLD, 0.35), 1, 14.0, 6.0))
		end
		b:add_theme_stylebox_override("hover", UITheme.flat(UITheme.c(UITheme.GOLD, 0.16), UITheme.R_MD, UITheme.GOLD, 1, 14.0, 6.0))
		b:add_theme_stylebox_override("pressed", UITheme.flat(UITheme.c(UITheme.GOLD, 0.24), UITheme.R_MD, UITheme.GOLD, 1, 14.0, 6.0))
		b:set_visible(false)
		self._offers:add_child(b)
		return b
	end
	self._goal_key = nil :: string?
	self._goal_btn = offer_button("lock")
	self._goal_btn.pressed:Connect(function()
		if self._goal_key ~= nil then
			self.open_arsenal:Fire(self._goal_key, "offer")
		end
	end)
	self._x2_btn = offer_button("star")
	self._x2_btn.pressed:Connect(function()
		self.open_arsenal:Fire("stars2x", "offer")
	end)
	self._next = UITheme.label("", 13, 600, UITheme.TEXT_2)
	self._next:set_alignment(W.ALIGN_CENTER)
	self._gap_next = spacer(14)
	self._center:add_child(self._gap_next)
	self._center:add_child(self._next)
	self:set_process(true)
	return self
end

--- What the Stars were for: the pill's card.
function GameOver._stars_spec(self): { [string]: any }
	local a = self._award
	local StarsData = UICtx.data("Stars")
	local rows = {}
	for _, l in a.lines do
		table.insert(rows, { StarsData.LABELS[l[1]] or l[1], "+" .. UICtx.commas(l[2]), UITheme.GOLD })
	end
	return {
		title = "Stars earned",
		body = "Stars unlock new weapons in the Arsenal.",
		rows = rows,
		hint = string.format("You have %s Stars", UICtx.commas(a.balance or 0)),
		hint_color = UITheme.GOLD,
		hint_icon = "star",
	}
end

--- The match's payout ({ lines, total, balance }, Session.stars_awarded), or nil: the pill counts up.
function GameOver.set_award(self, award: any)
	if award == nil or (tonumber(award.total) or 0) <= 0 then
		self._award = nil
		self._stars_btn:set_visible(false)
		self:_refresh_offers()
		return
	end
	if self._award == award then
		return
	end
	self._award = award
	self._balance = tonumber(award.balance)
	self._stars_shown = 0.0
	self._stars_done = false
	self._stars_btn:set_text("+0")
	self._stars_btn:set_visible(true)
	self:_refresh_offers()
	if self.is_open then
		UICtx.pop_in(self._stars_btn, 0.0, 0.8, 0.35)
		UICtx.pop_in(self._offers, 0.5, 0.9, 0.35)
		self:apply_layout()
	end
end

--- The offers for the payout shown (hidden without one, and while the takeover offer stands).
function GameOver._refresh_offers(self)
	local sess = self.ctx.session
	local inv = if sess ~= nil then sess.inventory else nil
	local o = UIRules.result_offers(self._award, inv, UICtx.data("Arsenal"), self._balance)
	local goal, x2 = o.goal, o.x2
	self._goal_key = if goal ~= nil then goal.key else nil
	if goal ~= nil then
		self._goal_btn:set_text(goal.text)
		self._goal_btn:set_icon(if goal.ready then "star" else "lock")
	end
	if x2 ~= nil then
		self._x2_btn:set_text(x2.text)
	end
	-- (apply_layout shows them: it knows whether there is room)
	self._goal_wanted = goal ~= nil
	self._x2_wanted = x2 ~= nil
end

--- The inventory changed (something was unlocked): the offers follow, counting with its Stars.
function GameOver.refresh_offers(self)
	local sess = self.ctx.session
	local inv = if sess ~= nil then sess.inventory else nil
	if type(inv) == "table" and type(inv.stars) == "number" then
		self._balance = inv.stars
	end
	self:_refresh_offers()
	if self.is_open then
		self:apply_layout()
	end
end

function GameOver._stat_card(self, icon_name: string, value: string, caption: string, col: Color3)
	if self.ctx.compact then
		-- Phones: one short row per card (icon | value over caption).
		local pc = GlassPanel.new(10.0, 7.0, 12, true, 12)
		pc:set_mouse_filter(W.MOUSE_IGNORE)
		local h = UITheme.hbox(8)
		pc:add_child(h)
		local pic = UITheme.icon_rect(icon_name, 18.0, col)
		pic.size_flags_vertical = W.SHRINK_CENTER
		h:add_child(pic)
		local pv = UITheme.vbox(0)
		pv:add_child(UITheme.label(value, 18, 800))
		pv:add_child(UITheme.caption(caption, 10, UITheme.TEXT_3))
		h:add_child(pv)
		return pc
	end
	local card = GlassPanel.new(16.0, 14.0, 14, true, 16)
	card:set_mouse_filter(W.MOUSE_IGNORE)
	card:set_min_size(Vector2.new(150, 0))
	local v = UITheme.vbox(4)
	card:add_child(v)
	local ic = UITheme.icon_rect(icon_name, 20.0, col)
	ic.size_flags_horizontal = W.SHRINK_CENTER
	v:add_child(ic)
	local vl = UITheme.label(value, 26, 800)
	vl:set_alignment(W.ALIGN_CENTER)
	v:add_child(vl)
	local cl = UITheme.caption(caption, 10, UITheme.TEXT_3)
	cl:set_alignment(W.ALIGN_CENTER)
	v:add_child(cl)
	return card
end

--- kind: "victory", "defeat", "eliminated" or "result" (the match ended while you were not in it).
--- reason: Defs.OVER_* (ignored for "eliminated"). stats: {peak_share, max_troops, kills, duration_s}
function GameOver.open(self, kind: string, winner: number, killer: number, stats: any, reason: number?)
	local ctx = self.ctx
	local s = ctx.state
	local rsn = reason or -1
	-- Already on screen (e.g. ELIMINATED, then the match ends): swap the copy in place. A close
	-- fade still in flight would otherwise hide the new screen when it finishes (review P1-1; the
	-- original game_over.gd has the same latent race).
	local was_shown = self.visible
	if self._close_tween ~= nil then
		self._close_tween:kill()
		self._close_tween = nil
	end
	if self._enter_tween ~= nil then
		self._enter_tween:kill()
		self._enter_tween = nil
	end
	self.is_open = true
	self:set_visible(true)
	self:set_modulate_a(1.0)
	self._kind = kind
	local copy = self:_copy(kind, winner, killer, rsn, tonumber(stats.duration_s) or 0.0)
	self._kicker:set_text(copy.kicker)
	self._title:set_text(copy.title)
	self._sub:set_text(copy.sub)
	self._title:set_colors(copy.top, copy.bottom)
	-- Winner pill: a real winner gets the crown; otherwise it reads "Current leader".
	local real_winner = (kind == "victory" or kind == "defeat" or kind == "result")
		and winner ~= 0
		and (rsn == Defs.OVER_DOMINATION or rsn == Defs.OVER_TIME)
	local pill_id = if real_winner then winner else self:_leader_id()
	-- A domination winner's share is the victory metric (land outside fallout), like the headline.
	self._pill_domination = real_winner and rsn == Defs.OVER_DOMINATION and self._dominated
	self._pill_live = not real_winner
	self._pill_id = -1
	self._pill_text = ""
	self._crown:set_visible(real_winner)
	self._winner:add_theme_stylebox_override(
		"panel",
		if real_winner
			then UITheme.flat(UITheme.c(UITheme.GOLD, 0.1), 999, UITheme.c(UITheme.GOLD, 0.45), 1, 16.0, 6.0)
			else UITheme.flat(UITheme.rgba(1, 1, 1, 0.06), 999, UITheme.LINE_2, 1, 16.0, 6.0)
	)
	self:_set_pill(pill_id)
	for _, ch in ipairs(self._stats:get_children()) do
		ch:queue_free()
	end
	-- Each card sits in a fixed slot so it can settle into place (the HBox ignores offsets).
	local function slot(card)
		local sl = W.Control.new()
		sl:set_mouse_filter(W.MOUSE_IGNORE)
		sl:set_min_size(card:get_combined_minimum_size())
		card:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
		sl:add_child(card)
		sl.card = card
		return sl
	end
	self._stats:add_child(
		slot(self:_stat_card("globe", UITheme.fmt_pct(tonumber(stats.peak_share) or 0.0), "Peak land", UITheme.AMBER))
	)
	self._stats:add_child(
		slot(self:_stat_card("troops", UITheme.fmt_troops(tonumber(stats.max_troops) or 0), "Max troops", UITheme.CYAN))
	)
	self._stats:add_child(
		slot(
			self:_stat_card(
				"skull",
				tostring(math.floor(tonumber(stats.kills) or 0)),
				"Nations eliminated",
				UITheme.RED
			)
		)
	)
	-- The match's length: a result reached after an elimination still reports the whole match
	-- (stats.match_s), not the moment the player fell (review R2-6).
	local secs = UIRules.result_seconds(kind, stats)
	self._stats:add_child(slot(self:_stat_card("clock", UITheme.fmt_time(secs), "Match duration", UITheme.VIOLET)))
	local solo = ctx:mode() == UICtx.MODE_SOLO
	local running = s ~= nil and s.phase == Defs.PHASE_PLAYING
	-- the Stars this match (or this life) paid, if the payout is in already
	local sess = ctx.session
	self:set_award(if sess ~= nil then sess.last_award else nil)
	self._again:set_visible(solo)
	self._spec:set_visible(kind == "eliminated" and running)
	self._spec:set_text("Keep watching")
	self._home:set_text("Return to title")
	self._next:set_visible(ctx:mode() == UICtx.MODE_MULTI and kind ~= "eliminated")
	self:_refresh_next()
	self:_show_takeover()
	self:apply_layout()
	-- Entrance (the dim stays put when the screen was already showing)
	if not was_shown then
		self._dim:set_modulate_a(0.0)
		W.fade(self._dim, 1.0, 0.6)
	elseif self._dim.modulate_a < 1.0 then
		W.fade(self._dim, 1.0, 0.3)
	end
	self._kicker:set_modulate_a(0.0)
	local t = self:create_tween():set_parallel(true)
	self._enter_tween = t
	t:tween_property(self._kicker, "modulate:a", 1.0, 0.5):set_delay(0.15)
	self._title:set_modulate_a(0.0)
	self._title:set_scale(1.35)
	t:tween_property(self._title, "modulate:a", 1.0, 0.45):set_delay(0.2)
	t:tween_property(self._title, "scale", 1.0, 0.9):set_delay(0.2):set_trans(W.TRANS_EXPO):set_ease(W.EASE_OUT)
	self._sub:set_modulate_a(0.0)
	t:tween_property(self._sub, "modulate:a", 1.0, 0.5):set_delay(0.6)
	self._winner:set_modulate_a(0.0)
	t:tween_property(self._winner, "modulate:a", 1.0, 0.5):set_delay(0.75)
	for i, sl in ipairs(self._stats:get_children()) do
		UICtx.pop_in(sl.card, 0.9 + 0.09 * (i - 1), 0.9, 0.45)
	end
	self._buttons:set_modulate_a(0.0)
	t:tween_property(self._buttons, "modulate:a", 1.0, 0.5):set_delay(1.35)
	if self._take.visible then
		UICtx.pop_in(self._take, 0.9, 0.9, 0.45)
		self._take_t = 0.0
	end
	self._sweep_t = 0.0
	ctx:set_world_input(false)
end

--- The takeover offer (Takeover.refresh): {name, color, price, saved, busy} or nil. Kept, and shown
--- on the ELIMINATED screen whenever it is up.
function GameOver.set_takeover(self, info: any)
	self._take_info = info
	if self.is_open then
		self:_show_takeover()
		self:apply_layout()
	end
end

--- Nation names spelled differently from their flag's name (the maps' nations vs the flags' names).
GameOver.FLAG_ALIASES = {
	["united states"] = "__us",
	["dr congo"] = "__cd",
	["dominican rep."] = "__do",
	["turkey"] = "__tr",
}

local _flag_by_name: { [string]: any }? = nil
--- The flag item whose name is `name` (the AI nations are named after the countries), or nil.
local function flag_named(name: string): any
	if _flag_by_name == nil then
		local m = {}
		local ok, Cosmetics = pcall(function()
			if typeof(game) == "Instance" then
				return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Cosmetics)
			end
			return (require :: any)("../../shared/Data/Cosmetics")
		end)
		if ok and type(Cosmetics) == "table" then
			for _, it in Cosmetics.all() do
				if it.kind == "flag" then
					local e = { item = it, image = Cosmetics.flag_image(it) }
					m[string.lower(it.name)] = e
					m["__" .. it.code] = e -- (FLAG_ALIASES by code)
				end
			end
		end
		_flag_by_name = m
	end
	local key = string.lower(name)
	return (_flag_by_name :: any)[GameOver.FLAG_ALIASES[key] or key]
end

function GameOver._show_takeover(self)
	local info = self._take_info
	local show = info ~= nil and self._kind == "eliminated"
	self._take:set_visible(show)
	self._gap4:set_visible(show)
	-- the offer takes the stat cards' place
	self._stats:set_visible(not show)
	-- one gold button at a time: the takeover's (PLAY AGAIN steps back to glass while it shows)
	local again = if show then "GlassButton" else "PrimaryButton"
	if self._again.theme_type_variation ~= again then
		self._again.theme_type_variation = again
		self._again:_theme_changed()
	end
	if not show then
		self._take_glow.ImageTransparency = 1
		return
	end
	local name = tostring(info.name)
	local fl = flag_named(name)
	self._take_flag:set_visible(fl ~= nil)
	self._take_sw:set_visible(fl == nil)
	if fl ~= nil then
		local img = self._take_flag_img
		img.Image = fl.image
		img.ImageRectOffset = Vector2.new(fl.item.x, fl.item.y)
		img.ImageRectSize = Vector2.new(fl.item.w, fl.item.h)
	elseif info.color ~= nil then
		UITheme.set_swatch_color(self._take_sw, info.color)
	end
	self._take_title:set_text("TAKE OVER " .. string.upper(name))
	self._take_btn:set_disabled(info.busy == true)
	local saved = info.saved > 0
	self._take_kicker:set_text(if saved then "YOUR TAKEOVER IS SAVED" else "DON'T GIVE UP")
	self._take_sub:set_text(
		if saved
			then "Use it now: " .. name .. "'s land, army and gold become yours."
			else name .. "'s land, army, gold and buildings become yours. Keep playing from where they stand."
	)
	self._take_btn:set_text(if info.busy then "…" elseif saved then "USE IT NOW" else "TAKE OVER")
	self._take_price.Text = tostring(info.price)
	self._take_tag.Visible = not saved and not info.busy
	self:_refresh_take_chips()
	self:_size_take()
end

--- What the offer gives, live: the nation's land, troops and gold.
function GameOver._refresh_take_chips(self)
	local info = self._take_info
	local s = self.ctx.state
	local o = if info ~= nil and s ~= nil then s:get_owner(info.target) else nil
	if o == nil then
		return
	end
	local land = UITheme.fmt_pct(s:land_share(info.target))
	local troops = UITheme.fmt_troops(tonumber(o.troops) or 0)
	local gold = UITheme.fmt_troops(tonumber(o.gold) or 0)
	self._chip.land:set_text(land)
	self._chip.troops:set_text(troops)
	self._chip.gold:set_text(gold)
	self._take_line:set_text(string.format("%s LAND  ·  %s TROOPS  ·  %s GOLD", land, troops, gold))
end

--- The card's sizes (desktop / phones), the title fitted to the card, the price tag in px.
function GameOver._size_take(self)
	local ctx = self.ctx
	local compact = ctx.compact
	local area = ctx:clear_rect()
	local w = math.min(if compact then 440.0 else 520.0, area.Width - 24.0)
	local pad_h = if compact then 16.0 else 22.0
	self._take:add_theme_stylebox_override(
		"panel",
		UITheme.flat(
			UITheme.rgba(0.11, 0.09, 0.055, 0.96),
			if compact then 14 else 18,
			UITheme.c(UITheme.GOLD, 0.85),
			2,
			pad_h,
			if compact then 12.0 else 18.0
		)
	)
	local inner = w - 2 * pad_h
	self._take_v:set_separation(if compact then 6 else 12)
	self._take_flag:set_min_size(if compact then Vector2.new(42, 28) else Vector2.new(57, 38))
	self._take_sw:set_min_size(if compact then Vector2.new(24, 24) else Vector2.new(30, 30))
	-- the title shrinks to fit next to the flag
	local head_w = inner - (if compact then 42 else 57) - 14
	local text = self._take_title.text or ""
	local px = if compact then 20 else 26
	while px > 14 and UITheme.text_width(text, px, 900, 1) > head_w do
		px -= 2
	end
	self._take_title:set_font_size(px)
	self._take_kicker:set_font_size(if compact then 10 else 11)
	self._take_line:set_font_size(if compact then 11 else 12)
	for _, chip in self._chip_panels do
		chip:add_theme_stylebox_override(
			"panel",
			UITheme.flat(UITheme.rgba(1, 1, 1, 0.06), 10, UITheme.rgba(1, 1, 1, 0.1), 1, if compact then 8.0 else 10.0, if compact then 4.0 else 7.0)
		)
	end
	for _, value in self._chip do
		value:set_font_size(if compact then 15 else 18)
	end
	self._take_sub:set_min_size(Vector2.new(inner, 0))
	self._take_sub:set_font_size(if compact then 12 else 13)
	self._take_btn:set_min_size(Vector2.new(inner, if compact then 50 else 60))
	self._take_btn:set_font_size(if compact then 17 else 20)
	-- (raw instances inside the button: px)
	local u = UITheme.scale
	local th = (if compact then 30 else 36) * u
	self._take_tag.Size = UDim2.fromOffset(0, th)
	self._take_tag.Position = UDim2.new(1, -10 * u, 0.5, 0)
	self._take_tag_pad.PaddingLeft = UDim.new(0, 10 * u)
	self._take_tag_pad.PaddingRight = UDim.new(0, 12 * u)
	self._take_tag_list.Padding = UDim.new(0, 5 * u)
	self._take_rbx.Size = UDim2.fromOffset(th * 0.55, th * 0.55)
	self._take_price.Size = UDim2.fromOffset(0, th)
	self._take_price.TextSize = math.floor(th * 0.62)
	self._take_corner.CornerRadius = UDim.new(0, 12 * u)
	self._take:set_min_size(Vector2.new(w, 0))
end

function GameOver.set_building(self, on: boolean)
	self._again:set_disabled(on)
	self._again:set_text(if on then "DEPLOYING…" else "PLAY AGAIN")
end

--- Fills the winner / leader pill for owner `id` (hidden when there is none, and on VICTORY).
--- Only touches the label when the text changes (called on every live refresh).
function GameOver._set_pill(self, id: number)
	local s = self.ctx.state
	local wo = if s ~= nil and id ~= 0 then s:get_owner(id) else nil
	local show = wo ~= nil and self._kind ~= "victory"
	self._pill_wanted = show
	-- (apply_layout may leave no room for it on a short screen)
	local vis = show and self._pill_room ~= false
	if vis ~= self._winner.visible then
		self._winner:set_visible(vis)
	end
	if wo == nil then
		self._pill_id = id
		return
	end
	local share = if self._pill_domination then self:_win_share(id) else s:land_share(id)
	local prefix = if self._pill_live then "Current leader  ·  " else ""
	local text = string.format("%s%s  ·  %s", prefix, wo.name, UITheme.fmt_pct(share))
	if id ~= self._pill_id then
		UITheme.set_swatch_color(self._winner_sw, wo.color)
	end
	self._pill_id = id
	if text ~= self._pill_text then
		self._pill_text = text
		self._winner_name:set_text(text)
	end
end

--- Share of the land that counts for victory: contestable land outside fallout (the Sim wins a
--- nation at Rules.WIN_SHARE of it). Equals land_share when nothing is irradiated.
function GameOver._win_share(self, id: number): number
	local ctx = self.ctx
	if ctx.win_share ~= nil then
		return ctx:win_share(id)
	end
	local s = ctx.state
	return if s ~= nil then s:land_share(id) else 0.0
end

--- "80.1% of all land" / "80.1% of the land outside fallout": the victory metric, worded so it
--- can never read as short of the 80% goal while fallout shrinks the land that counts (review R2-4).
function GameOver._win_phrase(self, id: number, all_land: string): string
	local s = self.ctx.state
	return UIRules.win_phrase(
		self:_win_share(id),
		if s ~= nil then s:land_share(id) else 0.0,
		if s ~= nil then (tonumber(s.fallout_count) or 0) else 0,
		all_land
	)
end

function GameOver._leader_id(self): number
	local s = self.ctx.state
	if s == nil then
		return 0
	end
	local r = s:ranking()
	return if #r > 0 then r[1].id else 0
end

--- Headline copy for every way a match can end, so the screen never claims something untrue.
function GameOver._copy(self, kind: string, winner: number, killer: number, reason: number, secs: number): any
	local ctx = self.ctx
	local s = ctx.state
	local R = UICtx.core("Rules")
	local wname = if s ~= nil and winner ~= 0 then s:owner_name(winner) else "Nobody"
	local wshare = if s ~= nil and winner ~= 0 then UITheme.fmt_pct(s:land_share(winner)) else "0%"
	-- Domination is decided on the land outside fallout (Sim._check_victory): the copy uses the same
	-- metric, so it always agrees with the 80% goal (review R2-4).
	local dominated = s ~= nil and winner ~= 0 and self:_win_share(winner) >= R.WIN_SHARE - 0.0005
	self._dominated = dominated
	local wdom = if s ~= nil and winner ~= 0 then self:_win_phrase(winner, "") else "0%"
	local lead = self:_leader_id()
	local lname = if s ~= nil and lead ~= 0 then s:owner_name(lead) else "Nobody"
	local lshare = if s ~= nil and lead ~= 0 then UITheme.fmt_pct(s:land_share(lead)) else "0%"
	local gold_top = Color3.new(1.0, 0.97, 0.86)
	local red_top = Color3.new(1.0, 0.85, 0.85)
	local cyan_top = Color3.new(0.92, 0.97, 1.0)
	local c = { kicker = "MATCH COMPLETE", title = "GAME OVER", sub = "", top = cyan_top, bottom = UITheme.CYAN }
	-- a team game: the team won, together
	local wt = if s ~= nil then tonumber(s.winner_team) or 0 else 0
	if kind ~= "eliminated" and wt ~= 0 and ctx.team_share ~= nil then
		local tshare = UITheme.fmt_pct(ctx:team_share(wt))
		local tname = ctx:team_label(wt)
		local the = if string.sub(tname, 1, 5) == "Team " then tname else "The " .. tname
		if reason == Defs.OVER_TIME then
			c.kicker = "TIME LIMIT REACHED"
		end
		if kind == "victory" then
			c.title = "VICTORY"
			c.top = gold_top
			c.bottom = UITheme.GOLD
			c.sub = if reason == Defs.OVER_TIME
				then string.format("Time! Your team holds the most land with %s.", tshare)
				else string.format("Your team won with %s of the land.", tshare)
		else
			c.title = if kind == "defeat" then "DEFEAT" else "MATCH OVER"
			c.top = if kind == "defeat" then red_top else cyan_top
			c.bottom = if kind == "defeat" then UITheme.RED else UITheme.CYAN
			c.sub = if reason == Defs.OVER_TIME
				then string.format("Time! %s holds the most land with %s.", the, tshare)
				else string.format("%s won with %s of the land.", the, tshare)
		end
		return c
	end
	if kind == "eliminated" then
		c.kicker = "YOUR NATION HAS FALLEN"
		c.title = "ELIMINATED"
		c.top = red_top
		c.bottom = UITheme.RED
		c.sub = if s ~= nil and killer ~= 0
			then string.format("Conquered by %s at %s.", s:owner_name(killer), UITheme.fmt_time(secs))
			else string.format("Your last territory fell at %s.", UITheme.fmt_time(secs))
	elseif kind == "victory" then
		c.title = "VICTORY"
		c.top = gold_top
		c.bottom = UITheme.GOLD
		if reason == Defs.OVER_TIME then
			c.kicker = "TIME LIMIT REACHED"
			c.sub = string.format("Time! You hold the most land with %s.", wshare)
		else
			c.sub = string.format(
				"You conquered the world with %s.",
				if s ~= nil and winner ~= 0 then self:_win_phrase(winner, " of all land") else wshare
			)
		end
	elseif kind == "defeat" then
		c.top = red_top
		c.bottom = UITheme.RED
		if reason == Defs.OVER_TIME then
			c.kicker = "TIME LIMIT REACHED"
			c.title = "TIME'S UP"
			c.sub = string.format("Time! %s holds the most land with %s.", wname, wshare)
		elseif dominated then
			c.title = "DEFEAT"
			c.sub = string.format("%s conquered the world (%s).", wname, wdom)
		else
			c.title = "DEFEAT"
			c.sub = string.format("%s won the war with %s of the land.", wname, wshare)
		end
	else
		if reason == Defs.OVER_TIME then
			c.kicker = "TIME LIMIT REACHED"
			c.title = "TIME'S UP"
			c.sub = string.format("Time! %s holds the most land with %s.", wname, wshare)
		elseif reason == Defs.OVER_DOMINATION then
			c.sub = if dominated
				then string.format("%s conquered the world (%s).", wname, wdom)
				else string.format("%s won the war with %s of the land.", wname, wshare)
		elseif reason == Defs.OVER_DEFEATED then
			c.title = "MATCH OVER"
			c.sub = string.format("Every commander has fallen. %s leads with %s.", lname, lshare)
		elseif reason == Defs.OVER_ABANDONED then
			c.title = "MATCH OVER"
			c.sub = string.format("Every commander left the match. %s leads with %s.", lname, lshare)
		else
			c.title = "MATCH OVER"
			c.sub = string.format("%s leads with %s.", lname, lshare)
		end
	end
	return c
end

--- Multiplayer: when the next match starts (results timer, then the lobby countdown).
function GameOver._refresh_next(self)
	if not self._next.visible then
		return
	end
	local ctx = self.ctx
	local lb = ctx:lobby()
	local stage = tostring(lb.stage or "")
	local cd = tonumber(lb.countdown_s) or 0.0
	if stage == "over" then
		local rematch = 12.0
		local sess = ctx.session
		if sess ~= nil and type(sess.REMATCH_COUNTDOWN_SEC) == "number" then
			rematch = sess.REMATCH_COUNTDOWN_SEC
		end
		self._next:set_text(
			string.format(
				"Next match in %s  ·  results close in %s",
				UITheme.fmt_time(math.ceil(cd + rematch)),
				UITheme.fmt_time(math.ceil(cd))
			)
		)
	elseif stage == "lobby" then
		self._next:set_text("Next match in " .. UITheme.fmt_time(math.ceil(cd)))
	else
		self._next:set_text("Stay here for the next match, or return to the title.")
	end
end

function GameOver.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	if self._enter_tween ~= nil then
		self._enter_tween:kill()
		self._enter_tween = nil
	end
	local t = self:create_tween()
	self._close_tween = t
	t:tween_property(self, "modulate:a", 0.0, 0.25)
	t:tween_callback(function()
		if self._close_tween == t then
			self._close_tween = nil
		end
		if not self.is_open then
			self:set_visible(false)
			self:set_modulate_a(1.0)
		end
	end)
	self.ctx:set_world_input(true)
end

function GameOver.apply_layout(self)
	local ctx = self.ctx
	local compact = ctx.compact
	local title_px = if compact
		then math.floor(math.clamp(ctx.vp.Y * 0.14, 44.0, 60.0))
		else math.floor(math.clamp(math.min(ctx.vp.X * 0.07, ctx.vp.Y * 0.12), 72.0, 128.0))
	if compact and self._take.visible then
		-- (phones with the takeover offer: a smaller headline keeps the offer's chips on screen)
		title_px = 40
	end
	self._title:set_px(title_px)
	self._title.spacing = if compact then 6 else 10
	self._title:update_minimum_size()
	self._sub:set_font_size(if compact then 14 else 18)
	self._kicker:set_font_size(if compact then 11 else 14)
	for _, b in ipairs({ self._again, self._spec, self._home }) do
		b:set_min_size(Vector2.new(if compact then 150 else 200, if compact then 44 else 52))
	end
	self._stars_btn:set_min_size(Vector2.new(if compact then 110 else 150, if compact then 44 else 52))
	self._gap4:set_min_size(Vector2.new(0, if compact then (if self._take.visible then 6 else 10) else 16))
	local take = self._take.visible
	-- the offers: not beside the takeover offer (one thing to buy at a time)
	local offers = (self._goal_wanted == true or self._x2_wanted == true) and not take
	self._goal_btn:set_visible(self._goal_wanted == true)
	self._x2_btn:set_visible(self._x2_wanted == true)
	for _, b in ipairs({ self._goal_btn, self._x2_btn }) do
		b:set_min_size(Vector2.new(0, if compact then 34 else 40))
		b:set_font_size(if compact then 12 else 13)
	end
	self._gap_offers:set_min_size(Vector2.new(0, if compact then 6 else 10))
	self._offers:set_visible(offers)
	self._gap_offers:set_visible(offers)
	self._sub:set_visible(true)
	self._gap_next:set_visible(self._next.visible)
	if take then
		self:_size_take()
		-- phones: the chips fold into one line under the card's title, the kicker goes
		self._take_sub:set_visible(true)
		self._take_chips:set_visible(not compact)
		self._take_line:set_visible(compact)
		self._take_kicker:set_visible(not compact)
	end
	self._pill_room = true
	self._winner:set_visible(self._pill_wanted == true)
	-- (the offer takes the stat cards' place)
	self._stats:set_visible(not take)
	self._gap3:set_visible(not take)
	self._gap2:set_min_size(Vector2.new(0, if compact then 14 else (if take then 18 else 26)))
	self._gap3:set_min_size(Vector2.new(0, if compact then 14 else (if take then 18 else 28)))
	local sz = self._center:get_combined_minimum_size()
	local area = ctx:clear_rect()
	if sz.Y > area.Height - 8.0 then
		-- Short screens (phones; a screen with the takeover offer): drop the kicker line and tighten
		-- the gaps until it fits.
		self._kicker:set_visible(false)
		self._gap2:set_min_size(Vector2.new(0, 8))
		self._gap3:set_min_size(Vector2.new(0, 8))
		sz = self._center:get_combined_minimum_size()
		-- still too tall with the offers (a phone): the "Current leader" pill gives them its line (the
		-- leaderboard says who leads; a result's winner stays), then the 2x Stars offer goes, then
		-- the next unlock too
		if offers and sz.Y > area.Height - 8.0 and self._pill_live and self._winner.visible then
			self._pill_room = false
			self._winner:set_visible(false)
			sz = self._center:get_combined_minimum_size()
		end
		if offers and sz.Y > area.Height - 8.0 and self._x2_btn.visible and self._goal_btn.visible then
			self._x2_btn:set_visible(false)
			sz = self._center:get_combined_minimum_size()
		end
		if offers and sz.Y > area.Height - 8.0 then
			self._offers:set_visible(false)
			self._gap_offers:set_visible(false)
			-- (and the pill has its line back)
			if not self._pill_room and not take then
				self._pill_room = true
				self._winner:set_visible(self._pill_wanted == true)
			end
			sz = self._center:get_combined_minimum_size()
		end
		-- still too tall with the takeover offer: the leader pill steps aside
		if take and sz.Y > area.Height - 8.0 then
			self._pill_room = false
			self._winner:set_visible(false)
			sz = self._center:get_combined_minimum_size()
		end
		-- then the offer's own extras: its line of copy, then its chips
		if take and sz.Y > area.Height - 8.0 then
			self._take_sub:set_visible(false)
			sz = self._center:get_combined_minimum_size()
		end
		-- ("Conquered by X": the offer names X already)
		if take and sz.Y > area.Height - 8.0 then
			self._sub:set_visible(false)
			sz = self._center:get_combined_minimum_size()
		end
		if take and sz.Y > area.Height - 8.0 and self._take_chips.visible then
			self._take_chips:set_visible(false)
			self._take_line:set_visible(true)
			sz = self._center:get_combined_minimum_size()
		end
	else
		self._kicker:set_visible(true)
	end
	local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
	local y = math.max(p.Y, area.Min.Y + 2.0)
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(y + 0.5))
	self._center:set_offsets(rp.X, rp.Y, rp.X + sz.X, rp.Y + sz.Y)
	self._center:reset_size()
	local ts = self._title:get_combined_minimum_size()
	self._title.y0 = ts.Y * 0.2
	self._title.span = ts.Y * 0.62
	self._title:_redraw()
end

--- The offer's life: its glow breathes, a shine sweeps over the button every few seconds.
function GameOver._animate_take(self, delta: number)
	local glow = self._take_glow
	if not self._take.visible then
		if glow.ImageTransparency < 1 then
			glow.ImageTransparency = 1
		end
		return
	end
	self._take_t += delta
	local t = self._take_t
	-- the glow sits under the card (the column's px coordinates)
	local cg, tg = self._center.gui, self._take.gui
	local rel = tg.AbsolutePosition - cg.AbsolutePosition
	local sz = tg.AbsoluteSize
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromOffset(rel.X + sz.X * 0.5, rel.Y + sz.Y * 0.5)
	glow.Size = UDim2.fromOffset(sz.X * 1.75, sz.Y * 2.3)
	local a = (0.5 + 0.15 * math.sin(t * 2.6)) * self._take.modulate_a * self.modulate_a
	glow.ImageTransparency = 1 - a
	local k = (t % 3.2) / 0.9
	self._take_shine.Offset = Vector2.new(if k < 1 then -1 + 2 * k else 1, 0)
end

function GameOver._process(self, delta: number)
	if not self.is_open then
		return
	end
	-- the Stars count up to the payout (a tick for every step, a chime at the end)
	local award = self._award
	if award ~= nil and not self._stars_done and self._buttons.modulate_a > 0.5 then
		local total = award.total
		self._stars_shown = math.min(total, self._stars_shown + math.max(total / 1.1, 60) * delta)
		local k = self._stars_shown / math.max(total, 1)
		self._stars_btn:set_text("+" .. UICtx.commas(math.floor(self._stars_shown)))
		if self._stars_shown >= total then
			self._stars_done = true
			self.ctx:sfx("star_get")
			UICtx.pop_in(self._stars_btn, 0.0, 1.12, 0.3)
		else
			self.ctx:sfx("star_tick", -6.0, 0.0, 0.8 + 0.6 * k)
		end
	end
	self._next_accum += delta
	if self._next_accum >= 0.25 then
		self._next_accum = 0.0
		self:_refresh_next()
		-- ELIMINATED while the war goes on: the "Current leader" pill follows the leaderboard
		-- (review R2-2; the original kept the snapshot taken when the screen opened).
		local s = self.ctx.state
		if self._pill_live and s ~= nil and s.phase == Defs.PHASE_PLAYING then
			self:_set_pill(self:_leader_id())
		end
		if self._take.visible then
			self:_refresh_take_chips()
		end
	end
	self:_animate_take(delta)
	if self._sweep_t < 0.0 then
		return
	end
	self._sweep_t += delta
	local w = self._title.size.X
	self._title.sweep = -200.0 + (w + 400.0) * math.clamp((self._sweep_t - 0.9) / 1.1, 0.0, 1.0)
	self._title:_redraw()
	if self._sweep_t > 2.2 then
		self._sweep_t = -1.0
		self._title.sweep = -10000.0
		self._title:_redraw()
	end
end

return GameOver
