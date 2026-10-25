--!nonstrict
-- Port of scripts/ui/ui_layout_probe.gd (UILayoutProbe)
-- Layout helpers for UIRoot: measures the platform's own HUD (the Roblox top bar row with Main's
-- top-bar buttons, the chat window) so our panels stay clear of it, reads the device safe area,
-- tells the globe which part of the screen is HUD-free, and enforces the 12 px text minimum on
-- touch screens.
--
-- Airship -> Roblox: Airship's top bar = the Roblox top bar row (GuiService.TopbarInset: Roblox's
-- own buttons sit left of TopbarInset.Min.X, Main's buttons start there); the Airship chat panel
-- = the TextChatService chat window (ChatWindowConfiguration.AbsolutePosition / AbsoluteSize).

local UICtx = require("./UICtx")

local UILayoutProbe = {}
UILayoutProbe.__index = UILayoutProbe

function UILayoutProbe.new(root: any)
	local self = setmetatable({}, UILayoutProbe)
	self.ui = root
	self._safe_gui = nil
	return self
end

local function to_logical_rect(ctx: any, r: Rect): Rect
	return ctx:rect_to_logical(r)
end

--- Device safe-area insets (logical px): left, top, right, bottom. A hidden probe ScreenGui with
--- ScreenInsets = DeviceSafeInsets covers exactly the safe area.
function UILayoutProbe.safe_insets(self): any
	local ui = self.ui
	if not UICtx.IS_ROBLOX then
		return { x = 0, y = 0, z = 0, w = 0 }
	end
	if self._safe_gui == nil then
		local lp = game:GetService("Players").LocalPlayer
		local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
		if pg == nil then
			return { x = 0, y = 0, z = 0, w = 0 }
		end
		local sg = Instance.new("ScreenGui")
		sg.Name = "AirfrontSafeAreaProbe"
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
		sg.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
		sg.DisplayOrder = -100
		local f = Instance.new("Frame")
		f.BackgroundTransparency = 1
		f.Size = UDim2.fromScale(1, 1)
		f.Parent = sg
		sg.Parent = pg
		self._safe_gui = f
	end
	local f = self._safe_gui
	-- Compare the safe-area frame with our full-screen UI root (same AbsolutePosition space).
	local root = ui.root and ui.root.gui
	if root == nil then
		return { x = 0, y = 0, z = 0, w = 0 }
	end
	local p, s = f.AbsolutePosition, f.AbsoluteSize
	local rp, rs = root.AbsolutePosition, root.AbsoluteSize
	if s.X <= 0 or s.Y <= 0 or rs.X <= 0 then
		return { x = 0, y = 0, z = 0, w = 0 }
	end
	local sc = require("./UITheme").scale
	local function q(v: number): number
		return math.max(0, math.floor(v / sc + 0.5))
	end
	return {
		x = q(p.X - rp.X),
		y = q(p.Y - rp.Y),
		z = q((rp.X + rs.X) - (p.X + s.X)),
		w = q((rp.Y + rs.Y) - (p.Y + s.Y)),
	}
end

--- Tell the globe which part of the screen is free of HUD so camera focus lands in its middle
--- (WorldView.set_safe_area, viewport px). Rect() on the title screen.
function UILayoutProbe.update_world_safe_area(self)
	local ui = self.ui
	local ctx = ui.ctx
	local r = Rect.new(0, 0, 0, 0)
	if ui._screen ~= "title" and ui._screen ~= "" and ui.hud.visible then
		local vp = ctx.vp
		local top_y = math.max(ctx.insets.y, ctx.airship_bar.Max.Y)
		for _, c in ipairs({ ui.top.panel, ui.spawn.panel }) do
			if c:is_visible_in_tree() then
				top_y = math.max(top_y, c:get_global_rect().Max.Y + 6.0)
			end
		end
		local bottom_y = vp.Y - ctx.insets.w
		-- (the bar itself: its build tray and placement chip float over the map like the right-side
		-- panels, so opening them never moves the camera)
		if ui.bar:is_visible_in_tree() then
			bottom_y = math.min(bottom_y, ui.bar:base_edge() - 6.0)
		end
		if ui.spectate_pill.visible and ui.spectate_pill:is_visible_in_tree() then
			bottom_y = math.min(bottom_y, ui.spectate_pill:get_global_rect().Min.Y - 6.0)
		end
		-- The right-side panels (leaderboard, attacks list) open and close on their own or at a key
		-- press; they float over the globe instead of narrowing this band, so toggling them never moves
		-- the camera. Map labels still keep clear of them (WorldView hud controls).
		local right_x = vp.X - ctx.insets.z
		local left_x = ctx.insets.x
		if bottom_y - top_y > 80.0 and right_x - left_x > 160.0 then
			r = Rect.new(left_x, top_y, right_x, bottom_y)
		end
	end
	if not UICtx.rect_equal_approx(r, ui._world_safe) then
		ui._world_safe = r
		ctx:world_call("set_safe_area", { if r.Width > 0 then ctx:rect_to_view(r) else Rect.new(0, 0, 0, 0) })
	end
end

--- The reserved top-left HUD (Roblox menu / chat buttons + Main's top-bar buttons, the chat window
--- when open), logical px. Falls back to conservative estimates.
function UILayoutProbe.airship_reserved(self): Rect
	local ui = self.ui
	local ctx = ui.ctx
	local bar_rect = self:airship_bar_rect()
	local chat = self:airship_chat_rect()
	ui._reserved_probe = bar_rect
	ui._chat_probe = chat
	local endv = if bar_rect.Width > 0
		then bar_rect.Max + Vector2.new(8, 8)
		else Vector2.new(ctx.insets.x + 350.0, ctx.insets.y + 58.0)
	ctx.airship_bar = Rect.new(0, 0, endv.X, endv.Y)
	if chat.Width > 0.0 then
		-- The chat window is open: keep clear of it too.
		local ce = chat.Max + Vector2.new(8, 8)
		return Rect.new(0, 0, math.max(endv.X, ce.X), math.max(endv.Y, ce.Y))
	end
	return Rect.new(0, 0, endv.X, endv.Y)
end

--- The chat window when it is open (desktop default), logical px; empty when hidden.
function UILayoutProbe.airship_chat_rect(self): Rect
	if not UICtx.IS_ROBLOX then
		return Rect.new(0, 0, 0, 0)
	end
	local ok, r = pcall(function()
		local tcs = game:GetService("TextChatService")
		local cfg = tcs:FindFirstChildOfClass("ChatWindowConfiguration")
		if cfg == nil or not cfg.Enabled then
			return nil
		end
		local active = true
		pcall(function()
			active = game:GetService("StarterGui"):GetCore("ChatActive")
		end)
		if not active then
			return nil
		end
		local p = cfg.AbsolutePosition
		local s = cfg.AbsoluteSize
		if s.X <= 0 or s.Y <= 0 then
			return nil
		end
		-- AbsolutePosition is relative to the inset area (below the top bar).
		local inset = game:GetService("GuiService"):GetGuiInset()
		return Rect.new(p.X + inset.X, p.Y + inset.Y, p.X + inset.X + s.X, p.Y + inset.Y + s.Y)
	end)
	if ok and r ~= nil then
		return to_logical_rect(self.ui.ctx, r)
	end
	return Rect.new(0, 0, 0, 0)
end

--- Phones: nothing below 12 px (labels and buttons whose sizes layouts set directly).
function UILayoutProbe.enforce_min_font(_self, n: any)
	local T = require("./UITheme")
	local minfs = T.min_font_size or 0
	local function rec(node)
		local fs = node.font_size or node._font_size
		if node.set_font_size and fs ~= nil and fs < minfs then
			node:set_font_size(minfs)
		end
		for _, ch in ipairs(node.children or {}) do
			rec(ch)
		end
	end
	rec(n)
end

function UILayoutProbe.airship_bar_moved(self): boolean
	local ui = self.ui
	return not UICtx.rect_equal_approx(self:airship_bar_rect(), ui._reserved_probe)
		or not UICtx.rect_equal_approx(self:airship_chat_rect(), ui._chat_probe)
end

--- The top bar row's occupied part (Roblox's buttons + Main's buttons), logical px. Main may set
--- `ui.topbar_provider` (function -> Rect in viewport px of its buttons); otherwise the Roblox
--- buttons alone (left of GuiService.TopbarInset).
function UILayoutProbe.airship_bar_rect(self): Rect
	if not UICtx.IS_ROBLOX then
		return Rect.new(0, 0, 0, 0)
	end
	local ui = self.ui
	local ti = game:GetService("GuiService").TopbarInset
	local h = ti.Max.Y
	if h <= 0 then
		return Rect.new(0, 0, 0, 0)
	end
	local right = ti.Min.X
	if ui.topbar_provider ~= nil then
		local ok, r = pcall(ui.topbar_provider)
		if ok and typeof(r) == "Rect" and r.Width > 0 then
			right = math.max(right, r.Max.X)
			h = math.max(h, r.Max.Y)
		end
	end
	return to_logical_rect(ui.ctx, Rect.new(0, 0, right, h))
end

return UILayoutProbe
