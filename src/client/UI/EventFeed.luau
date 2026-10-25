--!nonstrict
-- Port of scripts/ui/event_feed.gd (UIEventFeed)
-- Lower-left event feed: stacking toasts coloured by message category that fade on their own,
-- plus actionable alliance cards with an expiry bar: requests (Accept / Decline) and the
-- "about to expire" renewal prompt (Renew / Ignore). Phones show one
-- single-line toast at a time (a newer one replaces it; a tap dismisses it) and one-row cards.
--
-- EventFeed.new(ctx, top_mode = false). Members: _stack, top_mode.
-- Methods: apply_layout(bottom_y), apply_layout_top(y), stack_rect(), clear(),
-- toast(category, text, icon_name?, seconds?), alliance_request(from_id), close_request(from_id),
-- alliance_renewal(other, expires_at, other_asked), close_renewal(other), has_renewal_card(other),
-- close_all_requests(), has_request_card(from_id); per frame update(dt).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local FillBar = require("./FillBar")

local EventFeed = W.class(W.Control)

EventFeed.TOAST_SECONDS = 6.5
EventFeed.INFO_SECONDS = 4.0
EventFeed.ALERT_SECONDS = 9.0
--- Phones: short lives, one line.
EventFeed.PHONE_INFO_SECONDS = 2.5
EventFeed.PHONE_SECONDS = 3.5
EventFeed.PHONE_ALERT_SECONDS = 5.0
--- Phones: a toast's widest (longer text ends in "…"), its text, and an alliance row's buttons.
--- Smaller since 2026-10-10 ("notifs on mobile should be smaller"): 360 wide, 12 pt and 44 pt buttons
--- made a toast half a small phone's width and an alliance row a seventh of its height.
EventFeed.PHONE_MAX_W = 260.0
EventFeed.PHONE_FONT = 11
EventFeed.PHONE_BUTTON = 32.0

local function msec(): number
	return os.clock() * 1000.0
end

local function Defs(): any
	return UITheme.core("Defs")
end

function EventFeed.new(c: any, top: boolean?)
	local self = setmetatable({}, EventFeed.__mt)
	W.Control._init(self)
	self.ctx = c
	--- Top-centre variant (session notices): grows downwards, visible on every screen.
	self.top_mode = top == true
	self._cards = {} -- from owner id -> request card
	self._recent = {} -- text -> {node, count, msec, badge}
	self._bottom = 120.0
	self._top_limit = 340.0
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._stack = UITheme.vbox(8)
	self._stack:set_alignment(if self.top_mode then W.ALIGN_BEGIN else W.ALIGN_END)
	self:add_child(self._stack)
	return self
end

--- Top-centre placement for notices.
function EventFeed.apply_layout_top(self, y: number)
	local ctx = self.ctx
	local w = if not ctx.compact then 520.0 else 380.0
	local st = self._stack
	st.anchor_left, st.anchor_right, st.anchor_top, st.anchor_bottom = 0.5, 0.5, 0.0, 0.0
	st.grow_horizontal = W.GROW_BOTH
	st.grow_vertical = W.GROW_END
	w = math.min(w, ctx.vp.X - ctx.insets.x - ctx.insets.z - 24.0)
	local dx, yy = ctx:place_top(w, y)
	st.offset_left = dx - w * 0.5
	st.offset_right = dx + w * 0.5
	st.offset_top = yy
	st.offset_bottom = yy
	st:set_min_size(Vector2.new(w, 0))
	self._bottom = ctx.vp.Y
	self._top_limit = 0.0
end

function EventFeed.apply_layout(self, bottom_y: number)
	local ctx = self.ctx
	local st = self._stack
	self._bottom = bottom_y
	if ctx.compact then
		-- Phones: a narrow column under the top bar (top-left), clear of the globe's centre and of
		-- the bottom-left thumb area where target / inspect cards appear.
		local lx = 8.0 + ctx.insets.x
		local cw = 0.0 -- cards and toasts size to their content
		local ty = ctx.airship_bar.Max.Y + 2.0
		st.anchor_left, st.anchor_right, st.anchor_top, st.anchor_bottom = 0.0, 0.0, 0.0, 0.0
		st.grow_vertical = W.GROW_END
		st.grow_horizontal = W.GROW_END
		st:set_alignment(W.ALIGN_BEGIN)
		st.offset_left = lx
		st.offset_right = lx + cw
		st.offset_top = ty
		st.offset_bottom = ty
		st:set_min_size(Vector2.new(cw, 0))
		self._top_limit = ty
		st:queue_layout()
		self:_trim()
		return
	end
	st:set_alignment(W.ALIGN_END)
	local left = if not ctx.compact then 16.0 + ctx.insets.x else 8.0 + ctx.insets.x
	local w = if not ctx.compact then 340.0 else 290.0
	st.anchor_left, st.anchor_right, st.anchor_top, st.anchor_bottom = 0.0, 0.0, 1.0, 1.0
	st.grow_vertical = W.GROW_BEGIN
	st.grow_horizontal = W.GROW_END
	st.offset_left = left
	st.offset_right = left + w
	st.offset_bottom = -(ctx.vp.Y - bottom_y)
	st.offset_top = st.offset_bottom
	st:set_min_size(Vector2.new(w, 0))
	-- Never grow into the reserved top-left area (Roblox top bar / chat).
	local reserved = if not ctx.compact then ctx.reserved_top_left.Max.Y else 64.0
	self._top_limit = reserved + 12.0 + ctx.insets.y
	st:queue_layout()
	self:_trim()
end

function EventFeed.stack_rect(self): Rect
	if self:is_visible_in_tree() then
		return self._stack:get_global_rect()
	end
	return Rect.new(0, 0, 0, 0)
end

function EventFeed.clear(self)
	for _, ch in ipairs(self._stack:get_children()) do
		ch:queue_free()
	end
	table.clear(self._cards)
	table.clear(self._recent)
end

-- ---------------------------------------------------------------------------------------------
-- Toasts
-- ---------------------------------------------------------------------------------------------

function EventFeed.toast(self, category: number, text: string, icon_name: string?, seconds: number?)
	local ctx = self.ctx
	local T = UITheme
	local D = Defs()
	if text == nil or string.match(text, "^%s*$") then
		return
	end
	local icon = icon_name or ""
	local secs = seconds or -1.0
	local now = msec()
	local prev = self._recent[text]
	if prev ~= nil and not prev.node._freed and now - prev.msec < 4000 then
		prev.count += 1
		prev.msec = now
		prev.badge:set_text(string.format("×%d", prev.count))
		prev.badge:set_visible(true)
		prev.node:set_meta(
			"expire",
			now + (if ctx.compact then EventFeed.PHONE_SECONDS else EventFeed.TOAST_SECONDS) * 1000.0
		)
		return
	end
	if ctx.compact and not self.top_mode then
		self:_toast_line(category, text, icon, secs)
		return
	end
	local col = T.msg_color(category)
	local card =
		GlassPanel.new(if not ctx.compact then 12.0 else 10.0, if not ctx.compact then 9.0 else 6.0, T.R_MD, true, 12)
	-- On touch a toast must swallow taps (they would otherwise order an attack underneath).
	card:set_mouse_filter(if ctx.touch then W.MOUSE_STOP else W.MOUSE_IGNORE)
	card:set_accent(col)
	local row = T.hbox(10)
	card:add_child(row)
	row:add_child(
		self:_icon_disc(if icon ~= "" then icon else T.msg_icon(category), col, if not ctx.compact then 26.0 else 22.0)
	)
	local l = T.label(text, if not ctx.compact then 13 else 12, 500, T.TEXT)
	l:set_autowrap(true)
	l.size_flags_horizontal = W.EXPAND_FILL
	l:set_min_size(Vector2.new(200, 0))
	l.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(l)
	local badge = T.label("", 11, 700, col)
	badge:set_visible(false)
	badge.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(badge)
	local life = secs
	if life <= 0 then
		if category == D.MSG_ALERT then
			life = EventFeed.ALERT_SECONDS
		elseif category == D.MSG_INFO then
			life = if not ctx.compact then EventFeed.INFO_SECONDS else 3.0
		else
			life = EventFeed.TOAST_SECONDS
		end
	end
	card:set_meta("expire", now + life * 1000.0)
	card:set_meta("kind", "toast")
	self:_add_toast_node(card)
	self._recent[text] = { node = card, count = 1, msec = now, badge = badge }
	W.pop_in(card, 0.0, 0.94, 0.32)
	self:_trim()
end

--- Phones: one short line at a time. A newer toast replaces the current one, except that routine
--- info never pushes out an alert that has barely been seen. Tap to dismiss.
function EventFeed._toast_line(self, category: number, text: string, icon_name: string, seconds: number)
	local ctx = self.ctx
	local T = UITheme
	local D = Defs()
	local now = msec()
	for _, c in ipairs(self._stack:get_children()) do
		if not c:has_meta("leaving") and c:get_meta("kind", "") == "toast" then
			if
				category == D.MSG_INFO
				and c:get_meta("cat", -1) == D.MSG_ALERT
				and now - c:get_meta("born", 0) < 2000
			then
				return
			end
			self._stack:remove_child(c) -- swap in place: the line never jumps
			c:queue_free()
		end
	end
	local col = T.msg_color(category)
	local card = GlassPanel.new(8.0, 2.0, T.R_MD, true, 10)
	card:set_mouse_filter(if ctx.touch then W.MOUSE_STOP else W.MOUSE_IGNORE)
	card.size_flags_horizontal = W.SHRINK_BEGIN
	card:set_accent(col)
	card.gui_input:Connect(function(e)
		if e.kind == "button" and e.button == 1 and not e.pressed then
			self:_remove(card, true)
		end
	end)
	local fs = EventFeed.PHONE_FONT
	local row = T.hbox(5)
	row:set_min_size(Vector2.new(0, 18))
	card:add_child(row)
	local ic = T.icon_rect(if icon_name ~= "" then icon_name else T.msg_icon(category), 11.0, col)
	ic.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(ic)
	local l = T.label(text, fs, 600, T.TEXT)
	l.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	l:set_min_size(Vector2.new(math.min(T.measure_text(text, fs, 600) + 2.0, EventFeed.PHONE_MAX_W), 0))
	l.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(l)
	local badge = T.label("", fs, 700, col)
	badge:set_visible(false)
	badge.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(badge)
	local life = if seconds > 0
		then seconds
		else (if category == D.MSG_ALERT
			then EventFeed.PHONE_ALERT_SECONDS
			else (if category == D.MSG_INFO then EventFeed.PHONE_INFO_SECONDS else EventFeed.PHONE_SECONDS))
	life = math.min(life, EventFeed.PHONE_ALERT_SECONDS)
	card:set_meta("expire", now + life * 1000.0)
	card:set_meta("kind", "toast")
	card:set_meta("cat", category)
	card:set_meta("born", now)
	self:_add_toast_node(card)
	self._recent[text] = { node = card, count = 1, msec = now, badge = badge }
	W.pop_in(card, 0.0, 0.96, 0.2)
	self:_trim()
end

--- Actionable cards never move under a finger: toasts come and go on the far side of them
--- (above the cards in the bottom-anchored desktop stack, below them in the phone column).
function EventFeed._add_toast_node(self, card)
	self._stack:add_child(card)
	if self.top_mode then
		return
	end
	local first_card = -1
	for i, c in ipairs(self._stack.children) do
		if c:get_meta("kind", "") == "card" then
			first_card = i - 1
			break
		end
	end
	if first_card >= 0 and not self.ctx.compact then
		self._stack:move_child(card, first_card)
	end
end

function EventFeed._add_card_node(self, card)
	self._stack:add_child(card)
	if self.ctx.compact and not self.top_mode then
		-- Phone column grows downward: cards first, toasts after them.
		local last_card = -1
		for i, c in ipairs(self._stack.children) do
			if c ~= card and c:get_meta("kind", "") == "card" then
				last_card = i - 1
			end
		end
		self._stack:move_child(card, last_card + 1)
	end
end

function EventFeed._icon_disc(_self, icon_name: string, col: any, px: number)
	local T = UITheme
	local p = W.Panel.new()
	p:set_mouse_filter(W.MOUSE_IGNORE)
	p:set_min_size(Vector2.new(px, px))
	p.size_flags_vertical = W.SHRINK_CENTER
	p:add_theme_stylebox_override("panel", T.flat(T.c(col, 0.16), math.floor(px * 0.5), T.c(col, 0.4), 1))
	local ic = T.icon_rect(icon_name, px * 0.52, col)
	ic.size_flags_horizontal = W.SHRINK_CENTER
	ic.size_flags_vertical = W.SHRINK_CENTER
	p:add_child(ic)
	return p
end

function EventFeed._remove(_self, node, fast: boolean?)
	if node._freed or node:has_meta("leaving") then
		return
	end
	node:set_meta("leaving", true)
	local t = node:create_tween()
	t:tween_property(node, "modulate:a", 0.0, if fast then 0.12 else 0.35)
	t:tween_callback(function()
		node:queue_free()
	end)
end

function EventFeed._trim(self)
	-- Drop the oldest toasts while the stack would reach into the reserved top-left area.
	local ctx = self.ctx
	local guard = 0
	while guard < 12 do
		guard += 1
		local h = 0.0
		local toasts = {}
		for _, c in ipairs(self._stack.children) do
			if not c:has_meta("leaving") then
				h += c:get_combined_minimum_size().Y + 8.0
				if c:get_meta("kind", "") == "toast" then
					table.insert(toasts, c)
				end
			end
		end
		local limit = self._bottom - self._top_limit
		local max_toasts = 5
		if self.top_mode then
			max_toasts = 3
		elseif ctx.compact then
			max_toasts = 1
		end
		if (h <= limit and #toasts <= max_toasts) or #toasts == 0 then
			return
		end
		self._stack:remove_child(toasts[1])
		toasts[1]:queue_free()
	end
end

-- ---------------------------------------------------------------------------------------------
-- Alliance requests
-- ---------------------------------------------------------------------------------------------

--- An incoming alliance request: Accept / Decline, the bar runs out with the request.
function EventFeed.alliance_request(self, from_id: number)
	local ctx = self.ctx
	self:_ally_card(from_id, from_id, {
		text = "proposes an alliance",
		row_text = "wants an alliance",
		yes = "Accept",
		no = "Decline",
		on_yes = function()
			ctx:send({ type = "ally_reply", target = from_id, accept = true })
		end,
		on_no = function()
			ctx:send({ type = "ally_reply", target = from_id, accept = false })
		end,
		tick_start = ctx:render_tick(),
		span = UITheme.core("Rules").ALLY_REQUEST_TICKS,
	})
end

--- The "about to expire" event: the alliance with `other` is in its last
--- ALLIANCE_EXTEND_WINDOW_TICKS; Renew sends ally_extend (renewed once both asked). The bar runs
--- out with the alliance.
function EventFeed.alliance_renewal(self, other: number, expires_at: number, other_asked: boolean)
	local ctx = self.ctx
	local window = UITheme.core("Rules").ALLIANCE_EXTEND_WINDOW_TICKS
	self:_ally_card(-other, other, {
		text = if other_asked then "wants to renew your alliance" else "alliance is about to expire",
		row_text = if other_asked then "wants to renew" else "alliance expiring",
		yes = "Renew",
		no = "Ignore",
		on_yes = function()
			ctx:send({ type = "ally_extend", target = other })
		end,
		on_no = function() end,
		tick_start = expires_at - window,
		span = window,
	})
end

function EventFeed.close_renewal(self, other: number)
	self:close_request(-other)
end

function EventFeed.has_renewal_card(self, other: number): boolean
	return self._cards[-other] ~= nil
end

function EventFeed._ally_card(self, key: number, owner_id: number, spec: { [string]: any })
	local ctx = self.ctx
	local T = UITheme
	local s = ctx.state
	if s == nil or self._cards[key] ~= nil then
		return
	end
	local o = s:get_owner(owner_id)
	if o == nil then
		return
	end
	if ctx.compact then
		self:_alliance_row(key, o, spec)
		return
	end
	local card =
		GlassPanel.new(if not ctx.compact then 14.0 else 10.0, if not ctx.compact then 12.0 else 8.0, T.R_MD, true, 16)
	card:set_accent(T.VIOLET)
	card:set_border(T.c(T.VIOLET, 0.35))
	card:set_meta("kind", "card")
	local v = T.vbox(if not ctx.compact then 8 else 5)
	card:add_child(v)
	local head = T.hbox(10)
	head:add_child(self:_icon_disc("alliance", T.VIOLET, if not ctx.compact then 30.0 else 24.0))
	local tv = T.vbox(0)
	tv.size_flags_horizontal = W.EXPAND_FILL
	local nr = T.hbox(6)
	nr:add_child(T.swatch(o.color, 10.0, 3))
	local nl = T.label(o.name, 14, 700)
	nl.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	nl.size_flags_horizontal = W.EXPAND_FILL
	nl:set_min_size(Vector2.new(60, 0))
	nr:add_child(nl)
	tv:add_child(nr)
	tv:add_child(T.label(spec.text, 12, 500, T.TEXT_2))
	head:add_child(tv)
	v:add_child(head)
	local bar = FillBar.new(3.0, T.VIOLET)
	bar.glow = false
	bar:set_target(1.0, true)
	v:add_child(bar)
	local btns = T.hbox(8)
	local accept = T.button(spec.yes, "PrimaryButton", "", if not ctx.touch then 34.0 else 44.0)
	accept:set_font_size(13)
	accept.size_flags_horizontal = W.EXPAND_FILL
	local decline = T.button(spec.no, "GlassButton", "", if not ctx.touch then 34.0 else 44.0)
	decline:set_font_size(13)
	decline.size_flags_horizontal = W.EXPAND_FILL
	btns:add_child(accept)
	btns:add_child(decline)
	v:add_child(btns)
	accept.pressed:Connect(function()
		spec.on_yes()
		self:close_request(key)
	end)
	decline.pressed:Connect(function()
		spec.on_no()
		self:close_request(key)
	end)
	card:set_meta("tick_start", spec.tick_start)
	card:set_meta("span", spec.span)
	card:set_meta("owner_name", o.name)
	card:set_meta("bar", bar)
	self._cards[key] = card
	self:_add_card_node(card)
	W.pop_in(card, 0.0, 0.92, 0.36)
	self:_trim()
end

--- Phones: one row: [alliance] ■ Name wants an alliance [✓] [✕], with a thin expiry line.
function EventFeed._alliance_row(self, key: number, o: any, spec: { [string]: any })
	local T = UITheme
	local card = GlassPanel.new(8.0, 2.0, T.R_MD, true, 14)
	card:set_accent(T.VIOLET)
	card:set_border(T.c(T.VIOLET, 0.35))
	card:set_meta("kind", "card")
	card.size_flags_horizontal = W.SHRINK_BEGIN
	local v = T.vbox(0)
	card:add_child(v)
	local fs = EventFeed.PHONE_FONT
	local bs = EventFeed.PHONE_BUTTON
	local row = T.hbox(5)
	local ic = T.icon_rect("alliance", 12.0, T.VIOLET)
	ic.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(ic)
	local sw = T.swatch(o.color, 8.0, 2)
	sw.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(sw)
	local nl = T.label(o.name, fs + 1, 700)
	nl.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	nl:set_min_size(Vector2.new(math.min(T.measure_text(o.name, fs + 1, 700) + 2.0, 100.0), 0))
	nl.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(nl)
	local wl = T.label(spec.row_text, fs, 500, T.TEXT_2)
	wl.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(wl)
	local accept = T.button("", "PrimaryButton", "check", bs)
	accept.name = spec.yes
	accept:set_min_size(Vector2.new(bs, bs))
	local decline = T.button("", "GlassButton", "close", bs)
	decline.name = spec.no
	decline:set_min_size(Vector2.new(bs, bs))
	for _, b in ipairs({ accept, decline }) do
		b.expand_icon = true
		b:add_theme_constant_override("icon_max_width", 14)
		b.icon_alignment = W.ALIGN_CENTER
	end
	-- Icon-only buttons: the theme's wide text margins would leave no room for the icon.
	local acc = T.flat(T.AMBER, T.R_MD, T.CLEAR, 0, 4.0, 4.0)
	acc.bw_bottom = 3
	acc.border = T.to_rgba(T.AMBER_LO)
	local acc_h = T.dup(acc)
	acc_h.bg = T.to_rgba(T.AMBER_HI)
	local dec = T.flat(T.FILL, T.R_MD, T.LINE, 1, 4.0, 4.0)
	local dec_h = T.flat(T.FILL_2, T.R_MD, T.LINE_2, 1, 4.0, 4.0)
	for _, st in ipairs(W.BUTTON_STATES) do
		local hot = st ~= "normal" and st ~= "disabled"
		accept:add_theme_stylebox_override(st, if hot then acc_h else acc)
		decline:add_theme_stylebox_override(st, if hot then dec_h else dec)
	end
	row:add_child(accept)
	row:add_child(decline)
	v:add_child(row)
	local bar = FillBar.new(2.0, T.VIOLET)
	bar.glow = false
	bar:set_target(1.0, true)
	v:add_child(bar)
	accept.pressed:Connect(function()
		spec.on_yes()
		self:close_request(key)
	end)
	decline.pressed:Connect(function()
		spec.on_no()
		self:close_request(key)
	end)
	card:set_meta("tick_start", spec.tick_start)
	card:set_meta("span", spec.span)
	card:set_meta("owner_name", o.name)
	card:set_meta("bar", bar)
	self._cards[key] = card
	self:_add_card_node(card)
	W.pop_in(card, 0.0, 0.94, 0.3)
	self:_trim()
end

function EventFeed.close_request(self, from_id: number)
	local card = self._cards[from_id]
	self._cards[from_id] = nil
	if card ~= nil then
		self:_remove(card)
	end
end

function EventFeed.close_all_requests(self)
	local ids = {}
	for id in pairs(self._cards) do
		table.insert(ids, id)
	end
	for _, id in ipairs(ids) do
		self:close_request(id)
	end
end

function EventFeed.has_request_card(self, from_id: number): boolean
	return self._cards[from_id] ~= nil
end

--- Per frame (GDScript _process + _physics_process).
function EventFeed.update(self, _delta: number)
	local now = msec()
	for _, c in ipairs(self._stack:get_children()) do
		local e = c:get_meta("expire", nil)
		if e ~= nil and now > e then
			self:_remove(c)
		end
	end
	-- Expiry bars on alliance cards.
	if next(self._cards) == nil then
		return
	end
	local tick = self.ctx:render_tick()
	local done = {}
	for from_id, card in pairs(self._cards) do
		if card._freed then
			table.insert(done, from_id)
		else
			local start = card:get_meta("tick_start", tick)
			local left = 1.0 - (tick - start) / math.max(card:get_meta("span", 1), 1)
			local bar = card:get_meta("bar", nil)
			if bar ~= nil then
				bar:set_target(left, true)
			end
			if left <= 0 then
				table.insert(done, from_id)
			end
		end
	end
	for _, id in ipairs(done) do
		self:close_request(id)
	end
end

return EventFeed
