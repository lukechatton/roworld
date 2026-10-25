--!nonstrict
-- Port of scripts/ui/count_label.gd (UICount)
-- Label that animates between numeric values (troops, gold, percentages). Fixed-width tabular
-- rendering (UITheme.fix_width) keeps the rolling digits from jittering.

local UITheme = require("./UITheme")
local W = require("./Widgets")

local CountLabel = W.class(W.Label)

--- UICount.new(font_size = 18, weight = 700, color = TEXT, fmt = nil)  fmt: (value) -> string
function CountLabel.new(font_size: number?, weight: number?, color: any?, fmt: ((number) -> string)?)
	local self = setmetatable({}, CountLabel.__mt)
	W.Control._init(self)
	W.Label._init_label(self, "")
	self.formatter = fmt
	--- rolling number: fix_width renders it with equal-width digit cells (no jitter)
	self.rolling = true
	self.duration = 0.45
	self.value = 0.0
	self._shown = 0.0
	self._tween = nil
	self._init_done = false
	UITheme.style_label(self, font_size or 18, weight or 700, if color ~= nil then color else UITheme.TEXT)
	self:_refresh()
	return self
end

function CountLabel.set_value(self, v: number, animate: boolean?)
	if self._init_done and math.abs(v - self.value) < 1e-9 then
		return
	end
	self.value = v
	if animate == false or not self._init_done or not self:is_inside_tree() then
		self._init_done = true
		self._shown = v
		self:_refresh()
		return
	end
	if self._tween then
		self._tween:kill()
	end
	self._tween = self:create_tween()
	self._tween
		:tween_method(function(x: number)
			self:_set_shown(x)
		end, self._shown, v, self.duration)
		:set_trans(W.TRANS_CUBIC)
		:set_ease(W.EASE_OUT)
end

function CountLabel._set_shown(self, v: number)
	self._shown = v
	self:_refresh()
end

function CountLabel._refresh(self)
	local t
	if self.formatter then
		t = self.formatter(self._shown)
	else
		local r = self._shown
		t = tostring(if r >= 0 then math.floor(r + 0.5) else -math.floor(-r + 0.5))
	end
	self:set_text(t)
end

return CountLabel
