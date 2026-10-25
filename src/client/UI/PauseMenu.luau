--!nonstrict
-- Port of scripts/ui/pause_menu.gd (UIPauseMenu)
-- Game menu: resume, how to play, settings, and leave / surrender with a confirmation step.
--
-- The same window has a second page, SETTINGS (2026-10-07, with a new switch to turn off the
-- pop expansion sound): the music, border pop, territory label and
-- "select before attacking" switches and "Show tips again", which stood in the game menu itself
-- before. The top bar's gear opens the window on that page (on the title too); the game menu's
-- Settings row turns to it, and DONE turns back.

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Signal = UITheme.core("Signal")
local Defs = UICtx.core("Defs")
local UserInputService = game:GetService("UserInputService")

local PauseMenu = W.class(W.Control)

-- =============================================================================================
-- Switch (a row button with an animated toggle on the right)
-- =============================================================================================

local Switch = W.class(W.Button)
PauseMenu.Switch = Switch

function Switch.new(text: string, icon_name: string)
	local self = setmetatable({}, Switch.__mt)
	W.Control._init(self, "TextButton")
	W.Button._init_button(self, "", "GlassButton")
	self.on = false
	self._k = 0.0
	self:set_min_size(Vector2.new(0, 46))
	local normal = UITheme.flat(UITheme.rgba(1, 1, 1, 0.04), 10, UITheme.rgba(1, 1, 1, 0.08), 1)
	local hover = UITheme.flat(UITheme.rgba(1, 1, 1, 0.07), 10, UITheme.rgba(1, 1, 1, 0.08), 1)
	self:add_theme_stylebox_override("normal", normal)
	self:add_theme_stylebox_override("pressed", normal)
	self:add_theme_stylebox_override("disabled", normal)
	self:add_theme_stylebox_override("hover", hover)
	self:add_theme_stylebox_override("hover_pressed", hover)
	local h = UITheme.hbox(12)
	h:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	h.offset_left = 14.0
	h.offset_right = -70.0
	self:add_child(h)
	local ic = UITheme.icon_rect(icon_name, 18.0, UITheme.TEXT_2)
	ic.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(ic)
	local l = UITheme.label(text, 14, 600)
	l.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(l)
	-- Track + knob (drawn parts).
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BorderSizePixel = 0
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.ZIndex = 6
	track.Parent = self.gui
	self._track_corner = Instance.new("UICorner")
	self._track_corner.Parent = track
	self._track = track
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.BorderSizePixel = 0
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.ZIndex = 7
	knob.Parent = self.gui
	local kc = Instance.new("UICorner")
	kc.CornerRadius = UDim.new(0.5, 0)
	kc.Parent = knob
	self._knob = knob
	self:_part(knob, "BackgroundTransparency", 1.0)
	self.pressed:Connect(function()
		self:set_on(not self.on)
	end)
	self:_draw_switch()
	return self
end

function Switch.set_on(self, v: boolean)
	self.on = v
	self:set_process(true)
end

function Switch._process(self, delta: number)
	local target = if self.on then 1.0 else 0.0
	if math.abs(self._k - target) > 1e-4 then
		self._k = Defs.move_toward(self._k, target, delta * 8.0)
		self:_draw_switch()
	else
		self:set_process(false)
	end
end

function Switch._draw(self)
	self:_draw_switch()
end

function Switch._draw_switch(self)
	local s = UITheme.scale
	local k = self._k
	local tw, th = 40.0, 22.0
	local track = self._track
	track.Position = UDim2.new(1, -math.floor(14 * s + 0.5), 0.5, 0)
	track.Size = UDim2.fromOffset(math.floor(tw * s + 0.5), math.floor(th * s + 0.5))
	self._track_corner.CornerRadius = UDim.new(0, math.floor(11 * s + 0.5))
	local col = UITheme.lerp(UITheme.rgba(1, 1, 1, 0.14), UITheme.to_rgba(UITheme.AMBER), k)
	track.BackgroundColor3 = UITheme.color3(col)
	self:_part(track, "BackgroundTransparency", UITheme.alpha(col))
	local kx = (-14 - tw + 11) + (tw - 22) * k
	self._knob.Position = UDim2.new(1, math.floor(kx * s + 0.5), 0.5, 0)
	self._knob.Size = UDim2.fromOffset(math.floor(16 * s + 0.5), math.floor(16 * s + 0.5))
end

-- =============================================================================================
-- VolumeRow (a row like a Switch with a slider on the right: the music's level)
-- =============================================================================================

--- A music volume slider (2026-10-21). It began as a Music switch with a Volume row under it; two rows
--- were one too many, so it is one row as a Switch's
--- (icon and label on the left), with Tribes' slider on the right: a track and the value in a fixed column.
--- Tap or drag the track (the grab area is the row's right part, its full height), or the mouse wheel over
--- the row; `changed(v, final)`: v in 0..1, final once the finger lifts (save then).
local VolumeRow = W.class(W.Control)
PauseMenu.VolumeRow = VolumeRow
--- Logical px: the room the icon and label keep on the left, the gap at the right, the value's column,
--- the gap before it, and the track's limits (it takes the room left between).
VolumeRow.LEFT_W = 112.0
VolumeRow.RIGHT = 14.0
VolumeRow.PCT_W = 40.0
VolumeRow.GAP = 10.0
VolumeRow.TRACK_MIN = 80.0
VolumeRow.TRACK_MAX = 170.0
--- A wheel notch moves it this much.
VolumeRow.WHEEL_STEP = 0.05

local FONT_PCT = Font.fromId(UITheme.FONT_ID, Enum.FontWeight.Bold)

function VolumeRow.new(text: string, icon_name: string)
	local self = setmetatable({}, VolumeRow.__mt)
	W.Control._init(self)
	self.gui.Name = "MusicVolume"
	--- (set by the menu: a tick as the value steps)
	self.ctx = nil :: any
	self.value = 1.0
	self.changed = Signal.new()
	self._drag = false
	self:set_min_size(Vector2.new(0, 46))
	self:set_mouse_filter(W.MOUSE_STOP)
	local g = self.gui
	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.BorderSizePixel = 0
	bg.BackgroundColor3 = Color3.new(1, 1, 1)
	bg.Size = UDim2.fromScale(1, 1)
	bg.ZIndex = 4
	bg.Parent = g
	self._bg_corner = Instance.new("UICorner")
	self._bg_corner.Parent = bg
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Parent = bg
	-- (a Switch's look: 4% white, 7% under the mouse, a 8% line)
	self:_part(bg, "BackgroundTransparency", 0.04)
	self:_part(stroke, "Transparency", 0.08)
	self:_connect(g.MouseEnter:Connect(function()
		self:_part(bg, "BackgroundTransparency", 0.07)
	end))
	self:_connect(g.MouseLeave:Connect(function()
		self:_part(bg, "BackgroundTransparency", 0.04)
	end))
	local h = UITheme.hbox(12)
	h:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	h.offset_left = 14.0
	h.offset_right = -(VolumeRow.RIGHT + VolumeRow.PCT_W + VolumeRow.GAP + VolumeRow.TRACK_MIN)
	h:set_mouse_filter(W.MOUSE_IGNORE)
	self:add_child(h)
	local ic = UITheme.icon_rect(icon_name, 18.0, UITheme.TEXT_2)
	ic.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(ic)
	local l = UITheme.label(text, 14, 600)
	l.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(l)
	local function part(name: string, z: number): Frame
		local f = Instance.new("Frame")
		f.Name = name
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0, 0.5)
		f.ZIndex = z
		f.Parent = g
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = f
		return f
	end
	self._track = part("VolTrack", 6)
	self._fill = part("VolFill", 7)
	self._knob = part("VolKnob", 8)
	self._knob.AnchorPoint = Vector2.new(0.5, 0.5)
	self._knob.BackgroundColor3 = Color3.new(1, 1, 1)
	local ks = Instance.new("UIStroke")
	ks.Color = Color3.fromRGB(120, 72, 8)
	ks.Thickness = 2
	ks.Parent = self._knob
	self:_part(self._knob, "BackgroundTransparency", 1.0)
	self:_part(ks, "Transparency", 0.9)
	self:_part(self._fill, "BackgroundTransparency", 1.0)
	local pct = Instance.new("TextLabel")
	pct.Name = "VolPct"
	pct.BackgroundTransparency = 1
	pct.AnchorPoint = Vector2.new(1, 0.5)
	pct.FontFace = FONT_PCT
	pct.TextXAlignment = Enum.TextXAlignment.Right
	pct.TextColor3 = UITheme.color3(UITheme.to_rgba(UITheme.TEXT_2))
	pct.Text = "100%"
	pct.ZIndex = 6
	pct.Parent = g
	self:_part(pct, "TextTransparency", 1.0)
	self._pct = pct
	self:_connect(g.InputBegan:Connect(function(io: InputObject)
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			local x = self:_local_x(io)
			if x >= self:_track_x() - 18.0 then
				self._drag = true
				self._drag_input = io
				self:_set_from_x(x, false)
				self:_draw_row()
			end
		end
	end))
	self:_connect(g.InputChanged:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.MouseWheel and io.Position.Z ~= 0 then
			local v = math.clamp(self.value + VolumeRow.WHEEL_STEP * math.sign(io.Position.Z), 0.0, 1.0)
			self:_set(math.floor(v * 20 + 0.5) / 20, true)
		end
	end))
	self:_connect(UserInputService.InputChanged:Connect(function(io: InputObject)
		if not self._drag then
			return
		end
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseMovement or (t == Enum.UserInputType.Touch and io == self._drag_input) then
			self:_set_from_x(self:_local_x(io), false)
		end
	end))
	self:_connect(UserInputService.InputEnded:Connect(function(io: InputObject)
		if not self._drag then
			return
		end
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseButton1 or (t == Enum.UserInputType.Touch and io == self._drag_input) then
			self._drag = false
			self._drag_input = nil
			self:_draw_row()
			self.changed:Fire(self.value, true)
		end
	end))
	self:_draw_row()
	return self
end

--- The pointer's x in the row (logical px).
function VolumeRow._local_x(self, io: InputObject): number
	return W.screen_to_logical(W.input_pos(io), self).X - self:get_global_position().X
end

--- The track's width: the room the row leaves after the icon and label and the value (logical px).
function VolumeRow._track_w(self): number
	local room = self.size.X - VolumeRow.LEFT_W - (VolumeRow.RIGHT + VolumeRow.PCT_W + VolumeRow.GAP)
	return math.clamp(room, VolumeRow.TRACK_MIN, VolumeRow.TRACK_MAX)
end

--- The track's left edge in the row (logical px).
function VolumeRow._track_x(self): number
	return self.size.X - VolumeRow.RIGHT - VolumeRow.PCT_W - VolumeRow.GAP - self:_track_w()
end

function VolumeRow._set_from_x(self, x: number, final: boolean)
	local v = math.clamp((x - self:_track_x()) / self:_track_w(), 0.0, 1.0)
	self:_set(math.floor(v * 20 + 0.5) / 20, final) -- (steps of 5%)
end

function VolumeRow._set(self, v: number, final: boolean)
	if v ~= self.value or final then
		if v ~= self.value and self.ctx ~= nil then
			self.ctx:sfx("ui_click", -10.0, 0, 0.8 + v * 0.6) -- (a tick per step, as Tribes', higher as it rises)
		end
		self:set_value(v)
		self.changed:Fire(self.value, final)
	end
end

--- Show `v` (0..1) without firing changed.
function VolumeRow.set_value(self, v: number)
	self.value = math.clamp(tonumber(v) or 1.0, 0.0, 1.0)
	self._pct.Text = string.format("%d%%", math.floor(self.value * 100 + 0.5))
	self:_draw_row()
end

function VolumeRow._on_geometry(self)
	self:_draw_row()
end

function VolumeRow._draw(self)
	self:_draw_row()
end

-- (raw instances in px: logical px x UITheme.scale)
function VolumeRow._draw_row(self)
	local sc = UITheme.scale
	local px = function(v: number): number
		return math.floor(v * sc + 0.5)
	end
	self._bg_corner.CornerRadius = UDim.new(0, px(10))
	local tw = self:_track_w()
	local from_right = VolumeRow.RIGHT + VolumeRow.PCT_W + VolumeRow.GAP + tw
	local th = 6.0
	self._track.Position = UDim2.new(1, -px(from_right), 0.5, 0)
	self._track.Size = UDim2.fromOffset(px(tw), px(th))
	local tcol = UITheme.rgba(1, 1, 1, 0.14)
	self._track.BackgroundColor3 = UITheme.color3(tcol)
	self:_part(self._track, "BackgroundTransparency", UITheme.alpha(tcol))
	local fw = tw * self.value
	self._fill.Visible = fw > 0.5
	self._fill.Position = UDim2.new(1, -px(from_right), 0.5, 0)
	self._fill.Size = UDim2.fromOffset(px(math.max(fw, th)), px(th))
	self._fill.BackgroundColor3 = UITheme.color3(UITheme.to_rgba(UITheme.AMBER))
	self._knob.Position = UDim2.new(1, -px(from_right - fw), 0.5, 0)
	local k = if self._drag then 19 else 16
	self._knob.Size = UDim2.fromOffset(px(k), px(k))
	self._pct.Position = UDim2.new(1, -px(VolumeRow.RIGHT), 0.5, 0)
	self._pct.Size = UDim2.fromOffset(px(VolumeRow.PCT_W), px(20))
	self._pct.TextSize = math.max(px(13), 8)
end

-- =============================================================================================
-- Menu
-- =============================================================================================

function PauseMenu.new(c: any)
	local self = setmetatable({}, PauseMenu.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.help_requested = Signal.new()
	self.leave_requested = Signal.new()
	self.labels_toggled = Signal.new()
	self.music_toggled = Signal.new()
	--- (v 0..1, final): the music volume slider; final once the drag ends (UIRoot saves then)
	self.music_volume_changed = Signal.new()
	self.pops_toggled = Signal.new()
	self.restart_requested = Signal.new()
	self.tips_reset = Signal.new()
	--- Rofront Staging only: "Replay as new player" was pressed
	self.new_player_requested = Signal.new()
	self.is_open = false
	self._layout_compact = -1
	--- "menu" or "settings", and whether the settings page was reached from the menu (DONE goes back)
	self._page = "menu"
	self._from_menu = false
	self._confirm_action = ""
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self._dim = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.6))
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._dim.gui_input:Connect(function(e)
		-- (a press on the window's own ground reaches the dim too, as in Arsenal: only one outside it
		-- closes. Found 2026-10-21 with the music slider, whose every press closed the window)
		if e.pressed and not self._panel:has_global_point(e.global_position) then
			self:close()
		end
	end)
	self:add_child(self._dim)
	self._panel = GlassPanel.new(22.0, 22.0, 18, true, 34)
	self._panel:set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.94))
	self._panel:set_min_size(Vector2.new(380, 0))
	self:add_child(self._panel)
	local v = UITheme.vbox(14)
	self._v = v
	self._panel:add_child(v)
	-- the head: the title and its line, and (the settings page on a phone) the page's own buttons
	-- beside them, so the window is no taller than its switches
	local head_row = UITheme.hbox(10)
	v:add_child(head_row)
	local head = UITheme.vbox(2)
	head.size_flags_horizontal = W.EXPAND_FILL
	head.size_flags_vertical = W.SHRINK_CENTER
	self._title = UITheme.label("GAME MENU", 20, 800, UITheme.TEXT, 3)
	head:add_child(self._title)
	self._sub = UITheme.label("", 13, 500, UITheme.TEXT_2)
	head:add_child(self._sub)
	head_row:add_child(head)
	self._head_actions = UITheme.hbox(8)
	self._head_actions.size_flags_vertical = W.SHRINK_CENTER
	self._head_actions:set_visible(false)
	head_row:add_child(self._head_actions)

	-- Items live in one column on desktop and in two side-by-side columns on phones (short screens).
	self._main = UITheme.hbox(12)
	v:add_child(self._main)
	self._col_a = UITheme.vbox(8)
	self._col_a:set_min_size(Vector2.new(336, 0))
	self._col_b = UITheme.vbox(8)
	self._col_b:set_min_size(Vector2.new(336, 0))
	self._main:add_child(self._col_a)
	self._main:add_child(self._col_b)
	self._resume = UITheme.button("RESUME", "PrimaryButton", "play", 50.0)
	self._resume.pressed:Connect(function()
		self:close()
	end)
	self._help_btn = UITheme.button("How to play", "GlassButton", "help", 46.0)
	self._help_btn.alignment = W.ALIGN_LEFT
	self._help_btn.pressed:Connect(function()
		self:close()
		self.help_requested:Fire()
	end)
	self._settings_btn = UITheme.button("Settings", "GlassButton", "settings", 46.0)
	self._settings_btn.alignment = W.ALIGN_LEFT
	self._settings_btn.pressed:Connect(function()
		self._from_menu = true
		self:_show_page("settings")
	end)
	self._done = UITheme.button("DONE", "PrimaryButton", "check", 50.0)
	self._done.pressed:Connect(function()
		if self._from_menu then
			self._from_menu = false
			self:_show_page("menu")
		else
			self:close()
		end
	end)
	self._labels = Switch.new("Territory labels", "layers")
	self._labels.pressed:Connect(function()
		self.labels_toggled:Fire(self._labels.on)
	end)
	-- Music: one slider row (0% = off), as Tribes' settings. Music stays on/off underneath (the top bar's
	-- button and M toggle it): 0% is silent at once and switches it off when the finger lifts, any level
	-- above switches it on, and the level saved and kept for the button is the last one above 0.
	self._music = VolumeRow.new("Music", "music_on")
	self._music.ctx = c
	self._music_on = true
	self._music_keep = 1.0
	self._music.changed:Connect(function(v: number, final: boolean)
		if v <= 0 then
			self.music_volume_changed:Fire(0, false)
			if final and self._music_on then
				self._music_on = false
				self.music_toggled:Fire(false)
			end
			return
		end
		self.music_volume_changed:Fire(v, final)
		if final then
			self._music_keep = v
		end
		if not self._music_on then
			self._music_on = true
			self.music_toggled:Fire(true)
		end
	end)
	self._pops = Switch.new("Border pop sound", "pops")
	self._pops.pressed:Connect(function()
		self.pops_toggled:Fire(self._pops.on)
	end)
	self._confirm_sw = Switch.new("Select before attacking", "target")
	self._confirm_sw.pressed:Connect(function()
		self.ctx:set_setting(self:_confirm_key(), self._confirm_sw.on)
	end)
	self._tips = UITheme.button("Show tips again", "GhostButton", "info", 44.0)
	self._tips.alignment = W.ALIGN_LEFT
	self._tips:set_font_size(13)
	self._tips.pressed:Connect(function()
		self.tips_reset:Fire()
		self._tips:set_text("Tips will show again")
		self._tips:set_disabled(true)
	end)
	-- Rofront Staging (and Studio) only: be a new player again, to see the tutorial and every other
	-- first-time thing (2026-10-04: "Replay as new player")
	self._new_player = UITheme.button("Replay as new player", "GhostButton", "retreat", 44.0)
	self._new_player.alignment = W.ALIGN_LEFT
	self._new_player:set_font_size(13)
	self._new_player.pressed:Connect(function()
		self.new_player_requested:Fire()
	end)
	self._new_player:set_visible(false)
	self._divider = UITheme.hdivider()
	self._restart = UITheme.button("Restart match", "GlassButton", "retreat", 46.0)
	self._restart.alignment = W.ALIGN_LEFT
	self._restart.pressed:Connect(function()
		self:_ask_restart()
	end)
	-- (big and solid red since 2026-10-19, at a player's request; it was a
	-- tinted row like the others)
	self._leave = UITheme.button("LEAVE MATCH", "SurrenderButton", "exit", 56.0)
	self._leave.pressed:Connect(function()
		self:_ask_leave()
	end)
	self:_reflow(false)

	self._confirm = UITheme.vbox(12)
	self._confirm:set_visible(false)
	v:add_child(self._confirm)
	self._confirm_text = UITheme.label("", 14, 500, UITheme.TEXT)
	self._confirm_text:set_autowrap(true)
	self._confirm_text:set_min_size(Vector2.new(320, 0))
	self._confirm:add_child(self._confirm_text)
	local row = UITheme.hbox(10)
	local cancel = UITheme.button("Stay", "GlassButton", "", 46.0)
	cancel.size_flags_horizontal = W.EXPAND_FILL
	cancel.pressed:Connect(function()
		self._confirm:set_visible(false)
		self._main:set_visible(true)
		self:_center()
	end)
	row:add_child(cancel)
	self._confirm_go = UITheme.button("Leave", "SurrenderButton", "exit", 46.0)
	self._confirm_go.size_flags_horizontal = W.EXPAND_FILL
	self._confirm_go.pressed:Connect(function()
		self:close()
		if self._confirm_action == "restart" then
			self.restart_requested:Fire()
		else
			self.leave_requested:Fire()
		end
	end)
	row:add_child(self._confirm_go)
	self._confirm:add_child(row)
	return self
end

function PauseMenu._ask_restart(self)
	self._confirm_action = "restart"
	self._confirm_text:set_text("Restart with a fresh world? This match will be lost.")
	self._confirm_go:set_text("Restart")
	self._confirm_go:set_icon("retreat")
	self._main:set_visible(false)
	self._confirm:set_visible(true)
	self:_center()
end

function PauseMenu._ask_leave(self)
	local ctx = self.ctx
	self._confirm_action = "leave"
	self._confirm_go:set_text("Leave")
	self._confirm_go:set_icon("exit")
	if not ctx:in_match() then
		self:close()
		self.leave_requested:Fire()
		return
	end
	local o = ctx:my()
	local mp = ctx:mode() == UICtx.MODE_MULTI
	if o ~= nil and o.alive and ctx.state ~= nil and ctx.state.phase == Defs.PHASE_PLAYING then
		self._confirm_text:set_text(
			"Surrender and return to the title screen? "
				.. (if mp then "Your nation stays on the map without a commander." else "This campaign will end.")
		)
	else
		self._confirm_text:set_text("Return to the title screen?")
	end
	self._main:set_visible(false)
	self._confirm:set_visible(true)
	self:_center()
end

--- `page`: "settings" opens on the settings page (the top bar's gear), else the game menu.
function PauseMenu.open(self, labels_on: boolean, page: string?)
	if self.is_open then
		return
	end
	local ctx = self.ctx
	self.is_open = true
	self._page = if page == "settings" then "settings" else "menu"
	self._from_menu = false
	self._labels.on = labels_on
	self._labels._k = if labels_on then 1.0 else 0.0
	self._labels:_draw_switch()
	self._music_on = ctx:music_enabled()
	if ctx:music_volume() > 0 then
		self._music_keep = ctx:music_volume()
	end
	self._music:set_value(if self._music_on then ctx:music_volume() else 0)
	self._pops.on = ctx:pops_enabled()
	self._pops._k = if self._pops.on then 1.0 else 0.0
	self._pops:_draw_switch()
	local cs = if ctx.touch
		then ctx:setting(self:_confirm_key(), ctx.touch_device or ctx.touch)
		else ctx:setting(self:_confirm_key(), false)
	self._confirm_sw.on = cs == true
	self._confirm_sw._k = if self._confirm_sw.on then 1.0 else 0.0
	self._confirm_sw:_draw_switch()
	local mp = ctx:mode() == UICtx.MODE_MULTI
	local on_title = not ctx:in_match()
	self._on_title = on_title
	local diff = { [0] = "Relaxed", "Standard", "Brutal" }
	local d =
		math.clamp(tonumber(ctx:setting("difficulty", UICtx.DEFAULT_DIFFICULTY)) or UICtx.DEFAULT_DIFFICULTY, 0, 2)
	if on_title then
		self._menu_sub = if ctx:mp_waiting() then "Waiting for the next multiplayer match" else "Main menu"
	else
		self._menu_sub = if mp then "Multiplayer match" else string.format("Solo match · %s · paused", diff[d])
	end
	self._restart:set_visible(not mp and not on_title)
	self._labels:set_visible(not on_title)
	self._confirm_sw:set_visible(not on_title)
	self._tips:set_text("Show tips again")
	self._tips:set_disabled(false)
	self._new_player:set_visible(ctx.staging == true)
	local o = ctx:my()
	local alive = o ~= nil and o.alive and ctx.state ~= nil and ctx.state.phase == Defs.PHASE_PLAYING
	self._leave:set_visible(not on_title or ctx:mp_waiting())
	if on_title then
		self._leave:set_text("LEAVE QUEUE")
	else
		self._leave:set_text(if alive then "SURRENDER" else "LEAVE MATCH")
	end
	self._main:set_visible(true)
	self._confirm:set_visible(false)
	self:set_visible(true)
	self._panel:set_modulate_a(1.0)
	self:_show_page(self._page)
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.2)
	UICtx.pop_in(self._panel, 0.0, 0.94, 0.3)
	ctx:sfx("open")
end

--- Separate settings for touch and mouse (UIInteract.confirm_orders reads the same keys).
function PauseMenu._confirm_key(self): string
	return if self.ctx.touch then "confirm_orders" else "confirm_orders_desktop"
end

function PauseMenu.sync_music(self, on: boolean)
	self._music_on = on
	if on and self.ctx:music_volume() <= 0 then
		-- (back on from the top bar or M after the slider went to 0: the last level above 0)
		self.ctx:set_music_volume(self._music_keep, false)
	end
	self._music:set_value(if on then self.ctx:music_volume() else 0)
end

function PauseMenu.sync_pops(self, on: boolean)
	self._pops:set_on(on)
end

--- The page shown: "menu" or "settings".
function PauseMenu.page(self): string
	return self._page
end

--- The settings page while the window is open (the top bar's gear pressed over the game menu).
function PauseMenu.show_settings(self)
	if self.is_open and self._page ~= "settings" then
		self._from_menu = true
		self:_show_page("settings")
	end
end

function PauseMenu._show_page(self, page: string)
	self._page = page
	local settings = page == "settings"
	self._title:set_text(if settings then "SETTINGS" else "GAME MENU")
	self._sub:set_text(if settings then "Saved for next time" else (self._menu_sub or ""))
	self._confirm:set_visible(false)
	self._main:set_visible(true)
	self._layout_compact = -1
	self:_reflow(self.ctx.compact)
	self:_center()
end

function PauseMenu.close(self)
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

function PauseMenu.apply_layout(self)
	self:_reflow(self.ctx.compact)
	self:_center()
end

function PauseMenu._reflow(self, compact: boolean)
	local want = if compact then 1 else 0
	if want == self._layout_compact then
		return
	end
	self._layout_compact = want
	for _, cc in ipairs({
		self._resume,
		self._help_btn,
		self._settings_btn,
		self._labels,
		self._music,
		self._pops,
		self._confirm_sw,
		self._tips,
		self._new_player,
		self._divider,
		self._restart,
		self._leave,
		self._done,
	}) do
		if cc:get_parent() ~= nil then
			cc:get_parent():remove_child(cc)
		end
	end
	local h = if compact then 44.0 else 46.0
	self._leave:set_min_size(Vector2.new(0, if compact then 46.0 else 56.0))
	for _, b in ipairs({
		self._help_btn,
		self._settings_btn,
		self._restart,
		self._labels,
		self._music,
		self._pops,
		self._confirm_sw,
	}) do
		b:set_min_size(Vector2.new(0, h))
	end
	self._resume:set_min_size(Vector2.new(0, if compact then 46.0 else 50.0))
	-- one column on desktop, two side by side on phones (short screens)
	local a, b
	-- the settings page on a phone: DONE and "Show tips again" stand in the head beside the title, and
	-- the title's line goes (2026-10-07: the settings page wasted vertical space on phones;
	-- it was a head of two lines over three rows, 235 px of a 390 px screen)
	local slim = compact and self._page == "settings"
	self._head_actions:set_visible(slim)
	self._sub:set_visible(not slim)
	self._title:set_font_size(if slim then 18 else 20)
	self._v.separation = if slim then 10 else 14
	self._done:set_min_size(if slim then Vector2.new(120, 38) else Vector2.new(0, if compact then 46.0 else 50.0))
	self._tips:set_min_size(Vector2.new(0, if slim then 38.0 else 44.0))
	if slim then
		for _, sw in ipairs({ self._labels, self._music, self._pops, self._confirm_sw }) do
			sw:set_min_size(Vector2.new(0, 42.0))
		end
		self._head_actions:add_child(self._tips)
		self._head_actions:add_child(self._done)
		if self._on_title then
			-- (no labels or orders on the title: the music slider and the pops side by side; Staging's
			-- "Replay as new player" under them, the game menu's main page being out of reach on the title)
			a = { self._music, self._new_player }
			b = { self._pops }
		else
			a = { self._music, self._pops, self._new_player }
			b = { self._labels, self._confirm_sw }
		end
	elseif self._page == "settings" then
		-- (Staging: "Replay as new player" here too: the title's gear only opens this page,
		-- so before 2026-10-15 the Staging title screen had no way to it)
		a = {
			self._music,
			self._pops,
			self._labels,
			self._confirm_sw,
			self._tips,
			self._new_player,
			self._done,
		}
	elseif compact then
		-- (Staging: "Replay as new player" stands under How to play)
		-- (SURRENDER at the foot of the second column, as tall as RESUME: a row of its own under both
		-- made the window taller than a phone's screen)
		a = { self._resume, self._help_btn, self._new_player }
		b = { self._settings_btn, self._restart, self._leave }
	else
		a = {
			self._resume,
			self._help_btn,
			self._settings_btn,
			self._new_player,
			self._divider,
			self._restart,
			self._leave,
		}
	end
	for _, c2 in ipairs(a) do
		self._col_a:add_child(c2)
	end
	for _, c3 in ipairs(b or {}) do
		self._col_b:add_child(c3)
	end
	local w = if compact then 290 else 336
	self._col_a:set_min_size(Vector2.new(w, 0))
	self._col_b:set_min_size(Vector2.new(w, 0))
	self._col_b:set_visible(b ~= nil)
	self._panel:set_padding(
		if compact then 16.0 else 22.0,
		if slim then 12.0 elseif compact then 14.0 else 22.0,
		if compact then 16.0 else 22.0,
		if slim then 12.0 elseif compact then 14.0 else 22.0
	)
end

function PauseMenu._center(self)
	local ctx = self.ctx
	local sz = self._panel:get_combined_minimum_size()
	local area = ctx:clear_rect()
	local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
	local y = math.max(p.Y, area.Min.Y + 4.0)
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(y + 0.5))
	self._panel:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
	self._panel:reset_size()
end

return PauseMenu
