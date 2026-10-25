--!nonstrict
-- Port of scripts/ui/attacks_panel.gd (UIAttacksPanel)
-- Active attacks involving you (right side, under the leaderboard): incoming fronts in red with a
-- Focus button, outgoing fronts and expansions with their committed troops and a Retreat button.
-- Phones show only a small chip (icon + count, red when you are attacked); a tap opens the list
-- as a peek that folds itself away again.
--
-- Signals: retreat_requested(aid), toggled(collapsed). Members: panel, collapsed, manual, tray_open.
-- Methods: apply_layout(top, bottom_limit), peek(), bottom_edge(), mark_dirty(), involved(),
-- committed(), refresh(); per frame update(dt).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local Signal = UITheme.core("Signal")

local AttacksPanel = W.class(W.Control)

AttacksPanel.MAX_ROWS_DESKTOP = 6
AttacksPanel.MAX_ROWS_PHONE = 2
--- Lists this short never get summarised.
AttacksPanel.ALWAYS_ROWS = 2
--- Phones: seconds an opened list stays open after the last touch.
AttacksPanel.PEEK_SECONDS = 8.0

local function msec(): number
	return os.clock() * 1000.0
end

-- ---------------------------------------------------------------------------------------------
-- Row
-- ---------------------------------------------------------------------------------------------

local Row = W.class(W.Panel)
AttacksPanel.Row = Row

function Row.new(c: any)
	local self = setmetatable({}, Row.__mt)
	W.Control._init(self)
	W.Panel._init_panel(self)
	local T = UITheme
	self.ctx = c
	self.aid = 0
	self.incoming = nil
	self.focus_tile = -1
	self.focus_id = 0
	self.retreat = Signal.new()
	self.touched = Signal.new()
	self:set_mouse_filter(W.MOUSE_STOP)
	self._bg_in = T.flat(T.c(T.RED, 0.14), 8, T.c(T.RED, 0.45), 1, 8.0, 3.0)
	self._bg_out = T.flat(T.rgba(1, 1, 1, 0.04), 8, T.rgba(1, 1, 1, 0.06), 1, 8.0, 3.0)
	self:add_theme_stylebox_override("panel", self._bg_out)
	local h = T.hbox(8)
	self:add_child(h)
	self.arrow = T.icon_rect("attack", 13.0, T.AMBER)
	self.arrow.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self.arrow)
	self.sw = T.swatch(T.TEXT, 9.0, 2)
	h:add_child(self.sw)
	self.name_l = T.label("", 13, 600)
	self.name_l.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	self.name_l.size_flags_horizontal = W.EXPAND_FILL
	self.name_l:set_min_size(Vector2.new(40, 0))
	self.name_l.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self.name_l)
	self.troops_l = T.label("", 13, 700)
	T.fix_width(self.troops_l, T.text_width("888.8K", 13, 700) + 2.0, W.ALIGN_RIGHT)
	self.troops_l.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self.troops_l)
	local action = W.Button.new("", "GlassButton")
	action.expand_icon = true
	action:add_theme_constant_override("icon_max_width", 14)
	action:set_font_size(11)
	action:set_min_size(Vector2.new(30, 28))
	for _, st in ipairs(W.BUTTON_STATES) do
		action:add_theme_stylebox_override(
			st,
			T.flat(if st == "normal" then T.FILL else T.FILL_2, 7, T.LINE, 1, 6.0, 4.0)
		)
	end
	action.pressed:Connect(function()
		self:_on_action()
	end)
	self.action = action
	h:add_child(action)
	self.gui_input:Connect(function(e)
		if e.kind == "button" and e.pressed and e.button == 1 then
			-- Roblox also reports presses on the action button to the row: that one is the button's
			local r = self.action:get_global_rect()
			local p = e.global_position
			if p.X >= r.Min.X and p.X <= r.Max.X and p.Y >= r.Min.Y and p.Y <= r.Max.Y then
				return
			end
			self:_focus()
		end
	end)
	return self
end

function Row.set_attack(self, a: any, touch: boolean)
	local ctx = self.ctx
	local T = UITheme
	local s = ctx.state
	self.aid = a.aid
	local incoming = a.target == ctx:me()
	local other = if incoming then a.attacker else a.target
	self.focus_id = other
	self.focus_tile = a.anchor_tile
	-- Expansions into neutral land are routine: draw them quieter than real fronts.
	self:set_modulate_a(if not incoming and other == 0 then 0.72 else 1.0)
	if self.incoming ~= incoming then
		self.incoming = incoming
		self:add_theme_stylebox_override("panel", if incoming then self._bg_in else self._bg_out)
	end
	self.arrow:set_icon(if incoming then "target" else (if other ~= 0 then "attack" else "globe"))
	self.arrow:set_color(if incoming then T.RED else (if other ~= 0 then T.AMBER else T.GREEN))
	self.sw:set_visible(other ~= 0)
	if other ~= 0 then
		T.set_swatch_color(self.sw, s:owner_color(other))
	end
	-- a retreating attack says so and can't be recalled again
	local name = if other ~= 0 then s:owner_name(other) else "Expansion"
	self.name_l:set_text(if a.retreating then name .. " (retreating…)" else name)
	T.set_font_color(self.name_l, if incoming then Color3.new(1.0, 0.82, 0.84) else T.TEXT)
	self.troops_l:set_text(T.fmt_troops(a.troops))
	T.set_font_color(self.troops_l, if incoming then T.RED else T.TEXT)
	self.action:set_min_size(Vector2.new(if touch then 48 else 30, if touch then 44 else 26))
	self.action:set_icon(if incoming then "eye" else "retreat")
	self.action:set_text("")
	self.action:set_disabled(a.retreating == true and not incoming)
end

function Row._on_action(self)
	self.touched:Fire()
	if self.incoming then
		self:_focus()
	else
		self.retreat:Fire(self.aid)
	end
end

function Row._focus(self)
	self.touched:Fire()
	if self.focus_tile >= 0 then
		self.ctx:world_call("focus_tile", { self.focus_tile, -1.0, 0.8 })
	elseif self.focus_id ~= 0 then
		self.ctx:world_call("focus_owner", { self.focus_id })
	end
end

-- ---------------------------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------------------------

function AttacksPanel.new(c: any)
	local self = setmetatable({}, AttacksPanel.__mt)
	W.Control._init(self)
	local T = UITheme
	self.ctx = c
	self.retreat_requested = Signal.new()
	self.toggled = Signal.new()
	self._rows = {}
	self._accum = 0.0
	self._dirty = true
	--- Effective state (computed in refresh()).
	self.collapsed = false
	--- Player override: 0 = automatic, 1 = keep open, 2 = keep collapsed (reset when the list empties).
	self.manual = 0
	--- The phone build tray is open (the panel folds to its header so the tray never covers rows).
	self.tray_open = false
	self._bottom_limit = -1.0
	self._peek_msec = 0
	self._chip_key = ""
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self.panel = GlassPanel.new(10.0, 9.0, T.R_LG, true, 16)
	self:add_child(self.panel)
	local v = T.vbox(5)
	self.panel:add_child(v)
	local head = T.hbox(8)
	self._icon = T.icon_rect("attack", 13.0, T.AMBER)
	self._icon.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._icon)
	self._title = T.label("ATTACKS", 12, 800, T.TEXT, 2)
	head:add_child(self._title)
	local sp = W.Control.new()
	sp.size_flags_horizontal = W.EXPAND_FILL
	sp:set_mouse_filter(W.MOUSE_IGNORE)
	head:add_child(sp)
	self._count = T.label("", 11, 600, T.TEXT_3)
	T.fix_width(self._count, 90.0, W.ALIGN_RIGHT, false)
	head:add_child(self._count)
	self._chev = T.icon_rect("chevron", 12.0, T.TEXT_3)
	self._chev.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._chev)
	-- The whole header toggles the list (phones keep the globe clear with one tap).
	local hb = W.Button.new("", "GhostButton")
	hb:set_flat(true)
	for _, st in ipairs(W.BUTTON_STATES) do
		hb:add_theme_stylebox_override(st, T.empty_box())
	end
	hb:set_min_size(Vector2.new(0, 24))
	local hm = W.Margin.new()
	hm:set_mouse_filter(W.MOUSE_IGNORE)
	hm:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	hm:add_theme_constant_override("margin_left", 4)
	hm:add_theme_constant_override("margin_right", 4)
	hm:add_child(head)
	hb:add_child(hm)
	hb.pressed:Connect(function()
		self.manual = if self.collapsed then 1 else 2
		self._peek_msec = msec()
		self:refresh()
		self.toggled:Fire(self.collapsed)
	end)
	self._head_btn = hb
	v:add_child(hb)
	self._list = T.vbox(4)
	v:add_child(self._list)
	self._more = T.label("", 11, 600, T.TEXT_3)
	self._more.horizontal_alignment = W.ALIGN_CENTER
	v:add_child(self._more)
	self.panel:set_visible(false)
	return self
end

--- `bottom_limit`: the panel must end above this y (the command bar); rows that do not fit are
--- summarised as "+N more".
function AttacksPanel.apply_layout(self, top: number, bottom_limit: number?)
	local ctx = self.ctx
	self._bottom_limit = bottom_limit or -1.0
	local right = 12.0 + ctx.insets.z
	local p = self.panel
	p.anchor_left, p.anchor_right, p.anchor_top, p.anchor_bottom = 1.0, 1.0, 0.0, 0.0
	p.grow_horizontal = W.GROW_BEGIN
	p.grow_vertical = W.GROW_END
	p.offset_left = -right
	p.offset_right = -right
	p.offset_top = top
	p.offset_bottom = top
	self._head_btn:set_min_height(if ctx.touch then 44 else 24)
	self:_fit_chip()
	p:reset_size()
end

--- Keep the phone list open (e.g. after the player used a row).
function AttacksPanel.peek(self)
	self.manual = 1
	self._peek_msec = msec()
end

--- Phones: collapsed = a small chip exactly one touch target tall; open = the list panel.
function AttacksPanel._fit_chip(self)
	local ctx = self.ctx
	local T = UITheme
	local chip = ctx.compact and self.collapsed
	local key = string.format("%s|%s|%s", tostring(ctx.compact), tostring(chip), tostring(T.min_font_size))
	if key == self._chip_key then
		return
	end
	self._chip_key = key
	self._title:set_visible(not chip)
	self._list:set_visible(not chip)
	self.panel:set_min_size(Vector2.new(if chip then 0.0 else (if ctx.compact then 250.0 else 300.0), 0))
	if ctx.compact then
		if chip then
			self.panel:set_padding(6.0, 0.0, 4.0, 0.0)
		else
			self.panel:set_padding(10.0, 2.0, 10.0, 8.0)
		end
	else
		self.panel:set_padding(10.0, 9.0, 10.0, 9.0)
	end
	T.fix_width(self._count, 90.0, W.ALIGN_RIGHT, false)
	self._count:set_font_size(if chip then 12 else 11)
	self:_fit_chip_width()
end

--- Chip: as narrow as its count ("3", "3 · 1 in"); the header button carries that width
--- (margins 4 + icon + gap + count + gap + chevron + margins 4, and a full 44 px at least).
function AttacksPanel._fit_chip_width(self)
	local ctx = self.ctx
	if not (ctx.compact and self.collapsed) then
		self._head_btn:set_min_width(0.0)
		return
	end
	local cw = UITheme.text_width(if self._count.text ~= "" then self._count.text else "8", 12, 700) + 2.0
	self._count:set_min_width(cw)
	self._head_btn:set_min_width(math.max(44.0, 4.0 + 13.0 + 8.0 + cw + 8.0 + 12.0 + 4.0))
end

function AttacksPanel.bottom_edge(self): number
	if self.panel.visible then
		return self.panel:get_rect().Max.Y
	end
	return -1.0
end

function AttacksPanel.mark_dirty(self)
	self._dirty = true
end

--- Attacks involving the local player, incoming first, then by committed troops.
function AttacksPanel.involved(self): { any }
	local out = {}
	local ctx = self.ctx
	local s = ctx.state
	local me = ctx:me()
	if s == nil or me == 0 then
		return out
	end
	for _, a in pairs(s.attacks) do
		if a.attacker == me or a.target == me then
			table.insert(out, a)
		end
	end
	table.sort(out, function(p, q)
		local pi, qi = p.target == me, q.target == me
		if pi ~= qi then
			return pi
		end
		local pe, qe = p.target == 0, q.target == 0
		if pe ~= qe then
			return qe
		end
		if p.troops ~= q.troops then
			return p.troops > q.troops
		end
		return p.aid < q.aid
	end)
	return out
end

--- Phones fold the panel to its header while the build tray is open, and while only expansions
--- into neutral land are running (those are routine, not wars); the player can override by tapping.
function AttacksPanel._want_collapsed(self, list: { any }): boolean
	local ctx = self.ctx
	if #list == 0 then
		self.manual = 0
		return false
	end
	if self.tray_open and ctx.compact then
		return true
	end
	if ctx.compact then
		-- A peek: open only after a tap, and only until the player leaves it alone for a while.
		if self.manual == 1 and msec() - self._peek_msec < AttacksPanel.PEEK_SECONDS * 1000.0 then
			return false
		end
		self.manual = 0
		return true
	end
	if self.manual ~= 0 then
		return self.manual == 2
	end
	return false
end

--- Troops currently committed to our outgoing attacks.
function AttacksPanel.committed(self): number
	local n = 0
	for _, a in ipairs(self:involved()) do
		if a.attacker == self.ctx:me() then
			n += a.troops
		end
	end
	return n
end

function AttacksPanel.refresh(self)
	local ctx = self.ctx
	local T = UITheme
	self._dirty = false
	local list = self:involved()
	local was = self.panel.visible
	self.panel:set_visible(#list > 0 and ctx:alive_player())
	if not self.panel.visible then
		return
	end
	local max_rows = if ctx.compact then AttacksPanel.MAX_ROWS_PHONE else AttacksPanel.MAX_ROWS_DESKTOP
	if self._bottom_limit > 0 then
		local row_h = if ctx.touch then 48.0 else 30.0
		local head_h = self._head_btn.custom_minimum_size.Y + 24.0
		local room = self._bottom_limit - self.panel.offset_top - head_h
		max_rows = math.clamp(math.floor(room / row_h), 0, max_rows)
	end
	-- Short lists are always shown in full; "+N more" only summarises a real overflow.
	max_rows = math.max(max_rows, math.min(AttacksPanel.ALWAYS_ROWS, #list))
	if #list == max_rows + 1 then
		max_rows += 1 -- "+1 more" would take a row anyway
	end
	local was_collapsed = self.collapsed
	self.collapsed = self:_want_collapsed(list)
	if self.collapsed ~= was_collapsed or not was then
		self:_fit_chip()
	end
	local shown = if self.collapsed then 0 else math.min(max_rows, #list)
	self._chev:set_rotation(if self.collapsed then -math.pi * 0.5 else 0.0)
	while #self._rows < shown do
		local r = Row.new(ctx)
		r.retreat:Connect(function(aid: number)
			self.retreat_requested:Fire(aid)
		end)
		r.touched:Connect(function()
			self._peek_msec = msec()
		end)
		table.insert(self._rows, r)
		self._list:add_child(r)
	end
	for i, r in ipairs(self._rows) do
		r:set_visible(i <= shown)
		if i <= shown then
			r:set_attack(list[i], ctx.touch)
		end
	end
	local inc = 0
	for _, a in ipairs(list) do
		if a.target == ctx:me() then
			inc += 1
		end
	end
	local outc = #list - inc
	local parts = {}
	if outc > 0 then
		table.insert(parts, string.format("%d out", outc))
	end
	if inc > 0 then
		table.insert(parts, string.format("%d in", inc))
	end
	local ctext = table.concat(parts, "  ·  ")
	if ctx.compact and self.collapsed then
		ctext = if inc == 0 then tostring(#list) else string.format("%d · %d in", #list, inc)
	end
	self._count:set_text(ctext)
	T.set_font_color(
		self._count,
		if inc > 0 then T.RED else (if self.collapsed and ctx.compact then T.TEXT else T.TEXT_3)
	)
	if ctx.compact and self.collapsed and self._count.text ~= self._count:get_meta("fit", "") then
		self._count:set_meta("fit", self._count.text)
		self:_fit_chip_width()
	end
	self._icon:set_icon(if inc > 0 then "target" else "attack")
	self._icon:set_color(if inc > 0 then T.RED else T.AMBER)
	self._more:set_visible(#list > shown and not self.collapsed)
	self._more:set_text(string.format("+%d more", #list - shown))
	self.panel:reset_size()
	if not was then
		W.pop_in(self.panel, 0.0, 0.96, 0.3)
	end
end

--- Per frame (GDScript _process).
function AttacksPanel.update(self, delta: number)
	self._accum += delta
	if (self._dirty or self._accum >= 0.5) and self:is_visible_in_tree() then
		self._accum = 0.0
		self:refresh()
	end
end

return AttacksPanel
