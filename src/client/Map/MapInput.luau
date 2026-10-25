--!strict
-- Map input (from scripts/view/globe_input.gd): mouse, trackpad and multi-touch for MapView,
-- driving the MapCamera through its camera-rig API (drag pans the map, wheel / pinch zoom about
-- the pointer). "Globe" below means the map.
--
-- Touch model (Roblox): every touch is tracked by its InputObject from UserInputService. A touch
-- whose press was not processed by the GUI (gameProcessedEvent false: no Active GuiObject took it)
-- landed on free globe (GLOBE); one the GUI processed landed on a HUD control (UI). The GUI keeps
-- UI touches (taps, slider drags) unless they become part of a pinch.
--  * One GLOBE finger: orbit with inertia once it moves past the slop; a drag that crosses a HUD
--    panel keeps orbiting. Tap = tile_clicked, still 500 ms press = tile_context.
--  * A second finger stops any orbit / inertia at once and cancels the first finger's tap. If both
--    fingers are GLOBE the pinch starts immediately; if one started on the HUD it becomes a pinch
--    only when BOTH fingers move (a resting thumb on the globe + a tap / slider drag on the HUD
--    stays a HUD action). While pinching the globe only zooms (around the point under the
--    fingers' start midpoint); no rotation.
--  * Lifting fingers after a two-finger gesture never taps; a remaining GLOBE finger may orbit.
--  * touch_owned_by_world(io) tells the UI whether the view owns a touch (GLOBE gesture or pinch
--    participant); valid through the frame in which the finger lifts, so a HUD control can ignore
--    the release of a finger that took part in a pinch.
--  * Stale touches (review_code.md R2-6): a finger whose InputEnded never arrives (app backgrounded,
--    a system gesture stole it) must not lock the globe. A tracked touch is dropped when its
--    InputObject reports End / Cancel, when it has not moved for STALE_TOUCH_S and a new finger
--    would otherwise be refused (two tracked already: Roblox sends nothing for a finger held still,
--    so age alone never evicts a resting first finger — "rest a thumb, then pinch" stays a pinch),
--    when the window loses focus or the Roblox menu opens, and on input on / off.
-- Stop gesture: pressing (touch or mouse) while the globe is still moving (inertia above
-- STOP_PX_PER_S or a focus animation) halts it and that press never taps (it may still turn into a
-- drag, or be held for the menu: holding after a fling used to do nothing, which made the hold
-- menu seem inconsistent, 2026-09-29). Every press kills inertia.
-- hold_state() reports a touch hold in progress (UIRoot draws the hold ring from it).
-- Mouse: left-drag orbit, right-click context, wheel / trackpad pinch / two-finger pan zoom toward
-- the pointer. WASD / arrows pan and + / - zoom while input_enabled and no TextBox has focus.
-- All positions are VIEWPORT px (InputObject.Position + GuiService:GetGuiInset()).
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local MapInput = {}
MapInput.__index = MapInput

MapInput.TAP_SLOP_MOUSE = 6.0 -- px a press may move and still count as a click
MapInput.TAP_SLOP_TOUCH = 16.0 -- fingers wobble more (a hold for the menu must survive it: was 12)
MapInput.LONG_PRESS_MS = 500
MapInput.WHEEL_STEP = 1.16
MapInput.KEY_PAN_SPEED = 0.55 -- view heights per second
MapInput.KEY_ZOOM_SPEED = 1.6 -- doublings per second
MapInput.STOP_PX_PER_S = 30.0 -- globe moving faster than this under the pointer: a press only stops it
MapInput.PINCH_MOVE_PX = 8.0 -- both fingers must move this far to pinch when one started on the HUD
MapInput.GUI_PROBE_S = 0.1 -- re-test a resting pointer against the HUD this often (panels come and go)
--- A tracked touch without any update for this long is presumed lost (its end never arrived) once a
--- new finger comes down.
MapInput.STALE_TOUCH_S = 3.0

local GLOBE, UI = 1, 2
local TAP_SLOP_MOUSE, TAP_SLOP_TOUCH = MapInput.TAP_SLOP_MOUSE, MapInput.TAP_SLOP_TOUCH
local MOUSE = "mouse" -- press index of the mouse (touches use their InputObject)
local IS_END = { [Enum.UserInputState.End] = true, [Enum.UserInputState.Cancel] = true }

type Touch = { io: InputObject, pos: Vector2, pair_pos: Vector2, owner: number, order: number, t: number }

local function now_ms(): number
	return os.clock() * 1000
end

local function view_pos(io: InputObject): Vector2
	local inset = GuiService:GetGuiInset()
	return Vector2.new(io.Position.X, io.Position.Y) + inset
end

function MapInput.new(view: any, rig: any)
	local self = setmetatable({}, MapInput)
	self.view = view
	self.rig = rig
	--- Counters for tests / diagnostics.
	self.stats = { touch_presses = 0, mouse_presses = 0, stop_presses = 0, pinches = 0, stale_touches = 0, ticks = 0 }
	self._press_active = false
	self._press_index = nil :: any -- MOUSE or the touch's InputObject
	self._press_pos = Vector2.zero
	self._press_ms = 0
	self._press_dragging = false
	self._press_consumed = false
	self._press_stop = false
	self._press_slop = TAP_SLOP_MOUSE
	self._touches = {} :: { [InputObject]: Touch }
	self._touch_count = 0
	self._touch_order = 0
	self._pinching = false
	self._pinch_a = nil :: InputObject?
	self._pinch_b = nil :: InputObject?
	self._pinch_dist = 0.0
	self._pinch_anchor = Vector3.zero
	self._released_owned = {} :: { [any]: boolean }
	self._mouse_pos = Vector2.new(-1, -1)
	self._mouse_inside = true
	self._hover_tile = -1
	-- Pointer-over-HUD test (Godot: Controls with MOUSE_FILTER_STOP swallow mouse motion, so the
	-- globe never hovers under a panel). Cached per pointer position, re-tested every GUI_PROBE_S.
	self._player_gui = nil :: PlayerGui?
	self._gui_probe_pos = Vector2.new(-1e9, -1e9)
	self._gui_probe_t = -1e9
	self._gui_probe_hit = false
	self._conns = {} :: { RBXScriptConnection }
	self:_connect()
	return self
end

function MapInput.destroy(self: any)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
end

function MapInput.reset(self: any)
	self:_cancel_press()
	self:_forget_touches()
	table.clear(self._released_owned)
	self:set_hover_tile(-1)
end

-- drop every tracked touch and any two-finger gesture (the fingers still down are not ours anymore:
-- their moves and lifts are ignored)
function MapInput._forget_touches(self: any)
	table.clear(self._touches)
	self._touch_count = 0
	self._pinching = false
	self._pinch_a = nil
	self._pinch_b = nil
end

--- The window lost focus / the Roblox menu opened: touch ends may never arrive, a held mouse button
--- may be released elsewhere — cancel the gesture and forget every touch (R2-6).
function MapInput._on_focus_lost(self: any)
	if self._press_active or self._pinching then
		self:_cancel_press()
		self.rig:halt()
	end
	self._press_active = false
	self:_forget_touches()
	self:mouse_left_window()
end

--- Drop tracked touches that ended without an InputEnded (their InputObject says End / Cancel and
--- nothing arrived for `end_grace_s`: the InputEnded of a normal lift is being delivered), and with
--- `stale_s`, those without any update for that long. Returns how many were dropped.
function MapInput._prune_touches(self: any, stale_s: number?, end_grace_s: number?): number
	if self._touch_count == 0 then
		return 0
	end
	local now = os.clock()
	local grace = end_grace_s or 0
	local drop = nil
	for io, t in self._touches do
		local st = (io :: any).UserInputState
		local age = now - t.t
		if (IS_END[st] and age >= grace) or (stale_s ~= nil and age > stale_s) then
			drop = drop or {}
			table.insert(drop, io)
		end
	end
	if drop == nil then
		return 0
	end
	for _, io in drop do
		self.stats.stale_touches += 1
		self:_drop_touch(io)
	end
	return #drop
end

-- forget one touch as if it had been cancelled: no tap / click, a pinch it was part of ends
function MapInput._drop_touch(self: any, io: any)
	if self._touches[io] == nil then
		return
	end
	self._touches[io] = nil
	self._touch_count -= 1
	if self._pinching and (io == self._pinch_a or io == self._pinch_b) then
		self._pinching = false
	end
	if self._press_active and self._press_index == io then
		self:_cancel_press()
	end
	if self._touch_count == 0 then
		self._press_active = false
	end
end

--- True while the view owns touch `io` (a globe gesture or a pinch participant), and during the
--- frame in which such a finger lifts. `io` may be the touch's InputObject.
function MapInput.touch_owned_by_world(self: any, io: any): boolean
	local r = self._released_owned[io]
	if r ~= nil then
		return r
	end
	local t = self._touches[io]
	if t == nil then
		return false
	end
	return t.owner == GLOBE or (self._pinching and (io == self._pinch_a or io == self._pinch_b))
end

function MapInput._active(self: any): boolean
	return self.view.input_enabled and not self.view:is_attract()
end

-- ---------------------------------------------------------------------------------------------
-- Per-frame work (called by WorldView.update)
-- ---------------------------------------------------------------------------------------------

--- Input switched off (modal UI / attract): cancel the gesture cleanly, stop hover once. Tracked
--- touches are forgotten (the fingers still down belong to the UI now; their lifts are ignored).
function MapInput.disable(self: any)
	if self._press_active or self._pinching then
		self:_cancel_press()
		self.rig:halt()
		self._press_consumed = true
	end
	self:_forget_touches()
	self:set_hover_tile(-1)
end

--- Input switched back on: start from a clean gesture state (no touch tracked from before).
function MapInput.enable(self: any)
	self:_cancel_press()
	self:_forget_touches()
end

function MapInput.tick(self: any, delta: number)
	self.stats.ticks += 1
	table.clear(self._released_owned)
	if self._touch_count > 0 then
		self:_prune_touches(nil, 0.3)
	end
	if not self:_active() then
		-- the input_enabled field may also be flipped directly: same clean cancel
		if self._press_active or self._hover_tile ~= -1 then
			self:disable()
		end
		return
	end
	if
		self._press_active
		and not self._press_dragging
		and not self._press_consumed
		and now_ms() - self._press_ms >= MapInput.LONG_PRESS_MS
	then
		self._press_consumed = true
		self.view.tile_context:Fire(self.view:tile_at_screen(self._press_pos), self._press_pos)
	end
	self:_keyboard(delta)
	if self._touch_count == 0 and not self._press_dragging then
		local mp = UserInputService:GetMouseLocation()
		local vp = self.rig:viewport_size()
		local inside = UserInputService.MouseEnabled and mp.X >= 0 and mp.Y >= 0 and mp.X < vp.X and mp.Y < vp.Y
		if inside and self._mouse_inside and not self:pointer_over_gui(mp) then
			self._mouse_pos = mp
			self:set_hover_tile(self.view:tile_at_screen(mp))
		else
			self:set_hover_tile(-1)
		end
	end
end

--- True while the pointer (viewport px) rests on a visible input-blocking GUI element (an Active
--- GuiObject: HUD panels, buttons, cards, top-bar buttons) — the globe does not hover under it.
--- Map labels and other passive overlays are not Active and never block.
function MapInput.pointer_over_gui(self: any, mp: Vector2): boolean
	local now = os.clock()
	if mp == self._gui_probe_pos and now - self._gui_probe_t < MapInput.GUI_PROBE_S then
		return self._gui_probe_hit
	end
	self._gui_probe_pos = mp
	self._gui_probe_t = now
	local pg = self._player_gui
	if pg == nil or pg.Parent == nil then
		local lp = Players.LocalPlayer
		pg = if lp ~= nil then lp:FindFirstChildOfClass("PlayerGui") else nil
		self._player_gui = pg
	end
	local hit = false
	if pg ~= nil then
		-- GetGuiObjectsAtPosition works in GuiObject.AbsolutePosition space (below the top-bar inset).
		local inset = GuiService:GetGuiInset()
		for _, g in pg:GetGuiObjectsAtPosition(mp.X - inset.X, mp.Y - inset.Y) do
			if g.Active then
				hit = true
				break
			end
		end
	end
	self._gui_probe_hit = hit
	return hit
end

function MapInput.set_hover_tile(self: any, tile: number)
	if tile ~= self._hover_tile then
		self._hover_tile = tile
		self.view.tile_hovered:Fire(tile)
	end
end

function MapInput.mouse_left_window(self: any)
	self._mouse_inside = false
	self:set_hover_tile(-1)
end

function MapInput.mouse_entered_window(self: any)
	self._mouse_inside = true
end

local KC = Enum.KeyCode
function MapInput._keyboard(self: any, delta: number)
	if UserInputService:GetFocusedTextBox() ~= nil or not UserInputService.KeyboardEnabled then
		return
	end
	local function down(a: Enum.KeyCode, b: Enum.KeyCode?): boolean
		return UserInputService:IsKeyDown(a) or (b ~= nil and UserInputService:IsKeyDown(b))
	end
	local dx, dy = 0, 0
	if down(KC.A, KC.Left) then
		dx -= 1
	end
	if down(KC.D, KC.Right) then
		dx += 1
	end
	if down(KC.W, KC.Up) then
		dy -= 1
	end
	if down(KC.S, KC.Down) then
		dy += 1
	end
	if dx ~= 0 or dy ~= 0 then
		self.rig:pan(Vector2.new(dx, dy).Unit, MapInput.KEY_PAN_SPEED * delta)
	end
	local z = 0
	if down(KC.Equals, KC.KeypadPlus) then
		z += 1
	end
	if down(KC.Minus, KC.KeypadMinus) then
		z -= 1
	end
	if z ~= 0 then
		self.rig:zoom_by(2 ^ (z * MapInput.KEY_ZOOM_SPEED * delta))
	end
end

-- ---------------------------------------------------------------------------------------------
-- Event plumbing
-- ---------------------------------------------------------------------------------------------

function MapInput._connect(self: any)
	local UT = Enum.UserInputType
	table.insert(
		self._conns,
		UserInputService.InputBegan:Connect(function(io: InputObject, gp: boolean)
			if io.UserInputType == UT.Touch then
				if self:_active() then
					self:_touch_down(io, gp)
				end
				return
			end
			if not self:_active() then
				return
			end
			if io.UserInputType == UT.MouseButton1 then
				if gp or UserInputService.TouchEnabled and self._touch_count > 0 then
					return
				end
				local pos = view_pos(io)
				self._mouse_pos = pos
				self.stats.mouse_presses += 1
				self:_pointer_down(MOUSE, pos, TAP_SLOP_MOUSE)
			elseif io.UserInputType == UT.MouseButton2 then
				if gp then
					return
				end
				local pos = view_pos(io)
				self:_cancel_press()
				self.view.tile_context:Fire(self.view:tile_at_screen(pos), pos)
			end
		end)
	)
	table.insert(
		self._conns,
		UserInputService.InputChanged:Connect(function(io: InputObject, gp: boolean)
			if io.UserInputType == UT.Touch then
				if self:_active() then
					self:_touch_drag(io)
				end
				return
			end
			if not self:_active() then
				return
			end
			if io.UserInputType == UT.MouseMovement then
				local pos = view_pos(io)
				local rel = pos - self._mouse_pos
				self._mouse_pos = pos
				self._mouse_inside = true
				if self._press_active and self._press_index == MOUSE then
					self:_pointer_move(pos, rel)
				end
			elseif io.UserInputType == UT.MouseWheel then
				-- Shift + wheel belongs to the UI (attack ratio)
				if
					gp
					or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
				then
					return
				end
				local pos = view_pos(io)
				local k = MapInput.WHEEL_STEP ^ math.abs(io.Position.Z)
				self.rig:zoom_by(if io.Position.Z > 0 then k else 1 / k, self.rig:globe_hit(pos))
			end
		end)
	)
	table.insert(
		self._conns,
		UserInputService.InputEnded:Connect(function(io: InputObject, _gp: boolean)
			if io.UserInputType == UT.Touch then
				self:_touch_up(io)
				return
			end
			if io.UserInputType == UT.MouseButton1 then
				if self._press_active and self._press_index == MOUSE then
					self:_pointer_up(view_pos(io))
				end
			end
		end)
	)
	-- trackpad pinch / two-finger pan (InputEventMagnifyGesture / InputEventPanGesture)
	table.insert(
		self._conns,
		UserInputService.PointerAction:Connect(function(_wheel: number, pan: Vector2, pinch: number, gp: boolean)
			if gp or not self:_active() then
				return
			end
			local anchor = self.rig:globe_hit(UserInputService:GetMouseLocation())
			if pinch ~= 0 then
				self.rig:zoom_by(1 + pinch, anchor)
			elseif pan.Y ~= 0 then
				self.rig:zoom_by(1.035 ^ -pan.Y, anchor)
			end
		end)
	)
	table.insert(
		self._conns,
		UserInputService.WindowFocusReleased:Connect(function()
			self:_on_focus_lost()
		end)
	)
	-- the Roblox menu takes every finger / the mouse: a gesture in flight never ends on the globe
	table.insert(
		self._conns,
		GuiService.MenuOpened:Connect(function()
			self:_on_focus_lost()
		end)
	)
	table.insert(
		self._conns,
		UserInputService.WindowFocused:Connect(function()
			self:mouse_entered_window()
		end)
	)
end

-- ---------------------------------------------------------------------------------------------
-- Touch tracking
-- ---------------------------------------------------------------------------------------------

function MapInput._touch_down(self: any, io: InputObject, gp: boolean)
	if self._touches[io] ~= nil then
		return -- repeated press
	end
	-- a new finger: touches whose End / Cancel was missed never count. Age alone (no InputChanged
	-- for STALE_TOUCH_S) only evicts when the new finger would otherwise be refused: Roblox reports
	-- nothing for a finger held still, so a resting thumb must survive a second finger landing
	-- (review_code R3-1), while two lost touches still cannot lock every later touch out.
	self:_prune_touches(nil)
	if self._touch_count >= 2 then
		self:_prune_touches(MapInput.STALE_TOUCH_S)
	end
	if self._touch_count >= 2 then
		return -- a third finger: ignore
	end
	self._touch_order += 1
	local pos = view_pos(io)
	local t: Touch = {
		io = io,
		pos = pos,
		pair_pos = pos,
		owner = if gp then UI else GLOBE,
		order = self._touch_order,
		t = os.clock(),
	}
	self._touches[io] = t
	self._touch_count += 1
	self.stats.touch_presses += 1
	if self._touch_count == 2 then
		-- a second finger: no orbit, no inertia, no tap from here on
		self:_cancel_press()
		self._press_consumed = true
		self.rig:halt()
		for _, o in self._touches do
			o.pair_pos = o.pos
		end
	end
	if t.owner == GLOBE then
		self:_touch_on_globe(t)
	end
end

function MapInput._other(self: any, io: InputObject): Touch?
	for k, o in self._touches do
		if k ~= io then
			return o
		end
	end
	return nil
end

--- A touch press that the GUI did not process: the finger is on free globe.
function MapInput._touch_on_globe(self: any, t: Touch)
	if self._touch_count == 1 then
		self:_pointer_down(t.io, t.pos, TAP_SLOP_TOUCH)
		return
	end
	local other = self:_other(t.io)
	if other ~= nil and other.owner == GLOBE then
		self:_start_pinch() -- both fingers on the globe: pinch at once
	elseif other ~= nil and not self._press_active then
		-- the other finger rests on the HUD: this one runs a one-finger gesture (no tap until the
		-- pairing ends, so a HUD thumb can't turn into a pinch-tap)
		self:_pointer_down(t.io, t.pos, TAP_SLOP_TOUCH)
	end
end

function MapInput._touch_up(self: any, io: InputObject)
	local t = self._touches[io]
	if t == nil then
		return
	end
	local owned = self:touch_owned_by_world(io)
	self._released_owned[io] = owned
	self._touches[io] = nil
	self._touch_count -= 1
	if self._pinching and (io == self._pinch_a or io == self._pinch_b) then
		self._pinching = false
	end
	if not self:_active() then
		self:_cancel_press()
		return
	end
	if self._touch_count == 0 then
		if self._press_active and self._press_index == io then
			self:_pointer_up(view_pos(io))
		end
		self._press_active = false
		return
	end
	-- one finger remains: if it is on the globe it may orbit after moving, but never taps
	local rest = self:_other(io)
	self:_cancel_press()
	if rest ~= nil and rest.owner == GLOBE then
		self:_pointer_down(rest.io, rest.pos, TAP_SLOP_TOUCH)
		self._press_consumed = true
	end
end

function MapInput._touch_drag(self: any, io: InputObject)
	local t = self._touches[io]
	if t == nil then
		return
	end
	local pos = view_pos(io)
	local rel = pos - t.pos
	t.pos = pos
	t.t = os.clock()
	if self._pinching then
		self:_pinch_update()
		return
	end
	if self._touch_count == 2 then
		local other = self:_other(io) :: Touch
		local mixed = t.owner ~= GLOBE or other.owner ~= GLOBE
		if
			mixed
			and (t.pos - t.pair_pos).Magnitude >= MapInput.PINCH_MOVE_PX
			and (other.pos - other.pair_pos).Magnitude >= MapInput.PINCH_MOVE_PX
		then
			self:_start_pinch()
		end
		return -- a globe finger during a two-finger touch never orbits
	end
	if t.owner == GLOBE and self._press_active and self._press_index == io then
		self:_pointer_move(pos, rel)
	end
end

function MapInput._start_pinch(self: any)
	local a, b = nil :: Touch?, nil :: Touch?
	for _, o in self._touches do
		if a == nil or o.order < a.order then
			b = a
			a = o
		else
			b = o
		end
	end
	if a == nil or b == nil then
		return
	end
	self._pinching = true
	self._pinch_a = a.io
	self._pinch_b = b.io
	self._pinch_dist = (a.pos - b.pos).Magnitude
	self._pinch_anchor = self.rig:globe_hit((a.pos + b.pos) * 0.5)
	self:_cancel_press()
	self._press_consumed = true
	self.rig:halt()
	self.stats.pinches += 1
end

function MapInput._pinch_update(self: any)
	local a = self._touches[self._pinch_a]
	local b = self._touches[self._pinch_b]
	if a == nil or b == nil then
		return
	end
	local d = (a.pos - b.pos).Magnitude
	if self._pinch_dist > 1.0 and d > 1.0 then
		self.rig:zoom_by(d / self._pinch_dist, self._pinch_anchor)
	end
	self._pinch_dist = d
end

-- ---------------------------------------------------------------------------------------------
-- One-pointer gesture (mouse or a single globe finger)
-- ---------------------------------------------------------------------------------------------

function MapInput._pointer_down(self: any, index: any, pos: Vector2, slop: number)
	local moving = self.rig:is_moving(MapInput.STOP_PX_PER_S)
	self.rig:halt()
	self._press_active = true
	self._press_index = index
	self._press_pos = pos
	self._press_ms = now_ms()
	self._press_dragging = false
	self._press_consumed = false
	self._press_stop = moving -- a "stop" press: halts the globe, never taps (it may still be held)
	self._press_slop = slop
	if moving then
		self.stats.stop_presses += 1
	end
end

function MapInput._pointer_move(self: any, pos: Vector2, rel: Vector2)
	if not self._press_dragging then
		if (pos - self._press_pos).Magnitude <= self._press_slop then
			return
		end
		self._press_dragging = true
		self.rig:begin_drag()
		self:set_hover_tile(-1)
		rel = pos - self._press_pos
	end
	self.rig:drag_by(rel)
end

function MapInput._pointer_up(self: any, pos: Vector2)
	if not self._press_active then
		return
	end
	self._press_active = false
	if self._press_dragging then
		self._press_dragging = false
		self.rig:end_drag()
		return
	end
	if self._press_consumed or self._press_stop then
		return
	end
	local tile = self.view:tile_at_screen(pos)
	if tile >= 0 then
		self.view.tile_clicked:Fire(tile)
	end
end

--- A finger held still on the map (viewport px) and how far along the long-press it is (0..1); nil
--- when no touch hold runs.
function MapInput.hold_state(self: any): (Vector2?, number)
	if
		not self._press_active
		or self._press_dragging
		or self._press_consumed
		or self._press_index == MOUSE
		or not self:_active()
	then
		return nil, 0
	end
	return self._press_pos, math.clamp((now_ms() - self._press_ms) / MapInput.LONG_PRESS_MS, 0, 1)
end

function MapInput._cancel_press(self: any)
	if self._press_dragging then
		self.rig:end_drag()
		self.rig:halt()
	end
	self._press_active = false
	self._press_dragging = false
end

--- Test hooks: synthesise pointer events (viewport px) through the same paths.
function MapInput.debug_pointer(self: any, what: string, pos: Vector2)
	if what == "down" then
		self:_pointer_down(MOUSE, pos, TAP_SLOP_MOUSE)
	elseif what == "move" then
		local rel = pos - self._mouse_pos
		self._mouse_pos = pos
		if self._press_active then
			self:_pointer_move(pos, rel)
		end
	elseif what == "up" then
		self:_pointer_up(pos)
	end
end

return MapInput
