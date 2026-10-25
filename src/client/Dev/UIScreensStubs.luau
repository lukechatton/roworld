--!nonstrict
-- ui-screens dev: minimal stand-ins for kit components that have not landed yet (Leaderboard,
-- EventFeed, AttacksPanel, AlertBanner). Same surface as the GDScript components so UIRoot runs;
-- they draw a plain glass panel so layouts can be checked. Only used by the UIScreens* harnesses.

local UI = script.Parent.Parent:WaitForChild("UI")
local UITheme = require(UI.UITheme)
local W = require(UI.Widgets)
local GlassPanel = require(UI.GlassPanel)
local Signal = UITheme.core("Signal")

local Stubs = {}

local function base(c)
	local self = W.Control.new()
	self.ctx = c
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	return self
end

local function glass(self, title: string)
	local p = GlassPanel.new(14, 10, UITheme.R_LG, true, 18)
	p:add_child(UITheme.label(title, 13, 800, UITheme.TEXT_3, 2))
	self:add_child(p)
	return p
end

-- ---------------------------------------------------------------------------------------------
Stubs.Leaderboard = {}
function Stubs.Leaderboard.new(c)
	local self = base(c)
	self.toggled = Signal.new()
	self.expanded = true
	self.panel = glass(self, "LEADERBOARD (stub)")
	self.panel:set_min_size(Vector2.new(300, 360))
	self._pill = UITheme.button("#1", "GlassButton", "leaderboard", 40)
	self._pill:set_visible(false)
	self:add_child(self._pill)
	function self.toggle(s)
		s.expanded = not s.expanded
		s.panel:set_visible(s.expanded)
		s._pill:set_visible(not s.expanded)
		s.toggled:Fire(s.expanded)
	end
	function self.set_open(s, on)
		if s.expanded ~= on then
			s:toggle()
		end
	end
	function self.apply_layout(s, top)
		for _, n in ipairs({ s.panel, s._pill }) do
			n:set_anchors(1, 0, 1, 0)
			n:set_grow(W.GROW_BEGIN, W.GROW_END)
			n:set_offsets(-12 - s.ctx.insets.z, top, -12 - s.ctx.insets.z, top)
			n:reset_size()
		end
	end
	function self.place_pill_left_of(_s, _r) end
	function self.bottom_edge(s)
		local n = if s.expanded then s.panel else s._pill
		return n:get_global_rect().Max.Y
	end
	function self.my_rank()
		return 1
	end
	function self.mark_dirty() end
	function self.refresh() end
	return self
end

-- ---------------------------------------------------------------------------------------------
Stubs.EventFeed = {}
function Stubs.EventFeed.new(c, top_mode)
	local self = base(c)
	self.top_mode = top_mode == true
	self._stack = UITheme.vbox(8)
	self:add_child(self._stack)
	self._cards = {}
	function self.apply_layout(s, bottom_y)
		local st = s._stack
		st:set_anchors(0, 0, 0, 0)
		st:set_grow(W.GROW_END, W.GROW_BEGIN)
		st:set_offsets(16 + s.ctx.insets.x, bottom_y, 16 + s.ctx.insets.x, bottom_y)
		st:reset_size()
	end
	function self.apply_layout_top(s, y)
		local st = s._stack
		st:set_anchors(0.5, 0, 0.5, 0)
		st:set_grow(W.GROW_BOTH, W.GROW_END)
		st:set_offsets(0, y, 0, y)
		st:reset_size()
	end
	function self.stack_rect(s)
		return s._stack:get_global_rect()
	end
	function self.clear(s)
		for _, ch in ipairs(s._stack:get_children()) do
			ch:queue_free()
		end
	end
	function self.toast(s, cat, text, icon, secs)
		local p = GlassPanel.new(12, 8, UITheme.R_MD, true, 14)
		p:set_accent(UITheme.msg_color(cat))
		local h = UITheme.hbox(10)
		local ic = UITheme.icon_rect(
			if icon ~= nil and icon ~= "" then icon else UITheme.msg_icon(cat),
			16,
			UITheme.msg_color(cat)
		)
		ic.size_flags_vertical = W.SHRINK_CENTER
		h:add_child(ic)
		h:add_child(UITheme.label(text, 13, 600, UITheme.TEXT))
		p:add_child(h)
		s._stack:add_child(p)
		W.timer(secs or 6.5, function()
			if not p._freed then
				p:queue_free()
			end
		end)
	end
	function self.alliance_request(s, from)
		local st = s.ctx.state
		s:toast(4, (if st then st:owner_name(from) else "?") .. " proposes an alliance", "alliance", 20)
	end
	function self.close_request() end
	function self.close_all_requests() end
	function self.has_request_card()
		return false
	end
	return self
end

-- ---------------------------------------------------------------------------------------------
Stubs.AttacksPanel = {}
function Stubs.AttacksPanel.new(c)
	local self = base(c)
	self.retreat_requested = Signal.new()
	self.toggled = Signal.new()
	self.collapsed = false
	self.tray_open = false
	self.panel = glass(self, "ATTACKS (stub)")
	self.panel:set_min_size(Vector2.new(300, 60))
	function self.apply_layout(s, top, _bottom)
		s.panel:set_anchors(1, 0, 1, 0)
		s.panel:set_grow(W.GROW_BEGIN, W.GROW_END)
		s.panel:set_offsets(-12 - s.ctx.insets.z, top, -12 - s.ctx.insets.z, top)
		s.panel:reset_size()
	end
	function self.peek() end
	function self.bottom_edge(s)
		return s.panel:get_global_rect().Max.Y
	end
	function self.mark_dirty() end
	function self.refresh() end
	return self
end

-- ---------------------------------------------------------------------------------------------
Stubs.AlertBanner = {}
function Stubs.AlertBanner.new(c)
	local self = base(c)
	self.panel = glass(self, "ALERT (stub)")
	self.panel:set_visible(false)
	function self.apply_layout(s, y, _right)
		s.panel:set_anchors(0.5, 0, 0.5, 0)
		s.panel:set_grow(W.GROW_BOTH, W.GROW_END)
		s.panel:set_offsets(0, y, 0, y)
		s.panel:reset_size()
	end
	function self.clear() end
	function self.is_green()
		return false
	end
	function self.track()
		return false
	end
	function self.resolve() end
	return self
end

--- Install stubs into UIRoot.kit for every kit module that is missing.
function Stubs.install(UIRoot)
	for name, cls in pairs(Stubs) do
		if type(cls) == "table" and cls.new ~= nil and UI:FindFirstChild(name) == nil then
			UIRoot.kit[name] = cls
		end
	end
end

return Stubs
