--!nonstrict
-- Port of scripts/ui/alert_banner.gd (UIAlertBanner)
-- Red pulsing "INCOMING NUKE" banner shown while nukes aimed at your land are in flight; turns
-- green ("INTERCEPTED!") for a moment when a SAM shoots the last one down.
--
-- Members: panel. Methods: apply_layout(y, right_x = -1), clear(), is_green(), track(uid) -> bool,
-- resolve(uid, intercepted); per frame update(dt).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")

local AlertBanner = W.class(W.Control)

local RED_TITLE = Color3.new(1.0, 0.55, 0.58)
local RED_TINT = UITheme.rgba(0.26, 0.03, 0.07, 0.9)

function AlertBanner.new(c: any)
	local self = setmetatable({}, AlertBanner.__mt)
	W.Control._init(self)
	local T = UITheme
	self.ctx = c
	self._incoming = {} -- uid -> true
	self._t = 0.0
	--- Seconds left of the green "intercepted" state (0 = normal).
	self._green = 0.0
	--- The incoming set changed since the text was written (update() writes it).
	self._stale = false
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self.panel = GlassPanel.new(18.0, 10.0, 999, true, 24)
	self.panel:set_mouse_filter(W.MOUSE_IGNORE)
	self.panel:set_tint(RED_TINT)
	self.panel:set_border(T.c(T.RED, 0.8))
	self:add_child(self.panel)
	local row = T.hbox(12)
	self.panel:add_child(row)
	self._disc = W.Panel.new()
	self._disc:set_mouse_filter(W.MOUSE_IGNORE)
	self._disc:set_min_size(Vector2.new(34, 34))
	self._disc:add_theme_stylebox_override("panel", T.flat(T.c(T.RED, 0.25), 17, T.RED, 1))
	local ic = T.icon_rect("atom", 18.0, Color3.new(1.0, 0.85, 0.85))
	self._disc_icon = ic
	ic.size_flags_horizontal = W.SHRINK_CENTER
	ic.size_flags_vertical = W.SHRINK_CENTER
	self._disc:add_child(ic)
	row:add_child(self._disc)
	local v = T.vbox(0)
	v.size_flags_vertical = W.SHRINK_CENTER
	self._title = T.label("INCOMING NUKE", 15, 800, RED_TITLE, 3)
	v:add_child(self._title)
	self._detail = T.label("", 12, 500, Color3.new(1.0, 0.88, 0.88))
	v:add_child(self._detail)
	row:add_child(v)
	self:set_visible(false)
	return self
end

--- Centred under the status pill on larger screens; right-aligned under the leaderboard pill on phones.
function AlertBanner.apply_layout(self, y: number, right_x: number?)
	local ctx = self.ctx
	local T = UITheme
	local rx = right_x or -1.0
	local p = self.panel
	p:set_mouse_filter(if ctx.touch then W.MOUSE_STOP else W.MOUSE_IGNORE)
	-- Fixed width: long nation names ellipsize instead of stretching the banner.
	local w = if ctx.compact then 330.0 else 380.0
	T.fix_width(self._detail, w, W.ALIGN_LEFT, false)
	T.fix_width(self._title, w, W.ALIGN_LEFT, false)
	p.anchor_top = 0.0
	p.anchor_bottom = 0.0
	p.grow_vertical = W.GROW_END
	if rx >= 0 then
		p.anchor_left = 1.0
		p.anchor_right = 1.0
		p.grow_horizontal = W.GROW_BEGIN
		p.offset_left = -rx
		p.offset_right = -rx
	else
		p.anchor_left = 0.5
		p.anchor_right = 0.5
		p.grow_horizontal = W.GROW_BOTH
		local dx, yy = ctx:place_top(p:get_combined_minimum_size().X, y)
		p.offset_left = dx
		p.offset_right = dx
		y = yy
	end
	p.offset_top = y
	p.offset_bottom = y
	p:reset_size()
end

function AlertBanner.clear(self)
	table.clear(self._incoming)
	self._green = 0.0
	self:set_visible(false)
	self:_set_red()
end

function AlertBanner.is_green(self): boolean
	return self._green > 0
end

function AlertBanner._show_green(self, last: boolean)
	local T = UITheme
	self._green = 1.6
	self:set_visible(true)
	self:set_modulate_a(1.0)
	self._title:set_text("INTERCEPTED!")
	self._title:set_color(Color3.new(0.6, 1.0, 0.72))
	self._detail:set_text("Shot down by a SAM" .. (if last then "" else " · more incoming"))
	self.panel:set_tint(T.rgba(0.03, 0.2, 0.09, 0.9))
	self.panel:set_border(T.c(T.GREEN, 0.9))
	self._disc:add_theme_stylebox_override("panel", T.flat(T.c(T.GREEN, 0.25), 17, T.GREEN, 1))
	self._disc_icon:set_icon("sam")
	self._disc_icon:set_color(Color3.new(0.85, 1.0, 0.9))
	self.panel:reset_size()
end

function AlertBanner._set_red(self)
	local T = UITheme
	self._title:set_color(RED_TITLE)
	self.panel:set_tint(RED_TINT)
	self.panel:set_border(T.c(T.RED, 0.8))
	self._disc:add_theme_stylebox_override("panel", T.flat(T.c(T.RED, 0.25), 17, T.RED, 1))
	self._disc_icon:set_icon("atom")
	self._disc_icon:set_color(Color3.new(1.0, 0.85, 0.85))
end

--- Returns true when this nuke is newly aimed at the local player, and true again when it is the
--- one that brings the banner up.
--- (The text is written once a frame, in update(): a MIRV's 350 warheads are tracked in one tick and
--- land within seconds, and each used to rewrite both lines and size the panel again.)
function AlertBanner.track(self, uid: number): (boolean, boolean)
	local ctx = self.ctx
	local s = ctx.state
	if s == nil or s.nukes[uid] == nil or ctx:me() == 0 then
		return false, false
	end
	local n = s.nukes[uid]
	if n.owner == ctx:me() or s:tile_owner(n.to_tile) ~= ctx:me() then
		return false, false
	end
	local first = next(self._incoming) == nil
	self._incoming[uid] = true
	if first then
		self:set_visible(true)
		W.pop_in(self.panel, 0.0, 1.15, 0.35)
		self:_refresh()
	else
		self._stale = true
	end
	return true, first
end

--- `intercepted`: a SAM shot it down (the banner flashes green before it goes).
function AlertBanner.resolve(self, uid: number, intercepted: boolean?)
	if not self._incoming[uid] then
		return
	end
	self._incoming[uid] = nil
	if intercepted then
		self:_show_green(next(self._incoming) == nil)
		return
	end
	if next(self._incoming) == nil then
		local t = self:create_tween()
		t:tween_property(self, "modulate:a", 0.0, 0.4)
		t:tween_callback(function()
			if next(self._incoming) == nil then
				self:set_visible(false)
			end
			self:set_modulate_a(1.0)
		end)
	else
		self._stale = true
	end
end

function AlertBanner._refresh(self)
	self._stale = false
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return
	end
	local Defs = UITheme.core("Defs")
	local soonest = 1e9
	local kind = -1
	local from = 0
	local count = 0
	local gone = {}
	for uid in pairs(self._incoming) do
		local n = s.nukes[uid]
		if n == nil then
			table.insert(gone, uid)
		else
			count += 1
			local left = (n.launch_tick + n.flight_ticks) - ctx:render_tick()
			if left < soonest then
				soonest = left
				kind = n.kind
				from = n.owner
			end
		end
	end
	for _, uid in ipairs(gone) do
		self._incoming[uid] = nil
	end
	if count == 0 then
		return
	end
	local secs = math.max(0, math.ceil(soonest / Defs.TICK_RATE))
	local what = (if kind >= 0 then Defs.NUKE_TITLES[kind] else nil) or "Nuke"
	if count > 1 then
		self._title:set_text(string.format("INCOMING NUKES ×%d", count))
		self._detail:set_text(string.format("First impact in %ds · from %s", secs, s:owner_name(from)))
	else
		self._title:set_text("INCOMING NUKE")
		self._detail:set_text(string.format("%s from %s · impact in %ds", what, s:owner_name(from), secs))
	end
	self.panel:reset_size()
end

--- Per frame (GDScript _process).
function AlertBanner.update(self, delta: number)
	if not self.visible then
		return
	end
	local T = UITheme
	if self._green > 0 then
		self._green -= delta
		if self._green <= 0 then
			self:_set_red()
			if next(self._incoming) == nil then
				local t = self:create_tween()
				t:tween_property(self, "modulate:a", 0.0, 0.35)
				t:tween_callback(function()
					if next(self._incoming) == nil and self._green <= 0 then
						self:set_visible(false)
					end
					self:set_modulate_a(1.0)
				end)
			else
				self:_refresh()
			end
		end
		return
	end
	local prev = self._t
	self._t += delta
	local p = 0.5 + 0.5 * math.sin(self._t * 7.0)
	self.panel:set_border(T.c(T.RED, 0.45 + 0.5 * p))
	self._disc:set_modulate_a(0.75 + 0.25 * p)
	if self._stale or math.floor(self._t * 4.0) ~= math.floor(prev * 4.0) then
		self:_refresh()
	end
end

return AlertBanner
