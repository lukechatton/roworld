--!nonstrict
-- Port of scripts/ui/top_status.gd (UITopStatus)
-- Top-centre status pill: match clock (and time limit), phase, and world-control progress
-- towards the 80 % victory share for you and the current leader. Phones get a one-line mini pill
-- (clock · rank · share, a tiny Protected chip) whose tap opens the leaderboard.
--
-- Signals: tapped(). Members: panel, rank_provider (() -> number, set by UIRoot).
-- Methods: apply_layout(), bottom_edge(), on_phase(phase, ticks_left), on_bind(), refresh(),
-- grace_left(); per frame update(dt).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local FillBar = require("./FillBar")
local Signal = UITheme.core("Signal")

local TopStatus = W.class(W.Control)

local function spacer()
	local sp = W.Control.new()
	sp.size_flags_horizontal = W.EXPAND_FILL
	sp:set_mouse_filter(W.MOUSE_IGNORE)
	return sp
end

local function on_release(node, fn)
	node.gui_input:Connect(function(e)
		if e.kind == "button" and e.button == 1 and not e.pressed then
			fn()
		end
	end)
end

function TopStatus.new(c: any)
	local self = setmetatable({}, TopStatus.__mt)
	W.Control._init(self)
	local T = UITheme
	local Rules = T.core("Rules")
	self.ctx = c
	self.tapped = Signal.new()
	self._phase_end_tick = -1.0
	--- () -> number: my leaderboard rank (phones show it here instead of a separate pill).
	self.rank_provider = nil
	self._accum = 0.0
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self.panel = GlassPanel.new(18.0, 10.0, T.R_LG, true, 18)
	self.panel:set_mouse_filter(W.MOUSE_IGNORE)
	on_release(self.panel, function()
		self.tapped:Fire()
	end)
	self:add_child(self.panel)
	local row = T.hbox(16)
	self._full = row
	self.panel:add_child(row)

	local tb = T.vbox(0)
	tb.size_flags_vertical = W.SHRINK_CENTER
	self._phase = T.caption("Match time")
	tb:add_child(self._phase)
	local tv = T.hbox(4)
	self._clock = T.label("0:00", 20, 700)
	self._clock.rolling = true
	tv:add_child(self._clock)
	self._limit = T.label("", 12, 600, T.TEXT_3)
	self._limit.size_flags_vertical = W.SHRINK_END
	tv:add_child(self._limit)
	tb:add_child(tv)
	self._grace_row = T.hbox(4)
	local gic = T.icon_rect("defense", 11.0, T.GREEN)
	gic.size_flags_vertical = W.SHRINK_CENTER
	self._grace_row:add_child(gic)
	self._grace = T.label("", 11, 700, T.GREEN, 1)
	self._grace.rolling = true
	self._grace_row:add_child(self._grace)
	self._grace_row:set_visible(false)
	tb:add_child(self._grace_row)
	tb:move_child(self._grace_row, 0)
	tb:set_min_size(Vector2.new(88, 0))
	row:add_child(tb)
	row:add_child(T.vdivider(38.0))

	local sb = T.vbox(5)
	sb.size_flags_vertical = W.SHRINK_CENTER
	local head = T.hbox(6)
	self._head = head
	head:add_child(T.icon_rect("globe", 12.0, T.TEXT_3))
	head:add_child(T.caption("World control"))
	head:add_child(spacer())
	self._goal = T.caption("Goal 80%", 11, T.GOLD)
	head:add_child(self._goal)
	sb:add_child(head)
	self._bar = FillBar.new(7.0, T.AMBER)
	self._bar.goal = Rules.WIN_SHARE
	self._bar:set_min_size(Vector2.new(280, 12))
	sb:add_child(self._bar)
	local who = T.hbox(6)
	self._you_sw = T.swatch(T.AMBER, 9.0, 2)
	who:add_child(self._you_sw)
	self._you = T.label("You 0.0%", 12, 600, T.TEXT)
	who:add_child(self._you)
	who:add_child(spacer())
	self._lead_box = T.hbox(6)
	local crown = T.icon_rect("crown", 12.0, T.GOLD)
	crown.size_flags_vertical = W.SHRINK_CENTER
	self._lead_box:add_child(crown)
	self._lead_sw = T.swatch(T.TEXT, 9.0, 2)
	self._lead_box:add_child(self._lead_sw)
	self._lead = T.label("", 12, 600, T.TEXT_2)
	self._lead_box:add_child(self._lead)
	who:add_child(self._lead_box)
	sb:add_child(who)
	row:add_child(sb)
	self:_build_mini()
	return self
end

function TopStatus._build_mini(self)
	local T = UITheme
	self._mini = T.hbox(7)
	self._mini:set_visible(false)
	self._m_grace = W.Panel.new()
	self._m_grace:set_mouse_filter(W.MOUSE_IGNORE)
	self._m_grace.size_flags_vertical = W.SHRINK_CENTER
	self._m_grace:add_theme_stylebox_override("panel", T.flat(T.c(T.GREEN, 0.14), 999, T.c(T.GREEN, 0.45), 1, 6.0, 1.0))
	local gh = T.hbox(3)
	local gi = T.icon_rect("defense", 11.0, T.GREEN)
	gi.size_flags_vertical = W.SHRINK_CENTER
	gh:add_child(gi)
	self._m_grace_l = T.label("", 12, 700, T.GREEN)
	self._m_grace_l.rolling = true
	gh:add_child(self._m_grace_l)
	self._m_grace:add_child(gh)
	self._m_grace:set_visible(false)
	self._mini:add_child(self._m_grace)
	self._m_clock = T.label("0:00", 14, 700)
	self._m_clock.rolling = true
	self._m_clock.size_flags_vertical = W.SHRINK_CENTER
	self._mini:add_child(self._m_clock)
	self._m_sw = T.swatch(T.AMBER, 8.0, 2)
	self._m_sw.size_flags_vertical = W.SHRINK_CENTER
	self._mini:add_child(self._m_sw)
	self._m_you = T.label("", 13, 600)
	self._m_you.size_flags_vertical = W.SHRINK_CENTER
	self._mini:add_child(self._m_you)
	self._m_chev = T.icon_rect("leaderboard", 12.0, T.TEXT_3)
	self._m_chev.size_flags_vertical = W.SHRINK_CENTER
	self._mini:add_child(self._m_chev)
	self.panel:add_child(self._mini)
	self._hit = W.Control.new()
	self._hit.name = "StatusHit"
	self._hit:set_mouse_filter(W.MOUSE_IGNORE)
	on_release(self._hit, function()
		self.tapped:Fire()
	end)
	self:add_child(self._hit)
	self.panel.item_rect_changed:Connect(function()
		self:_fit_hit()
	end)
	self.panel.visibility_changed:Connect(function()
		self:_fit_hit()
	end)
end

--- The mini pill is ~30 px tall; its tap area is a full 44 px.
function TopStatus._fit_hit(self)
	if self._hit == nil then
		return
	end
	local ctx = self.ctx
	local on = ctx.compact and ctx.touch and self.panel.visible
	self._hit:set_mouse_filter(if on then W.MOUSE_STOP else W.MOUSE_IGNORE)
	self._hit:set_visible(on)
	if on then
		local p, s = self.panel.position, self.panel.size
		local pad = math.max(0.0, (44.0 - s.Y) * 0.5)
		self._hit:set_anchors(0, 0, 0, 0)
		self._hit:set_offsets(p.X - 4.0, p.Y - pad, p.X + s.X + 4.0, p.Y + s.Y + pad)
	end
end

function TopStatus.apply_layout(self)
	local ctx = self.ctx
	local T = UITheme
	local p = self.panel
	local top = 12.0 + ctx.insets.y
	-- Phones drop the "WORLD CONTROL · GOAL 80%" header: the bar and its gold goal line say it.
	self._head:set_visible(not ctx.compact)
	self._full:set_visible(not ctx.compact)
	self._mini:set_visible(ctx.compact)
	-- Very narrow phones drop the leaderboard hint icon (the pill still opens the board).
	self._m_chev:set_visible(ctx.vp.X >= 800.0)
	-- On touch the pill swallows taps (and on phones opens the leaderboard).
	p:set_mouse_filter(if ctx.touch then W.MOUSE_STOP else W.MOUSE_IGNORE)
	if ctx.compact then
		-- Phones: tuck into the top-right corner, clear of the top-left bar.
		p.anchor_left = 1.0
		p.anchor_right = 1.0
		p.grow_horizontal = W.GROW_BEGIN
		p.offset_left = -(8.0 + ctx.insets.z)
		p.offset_right = -(8.0 + ctx.insets.z)
		top = 8.0 + ctx.insets.y
		self._bar:set_min_size(Vector2.new(200, 10))
		self._clock:set_font_size(16)
		p:set_padding(12.0, 5.0, 10.0, 5.0)
	else
		p.anchor_left = 0.5
		p.anchor_right = 0.5
		p.grow_horizontal = W.GROW_BOTH
		p.offset_left = 0.0
		p.offset_right = 0.0
		self._bar:set_min_size(Vector2.new(if ctx.vp.X >= 1200.0 then 340 else 260, 12))
		self._clock:set_font_size(20)
		p:set_padding(18.0, 10.0, 18.0, 10.0)
	end
	self:_fix_widths()
	p.anchor_top = 0.0
	p.anchor_bottom = 0.0
	p.grow_vertical = W.GROW_END
	local w = p:get_combined_minimum_size().X
	if ctx.compact then
		-- Right-aligned; drop below the top-left bar row when the phone is too narrow for both.
		if ctx.vp.X - ctx.insets.z - 8.0 - w < ctx.reserved_top_left.Max.X + 8.0 then
			top = ctx.reserved_top_left.Max.Y + 4.0
		end
	else
		local dx, y = ctx:place_top(w, top)
		p.offset_left = dx
		p.offset_right = dx
		top = y
	end
	p.offset_top = top
	p.offset_bottom = top
	p:reset_size()
	self:_fit_hit()
	local _ = T
end

--- Fixed boxes for every changing text (tabular digits) so the pill never resizes or jitters.
function TopStatus._fix_widths(self)
	local ctx = self.ctx
	local T = UITheme
	local small = math.max(11, T.min_font_size)
	local cs = if ctx.compact then 16 else 20
	local ws = math.max(12, T.min_font_size)
	local w_block =
		math.max(T.text_width("SPAWN PHASE", small, 700) + 12.0, T.text_width("PROTECTED 8:88", small, 700) + 20.0)
	T.fix_width(self._phase, w_block, W.ALIGN_LEFT, false)
	T.fix_width(self._grace, w_block - 16.0)
	local w_clock = T.text_width("8:88:88", cs, 700) + 2.0
	T.fix_width(self._clock, w_clock)
	T.fix_width(self._limit, math.max(w_block - w_clock - 4.0, T.text_width("/ 88:88", ws, 600) + 2.0))
	self._phase.parent:set_min_size(Vector2.new(w_block, 0))
	self._grace_row:set_min_size(Vector2.new(w_block, self._phase:get_combined_minimum_size().Y))
	local bar_w = self._bar.custom_minimum_size.X
	local w_you = T.text_width("You lead · 88.88%", ws, 600) + 2.0
	T.fix_width(self._you, w_you, W.ALIGN_LEFT, false)
	local lead_w = math.max(40.0, bar_w - w_you - 12.0 - 9.0 - 12.0 - 18.0)
	T.fix_width(self._lead, lead_w, W.ALIGN_LEFT, false)
	-- The Protected chip and the clock take turns in one slot of fixed width (the pill never resizes).
	local slot = math.max(
		T.text_width("88:88", 14, 700) + 2.0,
		6.0 + 11.0 + 3.0 + T.text_width("8:88", 12, 700) + 2.0 + 6.0 + 2.0
	)
	T.fix_width(self._m_clock, slot, W.ALIGN_LEFT)
	self._m_grace:set_min_width(slot)
	T.fix_width(self._m_you, T.text_width("#888 · 88.88%", 13, 600) + 2.0, W.ALIGN_LEFT)
	T.fix_width(self._m_grace_l, T.text_width("8:88", 12, 700) + 2.0, W.ALIGN_LEFT)
end

function TopStatus.bottom_edge(self): number
	local r = self.panel:get_rect()
	return r.Max.Y
end

--- Call on bind and on every phase change.
function TopStatus.on_phase(self, phase: number, ticks_left: number)
	local s = self.ctx.state
	if s == nil then
		return
	end
	local Defs = UITheme.core("Defs")
	self._phase_end_tick = if ticks_left > 0 and phase ~= Defs.PHASE_OVER then s.tick + ticks_left else -1.0
	-- MATCH OVER: the clock stops at the final time (the Sim keeps ticking for the spectators;
	-- review P2-5, the original kept counting).
	if phase == Defs.PHASE_OVER then
		if self._over_secs == nil then
			self._over_secs = self.ctx:match_seconds()
		end
	else
		self._over_secs = nil
	end
	self:refresh()
end

function TopStatus.on_bind(self)
	self._phase_end_tick = -1.0
	self._over_secs = nil
	local s = self.ctx.state
	if s == nil then
		return
	end
	self:on_phase(s.phase, s.phase_ticks_left)
end

function TopStatus.refresh(self)
	local ctx = self.ctx
	local T = UITheme
	local Defs = T.core("Defs")
	local s = ctx.state
	if s == nil then
		return
	end
	local now = ctx:render_tick()
	local tr = Defs.TICK_RATE
	if s.phase == Defs.PHASE_SPAWN then
		self._phase:set_text("SPAWN PHASE")
		if self._phase_end_tick > 0 then
			self._clock:set_text(T.fmt_time(math.ceil((self._phase_end_tick - now) / tr)))
		else
			self._clock:set_text("--:--")
		end
		self._limit:set_text("")
	elseif s.phase == Defs.PHASE_PLAYING then
		local elapsed = ctx:match_seconds()
		if s.time_limit_ticks > 0 then
			-- time_limit_ticks is the absolute tick at which the match ends.
			local left = math.max(0, (s.time_limit_ticks - now) / tr)
			self._phase:set_text("TIME LEFT")
			self._clock:set_text(T.fmt_time(math.ceil(left)))
			T.set_font_color(self._clock, if left < 120 then T.RED else T.TEXT)
			local total = if ctx.play_start_tick >= 0
				then (s.time_limit_ticks - ctx.play_start_tick) / tr
				else ctx:match_limit_s()
			self._limit:set_text("/ " .. T.fmt_time(math.floor(total + 0.5)))
		else
			self._phase:set_text("MATCH TIME")
			self._clock:set_text(T.fmt_time(elapsed))
			self._limit:set_text("")
		end
	else
		self._phase:set_text("MATCH OVER")
		self._limit:set_text("")
		if self._over_secs == nil then
			self._over_secs = ctx:match_seconds()
		end
		self._clock:set_text(T.fmt_time(self._over_secs))
	end
	-- While protected the one timer is the protection's countdown (the match clock counting up beside
	-- it read badly, 2026-09-28); the match clock comes back when protection ends.
	local grace = self:grace_left()
	if grace > 0 then
		self._clock:set_text(T.fmt_time(math.ceil(grace)))
		T.set_font_color(self._clock, T.GREEN)
		self._limit:set_text("")
	elseif s.phase == Defs.PHASE_PLAYING and s.time_limit_ticks <= 0 then
		T.set_font_color(self._clock, T.TEXT)
	end
	self:_refresh_grace()
	local ranking = s:ranking()
	local me = ctx:me()
	local my_share = if me ~= 0 then s:land_share(me) else 0.0
	local mo = ctx:my()
	local mcol = if mo ~= nil then T.owner_ui_color(mo.color) else T.AMBER
	self._you_sw:set_visible(me ~= 0)
	T.set_swatch_color(self._you_sw, mcol)
	self._you:set_text(if me ~= 0 then ("You " .. T.fmt_pct(my_share)) else "Spectating")
	if ctx.compact and me ~= 0 and self.rank_provider ~= nil then
		local rk = tonumber(self.rank_provider()) or 0
		if rk > 0 then
			self._you:set_text(string.format("#%d · %s", rk, T.fmt_pct(my_share)))
		end
	end
	self._bar.fill_color = mcol
	self._bar:set_target(if me ~= 0 then ctx:win_share(me) else 0.0)
	table.clear(self._bar.markers)
	if #ranking > 0 then
		local leader = ranking[1]
		local ls = s:land_share(leader.id)
		self._lead_box:set_visible(leader.id ~= me)
		T.set_swatch_color(self._lead_sw, leader.color)
		self._lead:set_text(if ctx.compact then T.fmt_pct(ls) else string.format("%s %s", leader.name, T.fmt_pct(ls)))
		if leader.id ~= me then
			table.insert(self._bar.markers, { v = ctx:win_share(leader.id), color = T.owner_ui_color(leader.color) })
		else
			self._you:set_text((if ctx.compact then "#1 · " else "You lead · ") .. T.fmt_pct(my_share))
		end
	else
		self._lead_box:set_visible(false)
	end
	-- a team game: the team's land together, and the team ahead
	if type(s.is_team_game) == "function" and s:is_team_game() then
		self:_refresh_teams(me)
	end
	self._bar:queue_redraw()
	if ctx.compact then
		self._m_clock:set_text(self._clock.text)
		if #self._m_clock.text > 5 and self._m_clock.custom_minimum_size.X < T.text_width("8:88:88", 14, 700) then
			T.fix_width(self._m_clock, T.text_width("8:88:88", 14, 700) + 2.0, W.ALIGN_LEFT)
			self._m_grace:set_min_width(self._m_clock.custom_minimum_size.X)
		end
		T.set_font_color(self._m_clock, self._clock.color)
		T.set_swatch_color(self._m_sw, mcol)
		self._m_sw:set_visible(me ~= 0)
		local yt = string.gsub(self._you.text, "You lead · ", "#1 · ")
		yt = string.gsub(yt, "You ", "")
		self._m_you:set_text(yt)
		-- While protected, the shield countdown takes the clock's place (the match is young).
		local gl = self:grace_left()
		self._m_grace:set_visible(gl > 0)
		self._m_clock:set_visible(gl <= 0)
		if gl > 0 then
			self._m_grace_l:set_text(T.fmt_time(math.ceil(gl)))
		end
	end
end

--- A team game (Core/Teams): the bar is the player's team's land together (it wins at the same share),
--- the lead box the team ahead.
function TopStatus._refresh_teams(self, me: number)
	local ctx = self.ctx
	local T = UITheme
	local s = ctx.state
	local mine = if me ~= 0 then s:team_of(me) else 0
	local teams = s:team_ranking()
	local share = if mine ~= 0 then ctx:team_share(mine) else 0.0
	local mcol = if mine ~= 0 then T.owner_ui_color(s:team_color(mine)) else T.AMBER
	T.set_swatch_color(self._you_sw, mcol)
	self._bar.fill_color = mcol
	self._bar:set_target(share)
	table.clear(self._bar.markers)
	local rank = 0
	for i, r in teams do
		if r.team == mine then
			rank = i
		end
	end
	local Defs = T.core("Defs")
	if mine ~= 0 and s.phase == Defs.PHASE_SPAWN then
		-- before the land counts: which team you're on ("Your team:" in the spawn phase)
		self._you:set_text(if ctx.compact then ctx:team_label(mine) else "Your team: " .. ctx:team_label(mine))
		self._lead_box:set_visible(false)
		return
	end
	if mine ~= 0 then
		self._you:set_text(
			if ctx.compact
				then string.format("#%d · %s", rank, T.fmt_pct(share))
				elseif rank == 1 then "Your team leads · " .. T.fmt_pct(share)
				else string.format("%s %s", ctx:team_label(mine), T.fmt_pct(share))
		)
	end
	local top = teams[1]
	if top ~= nil and top.team ~= mine then
		local ts = ctx:team_share(top.team)
		local tcol = s:team_color(top.team)
		self._lead_box:set_visible(true)
		T.set_swatch_color(self._lead_sw, tcol)
		self._lead:set_text(if ctx.compact then T.fmt_pct(ts) else string.format("%s %s", ctx:team_label(top.team), T.fmt_pct(ts)))
		table.insert(self._bar.markers, { v = ts, color = T.owner_ui_color(tcol) })
	else
		self._lead_box:set_visible(false)
	end
end

--- Early peace: nations will not declare war on a commander during the grace window
--- (Rules.human_grace_ticks(difficulty), counted from the start of play).
function TopStatus._refresh_grace(self)
	local left = self:grace_left()
	local show = left > 0
	self._grace_row:set_visible(show)
	self._phase:set_visible(not show)
	if show then
		self._grace:set_text("PROTECTED")
	end
end

function TopStatus.grace_left(self): number
	local ctx = self.ctx
	local Defs = UITheme.core("Defs")
	local s = ctx.state
	if s == nil or s.phase ~= Defs.PHASE_PLAYING or not ctx:alive_player() or ctx.play_start_tick < 0 then
		return 0.0
	end
	-- (a public match: Easy nations, and bot players no harsher towards a player than
	-- Rules.SMART_VS_PLAYERS; it read 3:00 while the smart ones came for players at Medium's)
	local diff = tonumber(UITheme.core("Rules").SMART_VS_PLAYERS) or 0
	if ctx:mode() == 1 and ctx.session ~= nil then
		diff = tonumber(ctx.session.difficulty) or 1
	end
	local g = ctx:rules_call("human_grace_ticks", { diff })
	if type(g) ~= "number" then
		return 0.0
	end
	return (ctx.play_start_tick + g - ctx:render_tick()) / Defs.TICK_RATE
end

--- Per frame (GDScript _process).
function TopStatus.update(self, delta: number)
	self._accum += delta
	if self._accum >= 0.25 then
		self._accum = 0.0
		if self:is_visible_in_tree() then
			self:refresh()
		end
	end
end

return TopStatus
