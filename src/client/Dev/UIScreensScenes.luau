--!nonstrict
-- ui-screens dev: named scenes for the UIScreensGame harness, invoked through the
-- PlayerGui.UIScreensBridge BindableFunction (see UIScreensGame). Each takes the harness table
-- {ui, session, world, audio, W} and returns a short status string.

local UI = script.Parent.Parent:WaitForChild("UI")
local UICtx = require(UI.UICtx)
local Defs = UICtx.core("Defs")
local Ev = UICtx.core("Ev")

local Scenes = {}

local function tile_at(ll_lat: number, ll_lon: number): number
	local x = math.floor(((ll_lon + 180) % 360) / 360 * Defs.W)
	local y = math.floor((90 - ll_lat) / 180 * Defs.H)
	return y * Defs.W + x
end

--- Nearest tile to (lat, lon) owned by `owner` (-1: any contestable land of that owner / 0 = unclaimed).
local function tile_of(h, owner: number, lat: number, lon: number): number
	local s = h.ui.ctx.state
	local c = tile_at(lat, lon)
	local cx, cy = c % Defs.W, c // Defs.W
	for r = 0, 60 do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local y = cy + dy
					if y >= 0 and y < Defs.H then
						local t = y * Defs.W + (cx + dx) % Defs.W
						if s.map:is_contestable(t) and s:tile_owner(t) == owner then
							return t
						end
					end
				end
			end
		end
	end
	return -1
end
Scenes._tile_of = tile_of

local function point(h, t: number): Vector2
	return h.ui.ctx:tile_screen_pos(t)
end

function Scenes.status(h)
	local ui = h.ui
	local ctx = ui.ctx
	local T = require(UI.UITheme)
	local s = ctx.state
	return string.format(
		"screen=%s mode=%d vp=%s scale=%.3f insets=%d,%d,%d,%d reserved=%s touch=%s compact=%s me=%d phase=%s tick=%s",
		ui:screen(),
		ctx:mode(),
		tostring(ctx.vp),
		T.scale,
		ctx.insets.x,
		ctx.insets.y,
		ctx.insets.z,
		ctx.insets.w,
		tostring(ctx.reserved_top_left),
		tostring(ctx.touch),
		tostring(ctx.compact),
		ctx:me(),
		if s then tostring(s.phase) else "-",
		if s then tostring(s.tick) else "-"
	)
end

function Scenes.solo(h, d)
	h.ui:_on_play_solo(tonumber(d) or 1)
	return "starting solo"
end

function Scenes.title(h)
	h.session:leave_match()
	return "leaving"
end

function Scenes.touch(h, on)
	h.ui.debug_touch = if on == nil then -1 else (if on then 1 else 0)
	h.ui:relayout()
	return "touch=" .. tostring(h.ui.ctx.touch)
end

function Scenes.focus(h, lat, lon)
	h.world:focus_tile(tile_at(lat, lon))
	return "ok"
end

--- Hover the nearest tile of `owner` near (lat, lon): the pointer moves there (debug mouse).
function Scenes.hover(h, owner, lat, lon)
	local ctx = h.ui.ctx
	local t = tile_of(h, owner, lat, lon)
	if t < 0 then
		return "no tile"
	end
	local p = point(h, t)
	ctx.debug_mouse = if p.X >= 0 then p else ctx.vp * 0.5
	h.ui.interact:on_hover(t)
	return string.format("hover %d at %s", t, tostring(p))
end

function Scenes.unhover(h)
	h.ui.ctx.debug_mouse = Vector2.new(-1, -1)
	h.ui.interact:on_hover(-1)
	h.ui.tooltip:hide_tip()
	return "ok"
end

function Scenes.click(h, owner, lat, lon)
	local t = tile_of(h, owner, lat, lon)
	if t < 0 then
		return "no tile"
	end
	local p = point(h, t)
	h.ui.ctx.debug_mouse = if p.X >= 0 then p else h.ui.ctx.vp * 0.5
	h.ui.interact._last_click_msec = -100000
	h.ui.interact:on_click(t)
	return "clicked " .. t
end

function Scenes.radial(h, owner, lat, lon, hover, sub)
	local ctx = h.ui.ctx
	local t = tile_of(h, owner, lat, lon)
	if t < 0 then
		return "no tile"
	end
	local p = point(h, t)
	ctx.debug_mouse = p
	h.ui.interact._last_ctx_msec = -100000
	h.ui.interact:on_context(t, p)
	local r = h.ui.radial
	if sub ~= nil then
		for _, it in ipairs(r.items) do
			if it.id == sub then
				r:_enter_sub(it)
				break
			end
		end
	end
	if hover ~= nil then
		task.delay(0.45, function()
			r._hover = hover
			r:_redraw()
		end)
	end
	local ids = {}
	for _, it in ipairs(r.items) do
		table.insert(ids, it.id)
	end
	return "radial " .. table.concat(ids, ",")
end

function Scenes.help(h)
	h.ui:toggle_help()
	return "help=" .. tostring(h.ui.help.is_open)
end

function Scenes.menu(h)
	h.ui:open_pause_menu()
	return "menu=" .. tostring(h.ui.pause.is_open)
end

function Scenes.escape(h)
	return tostring(h.ui.interact:escape())
end

function Scenes.select(h, kind)
	h.ui.interact:select_action(kind)
	return "aim=" .. h.ui.interact.aim_kind
end

function Scenes.inspect(h, owner, lat, lon)
	local t = tile_of(h, owner, lat, lon)
	h.ui.interact:show_inspect(t)
	return "inspect " .. t
end

function Scenes.target(h, owner, lat, lon)
	local ui = h.ui
	local t = tile_of(h, owner, lat, lon)
	local act = ui.ctx.rules:primary(t)
	ui.interact:_select(t, if owner == 0 then "boat" else "attack", act)
	return "target " .. t .. " " .. tostring(act.type)
end

function Scenes.ally_card(h, owner, lat, lon, betray)
	local ui = h.ui
	local t = tile_of(h, owner, lat, lon)
	ui.interact:_select(t, "ally", ui.ctx.rules:primary(t))
	if betray then
		ui.target_card:confirm_betray()
	end
	return "ally " .. t
end

--- Pretend we are allied with `id` (mirror only).
function Scenes.ally_with(h, id)
	local s = h.ui.ctx.state
	local me = s.local_owner
	s:apply_delta({ t = s.tick, ev = { { Ev.ALLY, me, id } } })
	return "allied " .. tostring(s:are_allies(me, id))
end

function Scenes.request_from(h, id)
	local s = h.ui.ctx.state
	s:apply_delta({ t = s.tick, ev = { { Ev.ALLY_REQ, id, s.local_owner } } })
	return "requested"
end

function Scenes.gold(h, amount)
	local s = h.ui.ctx.state
	local o = s:get_owner(s.local_owner)
	o.gold = amount
	h.ui.bar:refresh(false)
	return "gold " .. amount
end

function Scenes.message(h, cat, text)
	local s = h.ui.ctx.state
	s:apply_delta({ t = s.tick, ev = { { Ev.MSG, s.local_owner, cat, text } } })
	return "msg"
end

function Scenes.nuke_incoming(h, from_id)
	local s = h.ui.ctx.state
	local me = s.local_owner
	local to = s:label_tile(me)
	local from = s:label_tile(from_id)
	s:apply_delta({ t = s.tick, ev = { { Ev.NUKE, 900001, Defs.N_HYDROGEN, from_id, from, to, s.tick - 5, 80 } } })
	return "nuke"
end

function Scenes.game_over(h, winner, reason)
	local s = h.ui.ctx.state
	local w = if winner == "me" then s.local_owner else tonumber(winner) or 0
	s:apply_delta({ t = s.tick, ev = { { Ev.GAME_OVER, w, tonumber(reason) or Defs.OVER_DOMINATION } } })
	return "over"
end

function Scenes.eliminate(h, killer)
	local s = h.ui.ctx.state
	s:apply_delta({ t = s.tick, ev = { { Ev.OWNER_OUT, s.local_owner, tonumber(killer) or 0 } } })
	return "out"
end

function Scenes.coach(h, id)
	local ui = h.ui
	ui.coach:reset()
	ui.coach:offer(id or "expand", function()
		return ui.advisor:frontier_point()
	end)
	return "coach " .. tostring(ui.coach.current)
end

function Scenes.pause_sim(h, on)
	h.session:set_paused(on == true)
	return "paused " .. tostring(on)
end

function Scenes.owners_near(h, lat, lon)
	local s = h.ui.ctx.state
	local seen = {}
	local out = {}
	local c = tile_at(lat, lon)
	for dy = -20, 20, 2 do
		for dx = -30, 30, 2 do
			local t = (c // Defs.W + dy) * Defs.W + (c % Defs.W + dx) % Defs.W
			local o = s:tile_owner(t)
			if o ~= 0 and not seen[o] then
				seen[o] = true
				table.insert(out, o .. "=" .. s:owner_name(o))
			end
		end
	end
	return table.concat(out, " ")
end

--- Press a node button by dotted path under ui (e.g. "over._spec").
function Scenes.press(h, path)
	local v = h.ui
	for part in string.gmatch(path, "[^%.]+") do
		v = v[part]
	end
	v.pressed:Fire()
	return "pressed " .. path
end

--- Viewport px of the nearest tile of `owner` near (lat, lon): "x y".
function Scenes.where(h, owner, lat, lon)
	local t = tile_of(h, owner, lat, lon)
	local v = h.world:screen_pos_of_tile(t)
	return string.format("%d %d %d", math.floor(v.X + 0.5), math.floor(v.Y + 0.5), t)
end

--- Viewport-px centre of a node by dotted path under ui: "x y".
function Scenes.node_at(h, path)
	local v = h.ui
	for part in string.gmatch(path, "[^%.]+") do
		v = v[part]
	end
	local r = v:get_global_rect()
	local c = h.ui.ctx:to_view(Vector2.new((r.Min.X + r.Max.X) / 2, (r.Min.Y + r.Max.Y) / 2))
	return string.format("%d %d", math.floor(c.X + 0.5), math.floor(c.Y + 0.5))
end

function Scenes.mp_status(h, st)
	h.session.multiplayer_status = function()
		return st
	end
	return "mp " .. st
end

function Scenes.intents(h, n)
	local log = h.ui.ctx.sent_log
	local out = {}
	for i = math.max(1, #log - (tonumber(n) or 5) + 1), #log do
		local it = log[i].intent
		local parts = {}
		for k, v in pairs(it) do
			table.insert(parts, k .. "=" .. tostring(v))
		end
		table.sort(parts)
		table.insert(out, "{" .. table.concat(parts, ",") .. "}")
	end
	return #log .. ": " .. table.concat(out, " ")
end

function Scenes.mouse(_h)
	local UIS = game:GetService("UserInputService")
	return tostring(UIS:GetMouseLocation()) .. " vp=" .. tostring(workspace.CurrentCamera.ViewportSize)
end

--- Run the hotkey handler directly (VirtualInput refuses keys bound to core actions, e.g. 1-9).
function Scenes.key(h, name)
	return tostring(h.ui.interact:_on_key(Enum.KeyCode[name], false)) .. " aim=" .. h.ui.interact.aim_kind
end

--- Give the local player gold in the local Sim (solo) so the mirror keeps it.
function Scenes.sim_gold(h, amount)
	local sim = h.session:local_sim()
	local me = h.ui.ctx:me()
	if sim == nil then
		return "no sim"
	end
	sim.o_gold[me] = tonumber(amount) or 0
	return "sim gold " .. tostring(sim.o_gold[me])
end

function Scenes.perf(h)
	local p = h.ui:perf_stats()
	return string.format(
		"ui ms/frame: process %.3f kit %.3f total %.3f max %.2f over %d frames",
		p.process,
		p.kit,
		p.total,
		p.max,
		p.frames
	)
end

--- Inject a warship (mirror only) of `owner` ("me" or id) on the water nearest (lat, lon), hp 620/1000,
--- veterancy 1, state 0; returns its uid.
function Scenes.warship(h, owner, lat, lon)
	local s = h.ui.ctx.state
	local id = if owner == "me" then s.local_owner else tonumber(owner)
	local c = tile_at(lat, lon)
	local t = -1
	for r = 0, 40 do
		for dx = -r, r do
			local tt = (c // Defs.W) * Defs.W + (c % Defs.W + dx) % Defs.W + (r - math.abs(dx)) * Defs.W
			if s.map:is_water(tt) then
				t = tt
				break
			end
		end
		if t >= 0 then
			break
		end
	end
	local uid = 800000 + math.random(1, 9999)
	s:apply_delta({
		t = s.tick,
		ev = { { Ev.UNIT_ADD, uid, Defs.U_WARSHIP, id, { t }, s.tick, 200, 0, 620, 1000, 1, 0, t } },
	})
	return tostring(uid) .. " at " .. t
end

function Scenes.select_unit(h, uid)
	h.ui.interact:select_unit(tonumber(uid))
	return "selected " .. tostring(h.ui.unit_card.is_open)
end

function Scenes.notice(h, text, sev)
	h.session.notice:Fire(text, tonumber(sev) or 0)
	return "notice"
end

--- Viewport px of the nearest water tile to (lat, lon): "x y tile".
function Scenes.where_water(h, lat, lon)
	local s = h.ui.ctx.state
	local c = tile_at(lat, lon)
	for r = 0, 40 do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local t = (c // Defs.W + dy) * Defs.W + (c % Defs.W + dx) % Defs.W
					if s.map:is_water(t) then
						local v = h.world:screen_pos_of_tile(t)
						return string.format("%d %d %d", math.floor(v.X + 0.5), math.floor(v.Y + 0.5), t)
					end
				end
			end
		end
	end
	return "none"
end

--- Freeze the title shine at x (word px) for inspection.
function Scenes.shine(h, x)
	local w = h.ui.title._word
	h.ui.title._sweep_t = -1
	w.sweep = tonumber(x) or -10000
	w:_redraw()
	return "shine " .. tostring(w.sweep) .. " w=" .. tostring(w.size.X)
end

--- Show the rotate card as if the viewport were portrait.
function Scenes.rotate_card(h, on)
	local rc = h.ui.rotate_card
	rc:set_visible(on ~= false)
	rc:set_process(on ~= false)
	rc.changed:Fire(on ~= false)
	return "rotate " .. tostring(rc.visible)
end

--- Tile under the pointer (UI conversion) + where the world draws a tile: "tile sx sy | t2 x y".
function Scenes.tile_here(h, t2)
	local ctx = h.ui.ctx
	local t = ctx:tile_at(ctx:mouse_pos())
	local out = string.format("tile %d owner %d", t, if t >= 0 then ctx.state:tile_owner(t) else -1)
	if t2 then
		local v = h.world:screen_pos_of_tile(t2)
		out ..= string.format(" | %d at %d %d", t2, math.floor(v.X + 0.5), math.floor(v.Y + 0.5))
	end
	return out
end

return Scenes
