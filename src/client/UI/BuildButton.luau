--!nonstrict
-- Port of scripts/ui/build_button.gd (UIBuildButton)
-- One build / nuke slot of the command bar: icon, cost, hotkey badge, owned count and a clear
-- disabled state. Stays clickable when unavailable so a click can explain why.
-- An Arsenal kind the player hasn't unlocked (UIRules.availability: `arsenal`) wears a gold lock
-- where its cost would be; its card shows what it does and what unlocks it.
--
-- Signals: chosen(kind). Methods as GDScript: set_compact(on, touch), refresh(), is_available(),
-- reason(), deny(), hint_spec(); `active` via set_active(on) (GDScript property setter).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local UICtx = require("./UICtx") :: any
local Signal = UITheme.core("Signal")

local _UIRules: any = nil
local function UIRules(): any
	if _UIRules == nil then
		_UIRules = UICtx.mod("UIRules")
	end
	return _UIRules
end

local BuildButton = W.class(W.Button)

function BuildButton.new(c: any, k: string, hk: string)
	local self = setmetatable({}, BuildButton.__mt)
	W.Control._init(self, "TextButton")
	W.Button._init_button(self, "", "GlassButton")
	self.ctx = c
	self.kind = k
	self.gui.Name = "Build_" .. k
	self.hotkey = hk
	self.active = false
	self.icon_px = 24.0
	--- Phones (tray): taller slots with the short name under the icon, since there is no hover.
	self.show_name = false
	self.chosen = Signal.new()
	self._av = { ok = false, locked = true, reason = "", cost = 0 }
	self._owned = 0
	self._flash = 0.0
	self._hint_serial = 0
	self._pressing = false
	self._long = false
	self.flat = true
	self:set_min_size(Vector2.new(54, 60))
	local g = self.gui
	local function text(name: string, z: number): TextLabel
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.BorderSizePixel = 0
		t.AnchorPoint = Vector2.zero
		t.TextYAlignment = Enum.TextYAlignment.Top
		t.ZIndex = z
		t.Active = false
		t.Parent = g
		return t
	end
	local ic = Instance.new("ImageLabel")
	ic.Name = "Glyph"
	ic.BackgroundTransparency = 1
	ic.BorderSizePixel = 0
	ic.AnchorPoint = Vector2.zero
	ic.ScaleType = Enum.ScaleType.Fit
	ic.ZIndex = 4
	ic.Parent = g
	self._glyph = ic
	local lock = Instance.new("ImageLabel")
	lock.Name = "Lock"
	lock.BackgroundTransparency = 1
	lock.BorderSizePixel = 0
	lock.ScaleType = Enum.ScaleType.Fit
	lock.ZIndex = 6
	lock.Visible = false
	lock.Parent = g
	self._lock = lock
	self._cost = text("Cost", 5)
	self._name = text("Name", 5)
	self._hk = text("Hotkey", 5)
	self._own = text("Owned", 5)
	self.pressed:Connect(function()
		self:_on_pressed()
	end)
	self.mouse_entered:Connect(function()
		self:_on_enter()
	end)
	self.mouse_exited:Connect(function()
		self:_on_exit()
	end)
	self.button_down:Connect(function()
		self:_touch_down()
	end)
	self.button_up:Connect(function()
		-- The card stays up until the next tap anywhere (UIInteract hides it).
		self._pressing = false
		self:_redraw()
	end)
	return self
end

function BuildButton.set_active(self, on: boolean)
	self.active = on
	self:_redraw()
end

function BuildButton.set_compact(self, on: boolean, touch: boolean)
	self.show_name = on and touch
	local ms = if on then Vector2.new(46, 46) else Vector2.new(54, 60)
	if touch and not on then
		ms = Vector2.new(56, 62)
	end
	if self.show_name then
		ms = Vector2.new(self.slot_w or 60, 64)
	end
	self:set_min_size(ms)
	self.icon_px = if on then 20.0 else 24.0
	self:_redraw()
end

--- Phone tray: the slot's width when the row is tight (nil: the usual 60).
function BuildButton.set_slot_width(self, w: number?)
	if w == self.slot_w then
		return
	end
	self.slot_w = w
	if self.show_name then
		self:set_min_size(Vector2.new(w or 60, 64))
		self:_redraw()
	end
end

local function av_equal(a, b): boolean
	return a.ok == b.ok
		and a.locked == b.locked
		and a.reason == b.reason
		and a.cost == b.cost
		and a.arsenal == b.arsenal
end

function BuildButton.refresh(self)
	local rules = self.ctx.rules
	if rules == nil then
		return
	end
	local av = rules:availability(self.kind)
	local own = rules:owned(self.kind)
	if not av_equal(av, self._av) or own ~= self._owned then
		self._av = {
			ok = av.ok == true,
			locked = av.locked == true,
			reason = tostring(av.reason or ""),
			cost = tonumber(av.cost) or 0,
			arsenal = av.arsenal,
		}
		self._owned = own
		self:_redraw()
	end
end

function BuildButton.is_available(self): boolean
	return self._av.ok == true
end

function BuildButton.reason(self): string
	return tostring(self._av.reason or "")
end

--- Short shake + red flash when a disabled slot is used.
function BuildButton.deny(self)
	self._flash = 1.0
	local t = self:create_tween()
	local base = self.position.X
	t:tween_property(self, "position:x", base - 3.0, 0.04)
	t:tween_property(self, "position:x", base + 3.0, 0.06)
	t:tween_property(self, "position:x", base, 0.05)
	self:set_process(true)
end

function BuildButton._process(self, delta: number)
	if self._flash > 0 then
		self._flash = math.max(0, self._flash - delta * 2.5)
		self:_redraw()
	else
		self:set_process(false)
	end
end

function BuildButton._on_pressed(self)
	if self._long then
		self._long = false
		return
	end
	self.ctx:hide_hint(self)
	self.chosen:Fire(self.kind)
end

--- Touch: long-press shows the slot's card (costs, what it does, why it is unavailable).
function BuildButton._touch_down(self)
	self:_redraw()
	if not self.ctx.touch then
		return
	end
	self._pressing = true
	self._long = false
	self._hint_serial += 1
	local serial = self._hint_serial
	W.timer(0.45, function()
		if self._pressing and serial == self._hint_serial and not self._freed then
			self._long = true
			self.ctx:show_hint(self, self:hint_spec(), true)
		end
	end)
end

function BuildButton._on_enter(self)
	self:_redraw()
	self._hint_serial += 1
	local serial = self._hint_serial
	W.timer(0.28, function()
		if self._hover and serial == self._hint_serial and not self._freed then
			self.ctx:show_hint(self, self:hint_spec())
		end
	end)
end

function BuildButton._on_exit(self)
	self._hint_serial += 1
	self._pressing = false
	self:_redraw()
	self.ctx:hide_hint(self)
end

function BuildButton.hint_spec(self): { [string]: any }
	local R = UIRules()
	local c = self._av.cost or 0
	local nuke = R.is_nuke(self.kind)
	local rows: { any } = { { "Cost", if c > 0 then UITheme.fmt_cost(c) .. " gold" else "Free", UITheme.GOLD } }
	if self.kind == "reinforce" then
		local o = self.ctx:my()
		local troops = if o ~= nil
			then UITheme.core("Rules").reinforce_troops(o.troops or 0, o.max_troops or 0)
			else 0
		table.insert(rows, { "Brings", UITheme.fmt_troops(troops) .. " troops", UITheme.TEXT })
	elseif not nuke then
		table.insert(rows, { "Owned", tostring(self._owned), UITheme.TEXT })
	else
		table.insert(rows, { "Blast radius", R.blast_text(self.kind), UITheme.TEXT })
	end
	local item = R.arsenal_item(self.kind)
	if self._av.arsenal ~= nil and item ~= nil then
		-- locked: what unlocks it
		rows = {}
		if item.stars ~= nil then
			table.insert(rows, { "Unlock", UICtx.commas(item.stars) .. " Stars", UITheme.GOLD })
		end
	end
	local spec: { [string]: any } = {
		title = R.TITLES[self.kind] or self.kind,
		badge = if not self.ctx.touch then self.hotkey else "",
		badge_color = UITheme.TEXT_2,
		body = R.blurb(self.kind),
		rows = rows,
	}
	if self._av.arsenal ~= nil then
		spec.hint = "Locked: " .. (if self.ctx.touch then "tap" else "click") .. " to unlock it in the Arsenal"
		spec.hint_color = UITheme.GOLD
		spec.hint_icon = "lock"
	elseif self._av.ok then
		spec.hint = if self.kind == "reinforce"
			then "Click to call them in"
			elseif nuke then "Click, then pick a target"
			else "Click, then choose a spot on your land"
		spec.hint_color = UITheme.CYAN
		spec.hint_icon = "target"
	else
		spec.hint = self:reason()
		spec.hint_color = UITheme.RED
		spec.hint_icon = "info"
	end
	return spec
end

-- Buttons refresh their look from _draw_state (hover / press changes) and _on_geometry.
function BuildButton._draw_state(self)
	self:_redraw()
end

function BuildButton._draw(self)
	self:_redraw()
end

--- A TextLabel positioned by its baseline like Godot draw_string(pos = (x, baseline), width, align).
local function place_text(
	self,
	t: TextLabel,
	x: number,
	baseline: number,
	w: number,
	align,
	size: number,
	weight: number,
	s: string,
	col
)
	local sc = UITheme.scale
	local ts = UITheme.text_size(size)
	t.FontFace = UITheme.font(weight)
	t.TextSize = ts
	t.Text = s
	t.TextXAlignment = align
	local ww = if w > 0 then w else UITheme.measure_text(s, size, weight) + 2
	local top_px = math.floor(baseline * sc + 0.5) - math.floor(ts * UITheme.RBX_BASELINE + 0.5)
	t.Position = UDim2.fromOffset(math.floor(x * sc + 0.5), top_px)
	t.Size = UDim2.fromOffset(math.floor(ww * sc + 0.5), ts)
	t.TextColor3 = UITheme.color3(col)
	t.Visible = true
	self:_part(t, "TextTransparency", UITheme.alpha(col))
end

function BuildButton._redraw(self)
	if self._geo == nil or self.ctx == nil then
		return
	end
	local R = UIRules()
	local size = self.size
	local ok = self._av.ok == true
	local locked = self._av.locked == true
	local arsenal_locked = self._av.arsenal ~= nil
	local nuke = R.is_nuke(self.kind)
	local bg: any = UITheme.rgba(1, 1, 1, 0.035)
	local border: any = UITheme.rgba(1, 1, 1, 0.07)
	if arsenal_locked then
		bg = UITheme.c(UITheme.GOLD, 0.05)
		border = UITheme.c(UITheme.GOLD, 0.28)
	end
	if nuke and ok then
		bg = UITheme.c(UITheme.RED, 0.07)
		border = UITheme.c(UITheme.RED, 0.22)
	end
	if self._hover then
		bg = if not nuke then UITheme.rgba(1, 1, 1, 0.1) else UITheme.c(UITheme.RED, 0.16)
		border = UITheme.LINE_2
	end
	if self.button_pressed or (self._hover and self._down) then
		bg = UITheme.rgba(1, 1, 1, 0.05)
	end
	if self.active then
		bg = UITheme.c(UITheme.AMBER, 0.2)
		border = UITheme.AMBER
	end
	if self._flash > 0 then
		bg = UITheme.lerp(bg, UITheme.c(UITheme.RED, 0.35), self._flash)
		border = UITheme.lerp(border, UITheme.RED, self._flash)
	end
	self._sv:set(UITheme.flat(bg, UITheme.R_MD, border, 1))

	local icol: any = UITheme.TEXT
	if nuke then
		icol = Color3.new(1.0, 0.86, 0.84)
	end
	if not ok then
		icol = UITheme.c(icol, if arsenal_locked then 0.55 elseif locked then 0.2 else 0.5)
	end
	if self.active then
		icol = UITheme.AMBER_HI
	end
	local cy = size.Y * (if size.Y < 50 then 0.4 else 0.42)
	if self.show_name then
		cy = 17.0
	end
	local ip = self.icon_px
	local sc = UITheme.scale
	local g = self._glyph
	g.Image = UITheme.icon(self.kind) or ""
	g.ImageColor3 = UITheme.color3(icol)
	self:_part(g, "ImageTransparency", UITheme.alpha(icol))
	local ipx = math.floor(ip * sc + 0.5)
	g.Size = UDim2.fromOffset(ipx, ipx)
	g.Position = UDim2.fromOffset(
		math.floor((size.X * 0.5) * sc + 0.5) - math.floor(ipx / 2),
		math.floor((cy - ip * 0.5) * sc + 0.5)
	)

	local fs = math.max(11, UITheme.min_font_size)
	local c = self._av.cost or 0
	local ctext = if c > 0 then UITheme.fmt_cost(c) elseif c == 0 then "FREE" else "-"
	local ccol: any = UITheme.GOLD
	if locked then
		ccol = UITheme.c(UITheme.TEXT_3, 0.8)
	elseif not ok then
		ccol = UITheme.c(UITheme.RED, 0.95)
	end
	-- a locked Arsenal kind: a gold lock where the cost would be
	local lock = self._lock
	lock.Visible = arsenal_locked
	if arsenal_locked then
		ctext = ""
		local lpx = math.floor(12 * sc + 0.5)
		lock.Image = UITheme.icon("lock") or ""
		lock.ImageColor3 = UITheme.color3(UITheme.GOLD)
		lock.Size = UDim2.fromOffset(lpx, lpx)
		lock.Position = UDim2.fromOffset(
			math.floor(size.X * 0.5 * sc + 0.5) - lpx // 2,
			math.floor((size.Y - (if size.Y < 50 then 4.0 else 6.0)) * sc + 0.5) - lpx
		)
	end
	place_text(
		self,
		self._cost,
		0,
		size.Y - (if size.Y < 50 then 5.0 else 7.0),
		size.X,
		Enum.TextXAlignment.Center,
		fs,
		700,
		ctext,
		ccol
	)
	if self.show_name then
		local ncol = UITheme.c(UITheme.TEXT, if ok then 0.9 else (if locked then 0.45 else 0.7))
		place_text(
			self,
			self._name,
			0,
			42.0,
			size.X,
			Enum.TextXAlignment.Center,
			math.max(12, UITheme.min_font_size),
			600,
			R.SHORT[self.kind] or self.kind,
			ncol
		)
	else
		self._name.Visible = false
	end
	if not self.ctx.touch and self.hotkey ~= "" then
		place_text(
			self,
			self._hk,
			6.0,
			13.0,
			0,
			Enum.TextXAlignment.Left,
			9,
			600,
			self.hotkey,
			UITheme.c(UITheme.TEXT_3, 0.9)
		)
	else
		self._hk.Visible = false
	end
	if self._owned > 0 and not nuke then
		local bfs = if UITheme.min_font_size > 0 then UITheme.min_font_size else 9
		place_text(
			self,
			self._own,
			0,
			4.0 + bfs,
			size.X - 5.0,
			Enum.TextXAlignment.Right,
			bfs,
			600,
			"×" .. tostring(self._owned),
			UITheme.c(UITheme.TEXT_2, 0.9)
		)
	else
		self._own.Visible = false
	end
end

return BuildButton
