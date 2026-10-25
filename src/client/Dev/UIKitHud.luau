--!nonstrict
-- ui-kit dev harness: the in-game HUD (command bar, top status, leaderboard, attacks, event feed,
-- nuke alert) over a still of the original's globe, driven by a real GameState built from mock
-- data (Dev/UIKitMock.luau = tests/ui_mock_state.gd). Lays the panels out like ui_root.gd.
--
-- workspace attributes (set in Edit mode before Play):
--   UIKIT_BACKDROP  "europe" (default) | "globe" | "plain"
--   UIKIT_VIEW      "" (full viewport) | "phone" (844x390 frame, insets 47,0,47,21, touch) |
--                   "laptop" (1280x720 frame) | "desktop" (1600x900 frame)
--   UIKIT_SCALE     number: force the UI scale (0 = automatic)
--   UIKIT_TOUCH     bool: touch mode
--   UIKIT_SCENE     "hud" (default) | "placing" | "tray" | "intercept"
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UI = script.Parent.Parent:WaitForChild("UI")
local T = require(UI:WaitForChild("UITheme"))
local W = require(UI:WaitForChild("Widgets"))
local UICtx = require(UI:WaitForChild("UICtx"))
local TopStatus = require(UI:WaitForChild("TopStatus"))
local Leaderboard = require(UI:WaitForChild("Leaderboard"))
local EventFeed = require(UI:WaitForChild("EventFeed"))
local AttacksPanel = require(UI:WaitForChild("AttacksPanel"))
local CommandBar = require(UI:WaitForChild("CommandBar"))
local AlertBanner = require(UI:WaitForChild("AlertBanner"))
local Mock = require(script.Parent:WaitForChild("UIKitMock"))
local Defs = require(game:GetService("ReplicatedStorage").Airfront.Core.Defs)

local BACKDROPS = {
	europe = { "rbxassetid://112172595346580", "rbxassetid://111073447149561" },
	globe = { "rbxassetid://103323506509073", "rbxassetid://124385868395526" },
}

T.init()
local t0 = os.clock()
local st, by_name = Mock.make_state()
print(string.format("[UIKitHud] mock state built in %.2fs", os.clock() - t0))

local view = workspace:GetAttribute("UIKIT_VIEW") or ""
local scene = workspace:GetAttribute("UIKIT_SCENE") or "hud"
local force_scale = workspace:GetAttribute("UIKIT_SCALE") or 0
local touch = workspace:GetAttribute("UIKIT_TOUCH") == true or view == "phone"

local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
local sg = Instance.new("ScreenGui")
sg.Name = "UIKitHud"
sg.IgnoreGuiInset = true
sg.ScreenInsets = Enum.ScreenInsets.None
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.ResetOnSpawn = false
sg.DisplayOrder = 10
sg.Parent = pg

-- Stage: the whole viewport, or a fixed-size frame (phone / laptop / desktop) centred in it.
local stage = Instance.new("Frame")
stage.Name = "Stage"
stage.BorderSizePixel = 0
stage.BackgroundColor3 = Color3.fromRGB(4, 5, 16)
stage.ClipsDescendants = true
local sizes = { phone = Vector2.new(844, 390), laptop = Vector2.new(1280, 720), desktop = Vector2.new(1600, 900) }
if sizes[view] then
	-- a fixed logical viewport, rendered at UIKIT_SCALE (default 1)
	local k = if force_scale > 0 then force_scale else 1
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromScale(0.5, 0.5)
	stage.Size = UDim2.fromOffset(math.floor(sizes[view].X * k + 0.5), math.floor(sizes[view].Y * k + 0.5))
else
	stage.Size = UDim2.fromScale(1, 1)
end
stage.Parent = sg

local bdname = workspace:GetAttribute("UIKIT_BACKDROP") or "europe"
local bd = BACKDROPS[bdname]
if bd then
	for i = 1, 2 do
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.BorderSizePixel = 0
		img.Image = bd[i]
		img.ScaleType = Enum.ScaleType.Stretch
		img.Size = UDim2.fromScale(0.5, 1)
		img.Position = UDim2.fromScale((i - 1) * 0.5, 0)
		img.ZIndex = 0
		img.Parent = stage
	end
end

-- calibration markers (pure magenta 4x4 px at the stage's corners) for capture alignment
if workspace:GetAttribute("UIKIT_MARKERS") ~= false then
	for i, pos in ipairs({ UDim2.fromOffset(0, 0), UDim2.new(1, -4, 1, -4) }) do
		local mk = Instance.new("Frame")
		mk.Name = "Marker" .. i
		mk.BorderSizePixel = 0
		mk.BackgroundColor3 = Color3.fromRGB(255, 0, 255)
		mk.Size = UDim2.fromOffset(4, 4)
		mk.Position = pos
		mk.ZIndex = 1000
		mk.Parent = stage
	end
end

local root = W.Root.new(
	stage,
	{ scale = if force_scale > 0 then force_scale else (if sizes[view] then 1.0 else nil), touch_device = touch }
)

local ctx = UICtx.new()
ctx.session = Mock.session(st)
ctx.world = Mock.world()
ctx.state = st
ctx.state_mode = 1
ctx.play_start_tick = 0
ctx.touch = touch
ctx.touch_device = touch
if view == "phone" then
	ctx.insets = { x = 47, y = 0, z = 47, w = 21 }
end
ctx.borders:bind(st, st.local_owner)
ctx.rules:recount()

local hud = W.Control.new()
hud:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
hud:set_mouse_filter(W.MOUSE_IGNORE)
root:add_child(hud)

local top = TopStatus.new(ctx)
hud:add_child(top)
local board = Leaderboard.new(ctx)
top.rank_provider = function()
	return board:my_rank()
end
hud:add_child(board)
local feed = EventFeed.new(ctx)
hud:add_child(feed)
local attacks = AttacksPanel.new(ctx)
hud:add_child(attacks)
local bar = CommandBar.new(ctx)
hud:add_child(bar)
local alert = AlertBanner.new(ctx)
hud:add_child(alert)
local floats = W.Control.new()
floats:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
floats:set_mouse_filter(W.MOUSE_IGNORE)
root:add_child(floats)

bar.build_chosen:Connect(function(kind)
	local b = bar:button(kind)
	if b and not b:is_available() then
		b:deny()
		local FT = require(UI:WaitForChild("FloatText"))
		local r = b:get_global_rect()
		FT.spawn(floats, Vector2.new((r.Min.X + r.Max.X) / 2, r.Min.Y), b:reason(), "info", T.RED)
		return
	end
	bar:set_placing(if bar._placing == kind then "" else kind)
end)
bar.cancel_placement:Connect(function()
	bar:set_placing("")
end)
board.toggled:Connect(function()
	W.defer(function()
		_G.UIKIT_LAYOUT()
	end)
end)

local function enforce_min_font(n)
	if n.base_fs ~= nil and n.set_font_size then
		n:set_font_size(math.max(n.base_fs, T.min_font_size))
	end
	for _, c in ipairs(n.children) do
		enforce_min_font(c)
	end
end

-- ui_root.gd _layout()
local function layout()
	local vp = root.vp
	ctx.vp = vp
	ctx.compact = vp.Y < 560 or vp.X < 900
	ctx.wide = vp.X >= 1420
	T.min_font_size = if ctx.touch then 12 else 0
	top:apply_layout()
	bar:apply_layout()
	local board_top = 12.0 + ctx.insets.y
	local board_w = if ctx.compact then 250.0 else 300.0
	local board_left = vp.X - 12.0 - ctx.insets.z - board_w
	if top.visible then
		local r = top.panel:get_global_rect()
		if r.Max.X + 12.0 > board_left then
			board_top = math.max(board_top, r.Max.Y + 10.0)
		end
	end
	board:apply_layout(board_top)
	if ctx.compact and top.visible and not board.expanded then
		local tr = top.panel:get_global_rect()
		local pill_w = board._pill:get_combined_minimum_size().X
		local min_x = if tr.Min.Y >= ctx.reserved_top_left.Max.Y
			then ctx.insets.x + 8.0
			else ctx.reserved_top_left.Max.X + 8.0
		if tr.Min.X - 8.0 - pill_w >= min_x then
			board:place_pill_left_of(tr)
		end
	end
	local attacks_top = math.max(board:bottom_edge(), if top.visible then top:bottom_edge() else 0.0) + 10.0
	attacks.tray_open = bar.tray.visible
	attacks:apply_layout(attacks_top, (if bar.visible then bar:top_edge() else vp.Y - ctx.insets.w) - 8.0)
	attacks:refresh()
	local bar_top = if bar.visible then bar:top_edge() else vp.Y - ctx.insets.w
	feed:apply_layout(bar_top - 12.0)
	if ctx.compact then
		alert:apply_layout(top.panel.offset_top, 8.0 + ctx.insets.z)
	else
		alert:apply_layout(top:bottom_edge() + 10.0)
	end
	if T.min_font_size > 0 then
		enforce_min_font(root)
	end
end
_G.UIKIT_LAYOUT = layout
_G.UIKIT = {
	root = root,
	ctx = ctx,
	top = top,
	board = board,
	feed = feed,
	attacks = attacks,
	bar = bar,
	alert = alert,
	state = st,
}
-- Debug report for the Studio MCP (execute_luau runs in another Lua state):
-- game.ReplicatedStorage.UIKitReport:Invoke() -> text with the logical rects of the main parts.
do
	local bf = Instance.new("BindableFunction")
	bf.Name = "UIKitReport"
	bf.OnInvoke = function(what)
		local out = {}
		local function r(name, n)
			local g = n:get_global_rect()
			table.insert(
				out,
				string.format("%-14s x=%.1f y=%.1f w=%.1f h=%.1f", name, g.Min.X, g.Min.Y, g.Width, g.Height)
			)
		end
		r("bar.panel", bar.panel)
		for _, k in ipairs({
			"_nation",
			"_troops_box",
			"_gold_box",
			"_ratio_box",
			"_builds",
			"_troops",
			"_troops_cap",
			"_growth",
			"_name",
			"_land",
			"_gold",
			"_income",
			"_ratio_pct",
			"_slider",
			"_ratio_sub",
		}) do
			r(k, bar[k])
		end
		r("top.panel", top.panel)
		for _, k in ipairs({ "_phase", "_clock", "_bar", "_you", "_lead", "_head" }) do
			r("top" .. k, top[k])
		end
		r("board.panel", board.panel)
		r("board.row1", board._rows[1])
		if board._pins[1] then
			r("board.pin", board._pins[1])
		end
		r("attacks.panel", attacks.panel)
		r("feed.stack", feed._stack)
		for i, c in ipairs(feed._stack.children) do
			r("feed." .. i, c)
		end
		r("alert.panel", alert.panel)
		table.insert(out, _G.UIKIT_PERF())
		return table.concat(out, "\n")
	end
	bf.Parent = game:GetService("ReplicatedStorage")
end

root.resized:Connect(function()
	W.defer(layout)
end)
bar.footprint_changed:Connect(function()
	W.defer(layout)
end)

layout()
top:on_bind()
bar:reset_rate()
bar:refresh(false)
board:refresh()
top:refresh()
layout()

-- Event feed as in the original's "hud" capture (oldest first).
-- (UIKIT_FREEZE: keep them up and the clock still, for side-by-side captures)
local freeze = workspace:GetAttribute("UIKIT_FREEZE") ~= false
local life = if freeze then 3600 else nil
feed:toast(Defs.MSG_GOOD, "Your transport landed in Sweden", "crown", life)
feed:toast(Defs.MSG_INFO, "France was eliminated by Spain", nil, life)
feed:toast(Defs.MSG_BAD, "Ukraine captured your Port", "attack", life)
feed:toast(Defs.MSG_ALERT, "Belarus (11.4K) is attacking you!", "attack", life)
feed:alliance_request(by_name["Italy"])
if workspace:GetAttribute("UIKIT_NUKE") ~= false then
	alert:track(900)
end
layout()

if scene == "placing" then
	bar:set_placing("city")
elseif scene == "tray" then
	bar:set_tray(true)
elseif scene == "motion" then
	-- slow-motion entrances (6 s) to inspect text stability while scaling
	task.delay(tonumber(workspace:GetAttribute("UIKIT_MOTION_DELAY")) or 2, function()
		print("[UIKitHud] motion start", os.clock())
		for _, c in ipairs(feed._stack.children) do
			W.pop_in(c, 0.0, 0.8, 12.0)
		end
		W.pop_in(board.panel, 0.0, 0.8, 12.0)
		W.pop_in(alert.panel, 0.0, 1.3, 12.0)
	end)
elseif scene == "moments" then
	-- Banner, busy chip, float text, green intercepted alert
	local Banner = require(UI:WaitForChild("Banner"))
	local BusyChip = require(UI:WaitForChild("BusyChip"))
	local FT = require(UI:WaitForChild("FloatText"))
	local busy = BusyChip.new(ctx)
	root:add_child(busy)
	task.delay(1.0, function()
		hud:add_child(Banner.make(ctx, "THE WAR BEGINS", "Nations will now attack each other", T.AMBER, 30.0))
		busy:show_text("Deploying a new world…")
		alert:resolve(900, true)
		alert._green = 1000 -- hold the green state for the capture
		while true do
			FT.spawn(floats, Vector2.new(800, 640), "Attacking Brazil with 24.5K", "attack", T.AMBER)
			task.wait(0.6)
		end
	end)
elseif scene == "grace" then
	-- early game: the "PROTECTED m:ss" countdown replaces the phase caption
	ctx.play_start_tick = st.tick - 100
	top:refresh()
elseif scene == "board" then
	board:set_open(true)
	layout()
elseif scene == "intercept" then
	task.delay(1.0, function()
		alert:resolve(900, true)
	end)
end

-- Mock session: advance the mirror at 10 Hz (render_tick smooth), drive the components.
local acc = 0.0
local upd_ms, upd_max = 0.0, 0.0
RunService.RenderStepped:Connect(function(dt)
	local t0 = os.clock()
	acc += if freeze then 0 else dt
	while acc >= 0.1 do
		acc -= 0.1
		st:apply_delta({ t = st.tick + 1 })
	end
	st.render_tick = st.tick + acc * 10.0
	top:update(dt)
	board:update(dt)
	attacks:update(dt)
	bar:update(dt)
	feed:update(dt)
	alert:update(dt)
	local ms = (os.clock() - t0) * 1000.0
	upd_ms = upd_ms + (ms - upd_ms) * 0.05
	upd_max = math.max(upd_max * 0.995, ms)
end)
_G.UIKIT_PERF = function()
	return string.format(
		"components update %.3f ms (max %.2f) | kit step %.3f ms (max %.2f)",
		upd_ms,
		upd_max,
		W.stats.step_ms,
		W.stats.max_ms
	)
end

-- Stats wobble so the count labels roll (like the original's stats deltas).
if workspace:GetAttribute("UIKIT_WOBBLE") then
	task.spawn(function()
		local me = st.local_owner
		while true do
			task.wait(1.5)
			local o = st.owners[me]
			if o then
				o.troops = math.min(o.max_troops, o.troops + 4500)
				o.gold += 5100
				st.stats_changed:Fire()
				bar:refresh()
			end
		end
	end)
end

print("[UIKitHud] ready; scale", T.scale, "vp", root.vp, "compact", ctx.compact, "wide", ctx.wide)
return nil
