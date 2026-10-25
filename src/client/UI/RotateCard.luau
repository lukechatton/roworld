--!nonstrict
-- Port of scripts/ui/rotate_card.gd (UIRotateCard)
-- Full-screen "Rotate your phone" card shown on touch devices while the viewport is portrait
-- (the game is designed for landscape; StarterGui.ScreenOrientation normally keeps us there).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local Signal = UITheme.core("Signal")

local RotateCard = W.class(W.Control)

function RotateCard.new(c: any)
	local self = setmetatable({}, RotateCard.__mt)
	W.Control._init(self)
	self.ctx = c
	self.changed = Signal.new()
	self._t = 0.0
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	local bg = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.96))
	bg:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	bg:set_mouse_filter(W.MOUSE_IGNORE)
	self:add_child(bg)
	local cc = UITheme.vbox(14)
	cc:set_alignment(W.ALIGN_CENTER)
	cc.anchor_left, cc.anchor_top, cc.anchor_right, cc.anchor_bottom = 0.5, 0.5, 0.5, 0.5
	cc.grow_horizontal = W.GROW_BOTH
	cc.grow_vertical = W.GROW_BOTH
	self:add_child(cc)
	self._icon = UITheme.icon_rect("app_icon", 72.0, Color3.new(1, 1, 1))
	self._icon.size_flags_horizontal = W.SHRINK_CENTER
	cc:add_child(self._icon)
	local t = UITheme.label("ROTATE YOUR PHONE", 22, 900, UITheme.AMBER, 3)
	t:set_alignment(W.ALIGN_CENTER)
	cc:add_child(t)
	local s = UITheme.label(
		"RoWorld is played in landscape.\nTurn your device sideways to continue.",
		15,
		500,
		UITheme.TEXT_2
	)
	s:set_alignment(W.ALIGN_CENTER)
	cc:add_child(s)
	self:set_visible(false)
	return self
end

--- Shows / hides the card for the current viewport; fires `changed` when that flips (UIRoot then
--- re-evaluates its world-input gate, so rotating back never re-enables input under a modal).
function RotateCard.refresh(self)
	local ctx = self.ctx
	local want = (ctx.touch_device or ctx.touch) and ctx.vp.Y > ctx.vp.X
	self:set_process(want)
	if want ~= self.visible then
		self:set_visible(want)
		self.changed:Fire(want)
	end
end

function RotateCard._process(self, delta: number)
	self._t += delta
	self._icon:set_rotation(math.sin(self._t * 2.2) * 0.35)
end

return RotateCard
