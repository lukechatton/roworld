-- Session dev diagnostics (client). Active only when workspace attribute AF_DIAG == true (never in the
-- shipped place). Main.start() requires this with the live Main table. Commands arrive as the
-- LocalPlayer attribute "af_cmd" (set from Studio's execute_luau, which runs in another VM); the result
-- is written to "af_cmd_result" and numbers to af_* attributes once per second.
--   title | solo <difficulty> | spawn [ocean] | expand [ratio] | join | joinlobby | jointeam | leaveline | public | leave | pause 0|1 | music 0|1 |
--   theme menu|war | mood [name] | prof [s] | mem | sfx <name> | pops [s] [tiles/s] | menu [settings|game|open|pops|music|done|close] | starter [open|buy|close|new|grant] | burst building|sam | wreck | tutorial [new|next|state|ratio <x>] | mirv [n] | speed <x> | budget <ms> | eliminate | conquer [id] | gold [n] | build <kind> [up] | boat [ratio] [tiles] | focus [owner] | fakelive [n] | adminhuman [n]
local Players = game:GetService("Players")

local Diag = {}

--- A free land tile for the spawn diag; `ocean`: on the ocean's coast (boat tests).
local function free_spawn_tile(state: any, ocean: boolean?): number
	local map = state.map
	local seed = os.clock() * 1000 // 1
	for k = 1, 40000 do
		local t = map:land_tile((seed + k * 7919) % map.land_count)
		local where = if ocean then map:coast_body_of(t) == 1 else not map:is_coastal(t)
		if map:is_contestable(t) and state:tile_owner(t) == 0 and where then
			local ok = true
			for _, n in map:neighbors4(t) do
				if state:tile_owner(n) ~= 0 then
					ok = false
					break
				end
			end
			if ok then
				return t
			end
		end
	end
	return -1
end

local function neutral_neighbor(state: any): number
	local me = state.local_owner
	local map = state.map
	for k = 0, map.land_count - 1 do
		local t = map:land_tile(k)
		if state:tile_owner(t) == me then
			for _, n in map:neighbors4(t) do
				if state:tile_owner(n) == 0 and map:is_contestable(n) then
					return n
				end
			end
		end
	end
	return -1
end

function Diag.start(Main: any)
	local player = Players.LocalPlayer
	local session = Main.session
	local audio = Main.audio
	local log = {}
	session.state_ready:Connect(function(st)
		table.insert(log, ("state_ready mode=%d tick=%d"):format(session.mode, st.tick))
	end)
	session.mode_changed:Connect(function(m)
		table.insert(log, "mode_changed " .. m)
	end)
	session.joined_owner:Connect(function(id)
		local st = session.state
		table.insert(log, ("joined_owner %d local_info=%s"):format(id, tostring(st ~= nil and st:local_info() ~= nil)))
	end)
	session.notice:Connect(function(text, sev)
		table.insert(log, ("notice[%d] %s"):format(sev, text))
	end)
	session.building_started:Connect(function(m)
		table.insert(log, "building_started " .. m)
	end)
	local function run(cmd: string): string
		local words = string.split(cmd, " ")
		local op = words[1]
		local st = session.state
		if op == "title" then
			session:start_title()
		elseif op == "solo" then
			session:start_solo(tonumber(words[2]) or 1)
		elseif op == "spawn" then
			if st == nil then
				return "no state"
			end
			local t = free_spawn_tile(st, words[2] == "ocean")
			session:send_intent({ type = "spawn", tile = t })
			return "spawn " .. t
		elseif op == "expand" then
			if st == nil then
				return "no state"
			end
			local t = neutral_neighbor(st)
			-- through the UI's send (as a click would), so its hooks see it too
			local intent = { type = "attack", tile = t, ratio = tonumber(words[2]) or 0.4 }
			local ui = Main.ui
			if ui ~= nil and ui.ctx ~= nil then
				ui.ctx:send(intent)
			else
				session:send_intent(intent)
			end
			return "attack " .. t
		elseif op == "join" then
			session:join_multiplayer()
		elseif op == "joinlobby" then
			-- Quick Play: a seat in the soonest free-for-all (`joinlobby world`: World's own kind)
			local kind = if words[2] == "world" then "world" else "ffa"
			session:join_public(kind)
			return "asked for a " .. kind
		elseif op == "leaveline" then
			session:leave_line()
			return "left the line"
		elseif op == "starter" then
			-- the starter pack (UI/StarterOffer): state | open | buy | close | new (a new player again) | grant
			local ui = Main.ui
			local sub = words[2] or "state"
			if ui == nil or ui.starter == nil then
				return "no ui"
			end
			if sub == "open" then
				ui:open_starter("button")
			elseif sub == "buy" then
				ui.starter:_buy()
			elseif sub == "close" then
				ui.starter:close()
			elseif sub == "new" then
				session:new_player()
			elseif sub == "grant" then
				-- as if BUY NOW's prompt was paid: the window waits for the unlock, the server grants a
				-- test receipt through the real path (server: studio_grant:starter)
				ui.starter._pending = { phase = "granting", since = os.clock() }
				ui.starter:refresh()
				session.env.net.send(12, "studio_grant:starter")
			end
			local o = session.inventory and session.inventory.starter
			local btn = ui.title and ui.title._starter_btn
			return string.format(
				"offer=%s left=%s open=%s pending=%s button=%s unlocks=%s",
				if type(o) == "table" then o.state else tostring(o),
				if type(o) == "table" and o.ends_at then tostring(math.floor(o.ends_at - os.clock())) else "-",
				tostring(ui.starter.is_open),
				if ui.starter._pending then ui.starter._pending.phase else "none",
				tostring(btn ~= nil and btn.visible),
				(function()
					local ks = {}
					for k in (session.inventory and session.inventory.unlocks or {}) do
						table.insert(ks, k)
					end
					table.sort(ks)
					return table.concat(ks, ",")
				end)()
			)
		elseif op == "public" then
			-- Quick Play's state and what the title's cards say
			local pub = session.public or {}
			local title = Main.ui and Main.ui.title
			local cards = {}
			if title ~= nil then
				for i, c in title._cards do
					table.insert(
						cards,
						("[%d %s | %s | %s%s%s]"):format(
							i,
							c.title.text,
							c.status.text,
							c.pill_l.text,
							if c.btn.disabled then " (off)" else "",
							if c.btn.visible then "" else " hidden"
						)
					)
				end
			end
			return ("state=%s mode=%s kinds=%s %s"):format(
				tostring(pub.state),
				tostring(pub.mode),
				table.concat(session.lobby_kinds or {}, ","),
				table.concat(cards, " ")
			)
		elseif op == "leave" then
			session:leave_match()
		elseif op == "pause" then
			session:set_paused(words[2] == "1")
		elseif op == "music" then
			audio:set_music_enabled(words[2] == "1")
		elseif op == "theme" then
			audio:play_theme(words[2] or "menu")
		elseif op == "mood" then
			-- mood [name]: the soundtrack's mood and track (with a name: switch to it)
			if words[2] then
				audio:set_music_mood(words[2])
			end
			return ("mood %s, track %s"):format(audio:music_mood(), tostring(audio:current_track()))
		elseif op == "sfx" then
			audio:play_sfx(words[2] or "ui_click", 0, 0.04)
		elseif op == "pops" then
			-- the border pop over a run: `pops [seconds] [tiles a second]` (how its pitch warms up)
			local secs, speed = tonumber(words[2]) or 3, tonumber(words[3]) or 120
			task.spawn(function()
				local t0 = os.clock()
				while os.clock() - t0 < secs do
					audio:pop(speed * 0.1, 0)
					task.wait(0.1)
				end
			end)
			return ("pops for %.1f s; heat %.2f, pitch %.2f"):format(
				secs,
				audio._pop_heat,
				audio.pop_pitch(audio._pop_heat)
			)
		elseif op == "tutorial" then
			-- the new player's tutorial: `tutorial` starts it from the title, `tutorial new` replays as a
			-- new player (Staging's game-menu button), `tutorial state` says where it is
			local ui = Main.ui
			if ui == nil or ui.tutorial == nil then
				return "no ui"
			end
			if words[2] == "new" then
				ui:replay_as_new_player()
				return "replaying as a new player"
			elseif words[2] == "next" then
				ui.tutorial:_advance()
				return "advanced to " .. tostring(ui.tutorial._i)
			elseif words[2] == "ratio" then
				-- `tutorial ratio <x>`: set the Attack slider (what the cap and the floor make of it)
				local c = ui.ctx
				c:set_ratio(tonumber(words[3]) or 1)
				local o = c:my()
				return ("ratio=%.2f max=%.2f floor=%s order=%.3f troops=%s/%s phase=%s"):format(
					c.ratio,
					c.ratio_max,
					tostring(c.troop_floor),
					c:order_ratio(),
					tostring(o and math.floor(o.troops)),
					tostring(o and math.floor(o.max_troops)),
					tostring(st and st.phase)
				)
			elseif words[2] == "state" then
				local t = ui.tutorial
				return ("active=%s step=%d setting=%s"):format(
					tostring(t.active),
					t._i,
					tostring(ui.ctx:setting("tutorial", ""))
				)
			end
			ui:start_tutorial()
			return "tutorial asked for"
		elseif op == "mirv" then
			-- mirv [n]: solo only. n MIRVs (default 1) leave the next-biggest nations for the leader's land,
			-- as the AI's do when a leader nears the win: the late-game load of docs/performance.md
			-- (a MIRV is Rules.MIRV_WARHEADS warheads). Works while spectating.
			local sim = session:local_sim()
			if sim == nil or session.mode ~= 1 or st == nil then
				return "not in a solo match"
			end
			local rank = st:ranking()
			if #rank < 2 then
				return "nobody to fire"
			end
			local leader = rank[1].id
			local to = st:label_tile(leader)
			if to < 0 then
				return "the leader has no land"
			end
			local fired = 0
			for i = 1, math.clamp(tonumber(words[2]) or 1, 1, 8) do
				local from_owner = rank[1 + (i - 1) % (#rank - 1) + 1].id
				local from = st:label_tile(from_owner)
				if from >= 0 then
					local arc = sim.R.munition_arc(sim.W, sim.H, from, to, 2)
					local nk = sim:_spawn_nuke(2, from_owner, from, to, sim.R.nuke_arc_ticks(arc, 2), arc)
					nk.target_owner = leader
					fired += 1
				end
			end
			return ("%d MIRV at %s (%d tiles)"):format(fired, tostring(rank[1].name), rank[1].tiles or -1)
		elseif op == "wreck" then
			-- solo only: destroy one of the local player's defense posts (its explosion, end to end)
			local sim = session:local_sim()
			if sim == nil or session.mode ~= 1 or st == nil or st.local_owner == 0 then
				return "not in a solo match"
			end
			for _, s in sim:structs_of(st.local_owner, 3) do
				sim:destroy_struct(s)
				return ("destroyed defense post %d at tile %d"):format(s.sid, s.tile)
			end
			return "no defense post"
		elseif op == "burst" then
			-- an explosion sprite at the local player's start: `burst building|sam|nuke [seconds a frame]
			-- [px a tile]` (the second slows it down for a screenshot, for the rest of the session; the
			-- third puts the camera on it at that zoom)
			local fx = Main.world and Main.world.layers and Main.world.layers.fx
			local tile = if st ~= nil and st.owners[st.local_owner] ~= nil
				then st.owners[st.local_owner].spawn_tile
				else nil
			if fx == nil or st == nil then
				return "no map"
			end
			local W = st.map.W
			tile = if type(tile) == "number" and tile >= 0 then tile else (st.map.H // 2) * W + W // 2
			local row = fx.BURSTS[words[2] or "building"]
			if row ~= nil and tonumber(words[3]) ~= nil then
				row.frame_s = tonumber(words[3])
			end
			if tonumber(words[4]) ~= nil then
				-- `burst nuke 0.35 3`: the camera on it first, at that many px a tile
				fx.view.rig:focus_tile(tile, tonumber(words[4]), 0.01)
				task.wait(0.15)
			end
			fx:burst(words[2] or "building", tile % W + 0.5, tile // W + 0.5)
			return ("burst %s at tile %d"):format(words[2] or "building", tile)
		elseif op == "bonus" then
			-- an income popup over my capital: `bonus [gold] [seconds it lasts]` (the last slows it down
			-- for a screenshot, for the rest of the session); `bonus count` says how many are up
			local fx = Main.world and Main.world.layers and Main.world.layers.fx
			if fx == nil or st == nil then
				return "no map"
			end
			if words[2] == "count" then
				local shown = 0
				for _, g in fx._bonus_gui do
					shown += if g.label.Visible then 1 else 0
				end
				return ("%d income popups alive, %d drawn"):format(#fx._bonus, shown)
			end
			if words[2] == "sim" then
				-- solo: through the Sim, as a train's stop pays it (Ev.BONUS, the mirror, the map)
				local sim = session:local_sim()
				local me = st.local_owner
				if sim == nil or me == 0 then
					return "not in a solo match"
				end
				if tonumber(words[4]) ~= nil then
					getmetatable(fx).__index.BONUS_S = tonumber(words[4])
				end
				local g0 = sim.o_gold[me]
				sim:add_bonus_gold(me, tonumber(words[3]) or 25000, sim.o_spawn_tile[me])
				return ("sim paid %d at tile %d (gold %d -> %d)"):format(
					tonumber(words[3]) or 25000,
					sim.o_spawn_tile[me],
					g0,
					sim.o_gold[me]
				)
			end
			local o = st.owners[st.local_owner]
			local tile = if o ~= nil then o.spawn_tile else nil
			tile = if type(tile) == "number" and tile >= 0 then tile else (st.map.H // 2) * st.map.W + st.map.W // 2
			if tonumber(words[3]) ~= nil then
				getmetatable(fx).__index.BONUS_S = tonumber(words[3])
			end
			fx:bonus(tile, tonumber(words[2]) or 25000)
			return ("income popup at tile %d"):format(tile)
		elseif
			op == "spawnat"
			or op == "nukeat"
			or op == "tileat"
			or op == "attackat"
			or op == "boatto"
			or op == "buildat"
		then
			-- (the trailer) spawnat <u> <v>: spawn on the free tile nearest map point (u, v);
			-- nukeat <kind> <u> <v>: fire `kind` (atom / hydrogen / mirv / mega ...) at the tile there, through
			-- the UI's send as a click would; tileat <u> <v>: the tile and its owner
			if st == nil then
				return "no state"
			end
			local map = st.map
			local W = map.W
			local base = if op == "nukeat" or op == "buildat" then 3 else 2
			local u = math.floor(tonumber(words[base]) or 0)
			local v = math.floor(tonumber(words[base + 1]) or 0)
			local at = v * W + u
			if op == "tileat" then
				return ("tile %d owner %d (%s)"):format(at, st:tile_owner(at), st:owner_name(st:tile_owner(at)))
			end
			if op == "attackat" or op == "boatto" or op == "buildat" then
				-- attackat <u> <v> [ratio] / boatto <u> <v> [ratio] / buildat <kind name> <u> <v>, through the
				-- UI's send as a click would
				local ui = Main.ui
				if op == "buildat" then
					ui.ctx:send({ type = "build", kind = words[2], tile = at })
					return ("build %s at %d"):format(tostring(words[2]), at)
				end
				local ratio = tonumber(words[4]) or 0.5
				ui.ctx:send({ type = if op == "boatto" then "boat" else "attack", tile = at, ratio = ratio })
				return ("%s %d (owner %d)"):format(op, at, st:tile_owner(at))
			end
			if op == "nukeat" then
				local ui = Main.ui
				ui.ctx:send({ type = "nuke", kind = words[2] or "atom", tile = at })
				return ("fired %s at %d (owner %d)"):format(tostring(words[2]), at, st:tile_owner(at))
			end
			local best, bd = -1, math.huge
			for r = 0, 120 do
				for dv = -r, r do
					for du = -r, r do
						if math.max(math.abs(du), math.abs(dv)) == r then
							local x, y = u + du, v + dv
							if x >= 0 and x < W and y >= 0 and y < map.H then
								local t = y * W + x
								if map:is_land(t) and map:is_contestable(t) and st:tile_owner(t) == 0 then
									local d = du * du + dv * dv
									if d < bd then
										best, bd = t, d
									end
								end
							end
						end
					end
				end
				if best >= 0 then
					break
				end
			end
			if best < 0 then
				return "no free tile near"
			end
			session:send_intent({ type = "spawn", tile = best })
			return ("spawn %d"):format(best)
		elseif op == "nations" then
			-- (the trailer) the biggest owners: id, name, tiles, the middle of their land (u, v)
			if st == nil then
				return "no state"
			end
			local map = st.map
			local W = map.W
			local acc = {}
			for k = 0, map.land_count - 1 do
				local t = map:land_tile(k)
				local o = st:tile_owner(t)
				if o ~= 0 then
					local a = acc[o]
					if a == nil then
						a = { n = 0, u = 0, v = 0 }
						acc[o] = a
					end
					a.n += 1
					a.u += t % W
					a.v += t // W
				end
			end
			local list = {}
			for o, a in acc do
				table.insert(list, { o = o, n = a.n, u = a.u / a.n, v = a.v / a.n })
			end
			table.sort(list, function(x, y)
				return x.n > y.n
			end)
			local out = {}
			for i = 1, math.min(tonumber(words[2]) or 12, #list) do
				local e = list[i]
				table.insert(out, ("%d %s %d @%.0f,%.0f"):format(e.o, st:owner_name(e.o), e.n, e.u, e.v))
			end
			return ("me=%d tick=%d | "):format(st.local_owner, st.tick) .. table.concat(out, " | ")
		elseif op == "film" then
			-- the trailer (Dev/Film): film start [fps] | stop | cam u v scale secs | look u v scale | where
			local Film = require(script.Parent:WaitForChild("Film")) :: any
			local sub = words[2]
			local rig = Main.world and Main.world.rig
			if sub == "start" then
				Film.start(Main, tonumber(words[3]))
				return "filming"
			elseif sub == "stop" then
				Film.stop()
				return "stopped"
			elseif sub == "cam" and rig ~= nil then
				-- (a glide on the camera's own dt: on film time while filming)
				rig:focus(
					tonumber(words[3]) or 0,
					tonumber(words[4]) or 0,
					tonumber(words[5]) or 0,
					tonumber(words[6]) or 1
				)
				return "cam"
			elseif sub == "look" and rig ~= nil then
				rig.attract = false
				-- (a glide still under way would carry on over this)
				rig._focus_active = false
				rig._vel = Vector2.zero
				rig:set_scale_immediate(tonumber(words[5]) or 1)
				rig:look_at(tonumber(words[3]) or 0, tonumber(words[4]) or 0)
				return "look"
			elseif sub == "where" then
				if rig == nil then
					return "no map"
				end
				return string.format(
					"cu=%.1f cv=%.1f scale=%.3f min=%.3f max=%.3f W=%d H=%d frames=%d tick=%s",
					rig.cu,
					rig.cv,
					rig.scale,
					rig:min_scale(),
					rig:max_scale(),
					rig.W,
					rig.H,
					Film.frames(),
					tostring(st and st.tick)
				)
			end
			if sub == "nuke" and rig ~= nil and st ~= nil then
				-- film nuke <kind> <scale>: the camera on the first such munition in flight (Defs.N_*; 2 = a
				-- MIRV), where the map draws it; "none" once there is none
				local kind = tonumber(words[3]) or 2
				local pick = nil
				for uid, n in st.nukes do
					if n.kind == kind and (pick == nil or uid < pick.uid) then
						pick = n
					end
				end
				if pick == nil then
					return "none"
				end
				local units = Main.world and Main.world.units
				local rt = st.render_tick or st.tick
				local t = math.clamp((rt - pick.launch_tick) / math.max(pick.flight_ticks, 1), 0, 1)
				local u, v = units.nuke_uv(st, pick, t)
				rig.attract = false
				rig._focus_active = false
				rig._vel = Vector2.zero
				rig:set_scale_immediate(tonumber(words[4]) or rig.scale)
				rig:look_at(u, v)
				return string.format("u=%.1f v=%.1f t=%.3f", u, v, t)
			end
			if sub == "busiest" and st ~= nil then
				-- film busiest <unit kind> <cell tiles>: the map cells with the most units of that kind
				-- (Defs.U_*; 1 = trade ships), where the map draws them: "u,v n" for the top five
				local kind = tonumber(words[3]) or 1
				local cell = tonumber(words[4]) or 120
				local units = Main.world and Main.world.units
				local rt = st.render_tick or st.tick
				local count, su, sv = {}, {}, {}
				for _, un in st.units do
					if un.kind == kind then
						local u, v = units.unit_uv(st, un, rt)
						local key = math.floor(u / cell) * 100000 + math.floor(v / cell)
						count[key] = (count[key] or 0) + 1
						su[key] = (su[key] or 0) + u
						sv[key] = (sv[key] or 0) + v
					end
				end
				local list = {}
				for key, n in count do
					table.insert(list, { n = n, u = su[key] / n, v = sv[key] / n })
				end
				table.sort(list, function(a, b)
					return a.n > b.n
				end)
				local out = {}
				for i = 1, math.min(5, #list) do
					table.insert(out, string.format("%.0f,%.0f %d", list[i].u, list[i].v, list[i].n))
				end
				return table.concat(out, " | ")
			end
			if sub == "ll" and rig ~= nil then
				-- film ll <lat> <lon>: that place's map point
				local u, v = rig:latlon_to_map(tonumber(words[3]) or 0, tonumber(words[4]) or 0)
				return string.format("u=%.1f v=%.1f", u, v)
			end
			return "film start|stop|cam|look|where|ll"
		elseif op == "speed" then
			session.local_speed = tonumber(words[2]) or 1
		elseif op == "budget" then
			session.step_budget_s = (tonumber(words[2]) or 6) / 1000
		elseif op == "settings" then
			local HttpService = game:GetService("HttpService")
			return ("ready=%s ui=%s audio=%s"):format(
				tostring(session.settings_ready),
				HttpService:JSONEncode(session:load_settings("ui")),
				HttpService:JSONEncode(session:load_settings("audio"))
			)
		elseif op == "menu" then
			-- the game menu's window: `menu settings` (the gear's press), `menu game` (the menu button's),
			-- `menu open` (its Settings row), `menu pops` / `menu music` (a press on that switch),
			-- `menu done`, `menu close`, `menu` (its state)
			local ui = Main.ui
			if ui == nil or ui.pause == nil then
				return "no ui"
			end
			local pm = ui.pause
			if words[2] == "settings" then
				ui:open_settings()
			elseif words[2] == "game" then
				ui:open_pause_menu()
			elseif words[2] == "open" then
				pm._settings_btn.pressed:Fire()
			elseif words[2] == "pops" then
				pm._pops.pressed:Fire()
			elseif words[2] == "music" then
				-- (the Music slider: to 0% and back to 100%, as a finger lifting there)
				pm._music:_set(if pm._music.value > 0 then 0 else 1, true)
			elseif words[2] == "done" then
				pm._done.pressed:Fire()
			elseif words[2] == "close" then
				pm:close()
			end
			return ("open=%s page=%s pops=%s (switch %s) music=%s paused=%s"):format(
				tostring(pm.is_open),
				pm:page(),
				tostring(audio:is_pops_enabled()),
				tostring(pm._pops.on),
				tostring(audio:is_music_enabled()),
				tostring(session.paused)
			)
		elseif op == "award" then
			-- the result screen's Stars and offers: `award <total> <balance> [notake]` shows a payout as
			-- the server's would be shown ("notake": without the takeover offer, which hides them)
			local ui = Main.ui
			if ui == nil or ui.over == nil then
				return "no ui"
			end
			local total = tonumber(words[2]) or 1440
			local award = {
				lines = { { "played", 100 }, { "time", total - 100 } },
				total = total,
				balance = tonumber(words[3]) or 4560,
				mode = "solo",
			}
			session.last_award = award
			if words[4] == "notake" then
				ui.over:set_takeover(nil)
			end
			ui.over:set_award(award)
			ui.over:apply_layout()
			return ("over open=%s take=%s offers=%s goal=%s (%s) x2=%s (%s)"):format(
				tostring(ui.over.is_open),
				tostring(ui.over._take.visible),
				tostring(ui.over._offers.visible),
				tostring(ui.over._goal_btn.visible),
				tostring(ui.over._goal_btn.text),
				tostring(ui.over._x2_btn.visible),
				tostring(ui.over._x2_btn.text)
			)
		elseif op == "save_ui" then
			session:save_settings("ui", { ratio = 0.42, labels = false, difficulty = 2 })
		elseif op == "log" then
			return table.concat(log, "\n")
		elseif op == "baddelta" then
			-- code-fixer: a delta that fails to decode arrives (review #11): the session asks for a resync
			session:_on_net(22, buffer.fromstring("\1\255\255\255"))
			return ("resync_pending=%s"):format(tostring(session._resync_pending))
		elseif op == "eliminate" then
			-- code-fixer: solo only — the local player falls (Sim._eliminate), so the real results screen
			-- ("Play again" / "Keep watching") and the spectate pill can be clicked.
			local sim = session:local_sim()
			if sim == nil or session.mode ~= 1 or st == nil or st.local_owner == 0 then
				return "not in a solo match"
			end
			local me = st.local_owner
			local killer = 0
			for _, r in st:ranking() do
				-- ("eliminate nation": by the biggest AI nation, for the takeover offer)
				if r.id ~= me and (words[2] ~= "nation" or r.kind == 0) then
					killer = r.id
					break
				end
			end
			sim:_eliminate(me, killer)
			return ("eliminated %d by %d"):format(me, killer)
		elseif op == "credit" then
			-- takeover check: the server (Studio + AF_DIAG) stores a test takeover credit
			local net = session.env.net
			if net == nil or not net.connected then
				return "not connected"
			end
			net.send(12, "studio_grant:takeover")
			return "asked for a test takeover credit"
		elseif op == "reach" then
			-- takeover check: what the UI's own rule says about a neighbour's tile (attack / boat /
			-- the "No border or sea route" refusal), for the nation this player commands now
			local ui = Main.ui
			local sst = session.state
			if ui == nil or sst == nil or sst.local_owner == 0 then
				return "no state"
			end
			local me = sst.local_owner
			local W = sst.W or 0
			local seen = {}
			for t = 0, (sst.N or 0) - 1 do
				if sst:tile_owner(t) == me then
					for _, n in { t - 1, t + 1, t - W, t + W } do
						local o = if n >= 0 then sst:tile_owner(n) else 0
						if o ~= 0 and o ~= me and not seen[o] then
							seen[o] = true
							local a = ui.ctx.rules:primary(n)
							return string.format(
								"me=%d (%s) vs %s: type=%s ok=%s reason=%s",
								me,
								tostring(sst:owner_name(me)),
								tostring(sst:owner_name(o)),
								tostring(a.type),
								tostring(a.ok),
								tostring(a.reason)
							)
						end
					end
				end
			end
			return "no bordering owner"
		elseif op == "win" then
			-- the windows over a dim: `win help|maps|locker|arsenal` opens one; `win` says which are open
			local ui = Main.ui
			if ui == nil then
				return "no ui"
			end
			local w = words[2]
			if w == "help" and not ui.help.is_open then
				ui:toggle_help()
			elseif w == "maps" and ui.title ~= nil then
				ui.title.pick_map:Fire()
			elseif w == "locker" then
				ui:open_locker()
			elseif w == "arsenal" then
				ui:open_arsenal(nil, "title")
			end
			local wins = { help = ui.help, maps = ui.map_picker, locker = ui.locker, arsenal = ui.arsenal }
			local rect = ""
			if wins[w] ~= nil then
				-- (the window's rect in viewport px, for a test click on its ground)
				local r = wins[w]._panel:get_view_rect()
				rect = (" rect=%d,%d,%d,%d"):format(r.Min.X, r.Min.Y, r.Max.X, r.Max.Y)
			end
			return ("help=%s maps=%s locker=%s arsenal=%s menu=%s%s"):format(
				tostring(ui.help.is_open),
				tostring(ui.map_picker.is_open),
				tostring(ui.locker.is_open),
				tostring(ui.arsenal.is_open),
				tostring(ui.pause.is_open),
				rect
			)
		elseif op == "locker" then
			-- crates check: open the Locker; "locker buy" presses its crate button
			local ui = Main.ui
			if ui == nil or ui.locker == nil then
				return "no ui"
			end
			if words[2] == "buy" then
				ui.locker:_buy_pressed()
				return "pressed the crate button"
			end
			if words[2] == "close" then
				ui.locker:close()
				return "closed"
			end
			if words[2] == "size" then
				-- the window's height (logical px) against the screen's clear height: it must fit
				local sz = ui.locker._panel:get_combined_minimum_size()
				local area = ui.ctx:clear_rect()
				local card = ui.locker._crate:get_combined_minimum_size()
				return ("window %dx%d, crate card %dx%d, clear area %dx%d, compact %s"):format(
					sz.X,
					sz.Y,
					card.X,
					card.Y,
					area.Width,
					area.Height,
					tostring(ui.ctx.compact)
				)
			end
			if words[2] == "tab" then
				ui.locker._tab = tonumber(words[3]) or 1
				ui.locker:_rebuild()
				return "tab " .. tostring(ui.locker._tab)
			end
			ui:open_locker()
			local inv = session.inventory or {}
			local n = 0
			for _ in inv.owned or {} do
				n += 1
			end
			return string.format(
				"locker open: %d owned, crates allowed %s, crate credits %s",
				n,
				tostring(inv.crates_allowed),
				tostring(session.credits and session.credits.crate)
			)
		elseif op == "cos" then
			-- cosmetics check: who wears what in this match's mirror
			local sst = session.state
			if sst == nil then
				return "no state"
			end
			local n, flags, skins, faces = 0, 0, 0, 0
			for _, c in sst.cosmetics or {} do
				n += 1
				flags += if c.flag then 1 else 0
				skins += if c.skin then 1 else 0
				faces += if c.face then 1 else 0
			end
			-- (players without a head shot: there should be none)
			local players, bare = 0, 0
			for id, o in sst.owners or {} do
				if o.kind == 2 then
					players += 1
					bare += if (sst.cosmetics or {})[id] ~= nil and sst.cosmetics[id].face ~= nil then 0 else 1
				end
			end
			local mine = (sst.cosmetics or {})[sst.local_owner or 0]
			return string.format(
				"%d owners dressed (%d flags, %d skins, %d faces); %d players, %d without a face; mine: skin=%s flag=%s face=%s",
				n,
				flags,
				skins,
				faces,
				players,
				bare,
				tostring(mine and mine.skin),
				tostring(mine and mine.flag),
				tostring(mine and mine.face)
			)
		elseif op == "crate_show" then
			-- the opening show without a crate: crate_show <rarity|item id> [pace] (the item is shown, not
			-- granted); crate_show tap | close
			local ui = Main.ui
			local o = ui and ui.crate_opening
			if o == nil then
				return "no ui"
			end
			if words[2] == "tap" then
				o:_tap()
				return "tap (" .. tostring(o._phase) .. ")"
			elseif words[2] == "close" then
				o:close()
				return "closed"
			end
			local Cosmetics = require(game:GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Cosmetics)
			local want = words[2] or "rare"
			local id = if Cosmetics.item(want) then want else nil
			if id == nil then
				for _, it in Cosmetics.all() do
					if it.rarity == want then
						id = it.id
						break
					end
				end
			end
			o.pace = tonumber(words[3]) or 1
			o:play(ui.locker:_offer())
			o:resolve(id or "stripes")
			return string.format("show %s at pace %s", tostring(id), tostring(o.pace))
		elseif op == "radial_sub" then
			-- the open radial menu: enter the item with this id's ring (build, build:city, nuke, ...)
			local r = Main.ui and Main.ui.radial
			if r == nil or not r.is_open then
				return "radial closed"
			end
			local ids = {}
			for _, it in r.items do
				table.insert(ids, tostring(it.id) .. (if it.sub then "▸" else "") .. (if it.ok then "" else "(x)"))
				if it.id == words[2] and it.sub ~= nil then
					r:_enter_sub(it)
					local sub = {}
					for _, s2 in r.items do
						table.insert(
							sub,
							tostring(s2.id) .. " [" .. tostring(s2.label) .. "]" .. (if s2.ok then "" else "(x)")
						)
					end
					return "entered " .. words[2] .. ": " .. table.concat(sub, ", ")
				end
			end
			if words[3] == "pick" then
				local rt = r.tile
				r:close(false)
				r.picked:Fire(words[2], rt)
				return "picked " .. words[2]
			end
			return "items: " .. table.concat(ids, ", ")
		elseif op == "tray" then
			-- phone build tray: tray 1|0 -> the camera's screen offset (must not change)
			local ui = Main.ui
			local rig = Main.world and Main.world.rig
			if ui == nil or ui.bar == nil or rig == nil then
				return "no ui"
			end
			local before = rig.screen_offset
			ui.bar:set_tray(words[2] ~= "0")
			task.wait(0.8)
			return string.format(
				"tray %s | screen offset %s -> %s",
				tostring(ui.bar.tray.visible),
				tostring(before),
				tostring(rig.screen_offset)
			)
		elseif op == "hold" then
			-- press and hold the map at viewport px (x y; default the centre) through MapInput's real path
			-- for `ms` (default 700), optionally sliding `dx dy` px after the menu opens; reports the camera
			-- (cu, cv, scale) before / after and whether the radial menu opened: hold [x y] [ms] [dx dy]
			local w = Main.world
			local inp = w and w.input
			local rig = w and w.rig
			if inp == nil or rig == nil then
				return "no world"
			end
			local vp = rig:viewport_size()
			local x, y = tonumber(words[2]) or vp.X * 0.5, tonumber(words[3]) or vp.Y * 0.5
			local ms = tonumber(words[4]) or 700
			local dx, dy = tonumber(words[5]) or 0, tonumber(words[6]) or 0
			if words[2] == "struct" then
				-- hold struct <Defs.S_* kind>: on my first structure of that kind
				local k = tonumber(words[3]) or 0
				local found = false
				for _, s2 in (st and st.structures or {}) do
					if s2.owner == st.local_owner and s2.kind == k then
						x, y = rig:tile_to_screen(s2.tile)
						found = true
						break
					end
				end
				if not found then
					return "no such structure"
				end
				ms, dx, dy = 700, 0, 0
			end
			local before = string.format("%.2f,%.2f s%.3f", rig.cu, rig.cv, rig.scale)
			local pos = Vector2.new(x, y)
			inp:debug_pointer("down", pos)
			task.wait(ms / 1000)
			local opened = Main.ui ~= nil and Main.ui.radial ~= nil and Main.ui.radial.is_open
			local mid = string.format("%.2f,%.2f s%.3f", rig.cu, rig.cv, rig.scale)
			if dx ~= 0 or dy ~= 0 then
				for i = 1, 8 do
					inp:debug_pointer("move", pos + Vector2.new(dx, dy) * (i / 8))
					task.wait(0.03)
				end
			end
			inp:debug_pointer("up", pos + Vector2.new(dx, dy))
			task.wait(0.5)
			local after = string.format("%.2f,%.2f s%.3f", rig.cu, rig.cv, rig.scale)
			return string.format(
				"radial %s | cam before %s  at open %s  after %s",
				tostring(opened),
				before,
				mid,
				after
			)
		elseif op == "crate_btn" then
			-- the title's crate button in a forced look: crate_btn waiting|first|offer|calm|off
			local ui = Main.ui
			local b = ui and ui.title and ui.title._crate_btn
			if b == nil then
				return "no button"
			end
			b._fake = if words[2] == "off" then nil else words[2]
			b:refresh()
			return "crate button: " .. tostring(b._state) .. " badge " .. tostring(b._badge_value)
		elseif op == "arsenal" then
			-- the Arsenal (Data/Arsenal): arsenal [item] opens it; arsenal close; arsenal stars <key> /
			-- arsenal robux <key> press an item's buttons; arsenal sel <key> shows an item; arsenal inv
			local ui = Main.ui
			if ui == nil or ui.arsenal == nil then
				return "no ui"
			end
			local a = ui.arsenal
			if words[2] == "close" then
				a:close()
				return "closed"
			elseif words[2] == "stars" or words[2] == "robux" then
				local it = (require(game:GetService("ReplicatedStorage").Airfront.Data.Arsenal) :: any).item(words[3])
				if it == nil then
					return "no such item"
				end
				if words[2] == "stars" then
					a:_stars_pressed(it)
				else
					a:_robux_pressed(it)
				end
				return ("pressed %s %s: pending=%s confirm=%s note=%s"):format(
					words[2],
					it.key,
					tostring(a._pending ~= nil),
					tostring(a._confirm),
					tostring(a._note)
				)
			elseif words[2] == "land" then
				-- solo only: claim the land within <r> tiles of my start (room to build and to be shelled)
				local sim = session:local_sim()
				if sim == nil or session.mode ~= 1 or st == nil or st.local_owner == 0 then
					return "not in a solo match"
				end
				local me = st.local_owner
				local n = 0
				for _, t in sim:disk_tiles(sim.o_spawn_tile[me], tonumber(words[3]) or 40, true) do
					if buffer.readi32(sim.owner, t * 4) ~= me then
						sim:set_owner(t, me)
						n += 1
					end
				end
				return ("claimed %d tiles"):format(n)
			elseif words[2] == "sim" then
				-- solo only: what the Sim holds of the Arsenal
				local sim = session:local_sim()
				if sim == nil or st == nil then
					return "no local sim"
				end
				local me = st.local_owner
				local kinds = {}
				for _, nk in sim.nukes do
					kinds[nk.kind] = (kinds[nk.kind] or 0) + 1
				end
				local parts = {}
				for k, c in kinds do
					table.insert(parts, ("%s x%d"):format(tostring(k), c))
				end
				local structs = {}
				for _, s in sim.struct_list do
					if not s.dead and s.owner == me then
						table.insert(structs, ("%d:L%d%s"):format(s.kind, s.level, if s.active then "" else "*"))
					end
				end
				return ("unlock=%d batteries=%d flying=[%s] mine=[%s] troops=%.0f gold=%.0f reinforce_wait=%d"):format(
					sim.o_unlock[me] or -1,
					#sim.batteries,
					table.concat(parts, " "),
					table.concat(structs, " "),
					sim.o_troops[me] or 0,
					sim.o_gold[me] or 0,
					sim:reinforce_wait(me)
				)
			elseif words[2] == "fire" then
				-- fire <kind>: launch at the nearest land that isn't mine, through the UI's send
				local sim = session:local_sim()
				if sim == nil or st == nil or st.local_owner == 0 then
					return "not in a solo match"
				end
				local me = st.local_owner
				local W = st.map.W
				local from = sim.o_spawn_tile[me]
				local best, bd = -1, math.huge
				for k = 0, st.map.land_count - 1 do
					local t = st.map:land_tile(k)
					local o = st:tile_owner(t)
					if o ~= me and o ~= 0 then
						local d = (t % W - from % W) ^ 2 + (t // W - from // W) ^ 2
						local want = (tonumber(words[4]) or 60) ^ 2
						if math.abs(d - want) < bd then
							best, bd = t, math.abs(d - want)
						end
					end
				end
				if best < 0 then
					return "no target"
				end
				ui.ctx:send({ type = "nuke", kind = words[3] or "mega", tile = best })
				return ("fired %s at %d (owner %d)"):format(tostring(words[3]), best, st:tile_owner(best))
			elseif words[2] == "size" then
				-- the window (logical px) against the screen's clear area, and the item's area
				local sz = a._panel:get_combined_minimum_size()
				local area = ui.ctx:clear_rect()
				local d = a._detail_size or Vector2.zero
				return ("window %dx%d, item %dx%d, clear area %dx%d, compact %s, scale %.2f"):format(
					sz.X,
					sz.Y,
					d.X,
					d.Y,
					area.Width,
					area.Height,
					tostring(ui.ctx.compact),
					(require(script.Parent.Parent.UI.UITheme) :: any).scale
				)
			elseif words[2] == "sel" then
				-- arsenal sel <key>: show that item, as a press on its row would
				if words[3] ~= nil then
					a:_select(words[3], true)
				end
				local d = a._detail
				return ("sel=%s detail=%s demo=%s viewed=%d"):format(
					tostring(a._sel),
					tostring(d and d.key),
					tostring(d ~= nil and d.demo ~= nil),
					(function()
						local n = 0
						for _ in a._viewed do
							n += 1
						end
						return n
					end)()
				)
			elseif words[2] == "inv" then
				local inv = session.inventory
				local keys = {}
				for k in inv.unlocks do
					table.insert(keys, k)
				end
				table.sort(keys)
				return ("stars=%d unlocks=[%s] loaded=%s award=%s"):format(
					inv.stars,
					table.concat(keys, ","),
					tostring(inv.loaded),
					if session.last_award then tostring(session.last_award.total) else "nil"
				)
			end
			ui:open_arsenal(words[2], words[3] or "title")
			return "open=" .. tostring(a.is_open)
		elseif op == "stars" then
			-- a Studio-only grant of test Stars (server: studio_grant:stars), or "unlock <key>": a test
			-- unlock as a Robux receipt would make it
			local net = session.env.net
			if net == nil or not net.connected then
				return "not connected"
			end
			net.send(12, "studio_grant:stars", tonumber(words[2]) or 10000)
			return "asked for test Stars"
		elseif op == "unlock" then
			local net = session.env.net
			if net == nil or not net.connected then
				return "not connected"
			end
			net.send(12, "studio_grant:unlock:" .. tostring(words[2]))
			return "asked for a test unlock of " .. tostring(words[2])
		elseif op == "pick" then
			-- pick <kind>: choose a build / launch kind as the bar's slot would (UIInteract.select_action)
			local ui = Main.ui
			if ui == nil then
				return "no ui"
			end
			ui.interact:select_action(words[2] or "city")
			return ("aim=%s arsenal_open=%s"):format(tostring(ui.interact.aim_kind), tostring(ui.arsenal.is_open))
		elseif op == "wear" then
			-- skins check: put skin `words[2]` (any id, exclusives too) on owner `words[3]` (default: you)
			-- in this match's mirror only. Nothing is owned or saved; the next cosmetics update replaces it.
			local sst = session.state
			if sst == nil or type(sst.set_cosmetics) ~= "function" then
				return "no state"
			end
			local who = tonumber(words[3]) or sst.local_owner or 0
			local c = table.clone((sst.cosmetics or {})[who] or {})
			c.skin = if words[2] == nil or words[2] == "none" then nil else words[2]
			sst:set_cosmetics({ [who] = c })
			return "owner " .. tostring(who) .. " wears " .. tostring(c.skin)
		elseif op == "shop" then
			-- the flag shop: `shop` opens it and says what's in it; `shop grant <key>|set:<id>` a test purchase of
			-- that flag through the real receipt path (server: studio_grant:shopflag:<key>); `shop close`
			local ui = Main.ui
			if ui == nil or ui.flag_shop == nil then
				return "no ui"
			end
			if words[2] == "grant" then
				local net = session.env.net
				if net == nil or not net.connected then
					return "not connected"
				end
				-- (`shop grant set:<id>`: a set's bundle)
				local set_id = string.match(tostring(words[3]), "^set:(.+)$")
				if set_id ~= nil then
					net.send(12, "studio_grant:shopset:" .. set_id)
					return "asked for the " .. set_id .. " pack"
				end
				net.send(12, "studio_grant:shopflag:" .. tostring(words[3]))
				return "asked for shop flag " .. tostring(words[3])
			elseif words[2] == "close" then
				ui.flag_shop:close()
				return "closed"
			end
			ui:open_shop()
			local FS = require(script.Parent.Parent.UI.FlagShop) :: any
			local c = FS.contents(FS.now())
			local sets = {}
			for _, st in c.sets do
				table.insert(sets, st.id .. "=" .. table.concat(st.keys, ","))
			end
			local inv = session.inventory or {}
			local mine = {}
			for id in inv.owned or {} do
				if string.sub(id, 1, 5) == "shop_" then
					table.insert(mine, id)
				end
			end
			table.sort(mine)
			return ("open=%s day=%d daily=%s sets=[%s] owned=[%s] wearing=%s"):format(
				tostring(ui.flag_shop.is_open),
				c.day,
				table.concat(c.daily, ","),
				table.concat(sets, " "),
				table.concat(mine, ","),
				tostring((inv.equipped or {}).flag)
			)
		elseif op == "crate_credit" then
			local net = session.env.net
			if net == nil or not net.connected then
				return "not connected"
			end
			net.send(12, "studio_grant:crate")
			return "asked for a test crate"
		elseif op == "equip" then
			session:equip(words[2] or "skin", if words[3] == nil or words[3] == "none" then false else words[3])
			return "equip " .. tostring(words[2]) .. " " .. tostring(words[3])
		elseif op == "takeover_preview" then
			-- takeover check: show the priced offer (a fake product id; pressing it would fail)
			local ui = Main.ui
			if ui == nil or ui.takeover == nil then
				return "no ui"
			end
			ui.takeover._preview_id = if words[2] == "off" then nil else 1
			ui.takeover._shown_key = "?"
			ui.takeover:refresh()
			return "preview " .. tostring(ui.takeover._preview_id)
		elseif op == "takeover" then
			-- takeover check: press the offer's button (the ELIMINATED screen / the pill)
			local ui = Main.ui
			if ui == nil or ui.takeover == nil then
				return "no ui"
			end
			local t = ui.takeover:target()
			if t == 0 then
				return "no offer (credits " .. tostring(ui.takeover:saved()) .. ")"
			end
			ui.takeover:start()
			return "pressed TAKE OVER for " .. tostring(t)
		elseif op == "fakelive" then
			-- title check: n fake running matches (WATCH card, live list), kept in every lobby list the
			-- server sends from now on
			local maps = { "europe", "world", "africa", "mena", "twolakes", "caribbean", "arctic", "montreal" }
			local fakes = {}
			for i = 1, math.clamp(tonumber(words[2]) or 1, 0, 8) do
				local m = maps[i]
				table.insert(fakes, {
					id = "fake-live-" .. i,
					map = m,
					map_name = string.upper(string.sub(m, 1, 1)) .. string.sub(m, 2),
					max = 50,
					players = 4 - i % 3,
					starts_in = 0,
					joinable = false,
					live = true,
					elapsed = 754 - i * 60,
					watchable = true,
				})
			end
			Diag._fake_live = fakes
			if not Diag._emit_wrapped then
				Diag._emit_wrapped = true
				local emit = session._emit
				session._emit = function(s: any, name: string, ...: any)
					if name ~= "lobbies_updated" then
						return emit(s, name, ...)
					end
					local list = {}
					for _, l in (...) or {} do
						if type(l.id) ~= "string" or string.sub(l.id, 1, 10) ~= "fake-live-" then
							table.insert(list, l)
						end
					end
					for _, f in Diag._fake_live or {} do
						table.insert(list, f)
					end
					s.lobbies = list
					return emit(s, name, list)
				end
			end
			session:_emit("lobbies_updated", session.lobbies or {})
			return ("%d fake live matches listed"):format(#fakes)
		elseif op == "adminhuman" then
			-- admin view check: pretend the first n bot players are humans (this client only)
			local bots = session.admin_bots
			if bots == nil then
				return "no admin data"
			end
			local ids = {}
			for id in bots do
				table.insert(ids, id)
			end
			table.sort(ids)
			local n = math.min(tonumber(words[2]) or 3, #ids)
			for i = 1, n do
				bots[ids[i]] = nil
			end
			session:_emit("admin_changed")
			return ("%d bots shown as humans"):format(n)
		elseif op == "build" then
			-- build <kind> [up]: a structure of `kind` (Defs.S_*) on my land away from the others, or
			-- ("up") upgrade my first one of that kind — through the UI's send, as a click would
			if st == nil or st.local_owner == 0 then
				return "not in a match"
			end
			local kind = tonumber(words[2]) or 4
			local me = st.local_owner
			local map = st.map
			local tile = -1
			if words[3] == "up" then
				for _, s in st.structures do
					if s.owner == me and s.kind == kind then
						tile = s.tile
						break
					end
				end
			else
				local W = map.W
				-- nearest my territory's middle
				local sx, sy, cnt = 0, 0, 0
				for k = 0, map.land_count - 1 do
					local t = map:land_tile(k)
					if st:tile_owner(t) == me then
						sx += t % W
						sy += t // W
						cnt += 1
					end
				end
				local cx, cy = sx / math.max(cnt, 1), sy / math.max(cnt, 1)
				local best_d = math.huge
				for k = 0, map.land_count - 1 do
					local t = map:land_tile(k)
					local d = (t % W - cx) ^ 2 + (t // W - cy) ^ 2
					if d < best_d and st:tile_owner(t) == me then
						local inner = true
						for _, nb in map:neighbors4(t) do
							if st:tile_owner(nb) ~= me then
								inner = false
								break
							end
						end
						local clear = inner
						for _, s in st.structures do
							if clear and math.abs(s.tile % W - t % W) + math.abs(s.tile // W - t // W) < 8 then
								clear = false
							end
						end
						if clear then
							tile = t
							best_d = d
						end
					end
				end
			end
			if tile < 0 then
				return "no tile"
			end
			local ui = Main.ui
			if ui == nil or ui.ctx == nil then
				return "no ui"
			end
			local Defs = require(
				game:GetService("ReplicatedStorage"):WaitForChild("Airfront"):WaitForChild("Core"):WaitForChild("Defs")
			) :: any
			ui.ctx:send({ type = "build", kind = Defs.STRUCT_NAMES[kind], tile = tile })
			if words[4] ~= "nofocus" then
				ui.ctx:world_call("focus_tile", { tile })
			end
			return ("build %d at %d"):format(kind, tile)
		elseif op == "boat" then
			-- boat [ratio] [tiles]: a transport ship to the nearest coast (not mine) at least `tiles` (20) away
			if st == nil or st.local_owner == 0 then
				return "not in a match"
			end
			local me = st.local_owner
			local map = st.map
			local W = map.W
			local sx, sy, cnt = 0, 0, 0
			for k = 0, map.land_count - 1 do
				local t = map:land_tile(k)
				if st:tile_owner(t) == me then
					sx += t % W
					sy += t // W
					cnt += 1
				end
			end
			if cnt == 0 then
				return "no land"
			end
			local cx, cy = sx / cnt, sy / cnt
			-- the water my coast touches (a coast on another body has no sea route)
			local bodies = {}
			for k = 0, map.coast_count - 1 do
				local t = map:coast_tile(k)
				if st:tile_owner(t) == me then
					bodies[map:coast_body_of(t)] = true
				end
			end
			local best, best_d = -1, math.huge
			for k = 0, map.coast_count - 1 do
				local t = map:coast_tile(k)
				if st:tile_owner(t) ~= me and bodies[map:coast_body_of(t)] then
					local d = (t % W - cx) ^ 2 + (t // W - cy) ^ 2
					local far = tonumber(words[3]) or 20
					if d > far * far and d < best_d then
						best, best_d = t, d
					end
				end
			end
			if best < 0 then
				return "no coast"
			end
			local ui = Main.ui
			ui.ctx:send({ type = "boat", tile = best, ratio = tonumber(words[2]) or 0.3 })
			ui.ctx:world_call("focus_tile", { best })
			return ("boat to %d (%.0f tiles)"):format(best, math.sqrt(best_d))
		elseif op == "focusunit" then
			-- focusunit <kind>: the camera on the first unit of that kind (Defs.U_*; 3 = train)
			local kind = tonumber(words[2]) or 3
			local ui = Main.ui
			if ui == nil or st == nil then
				return "no ui"
			end
			-- (`focusunit <kind> <zoom> long`: the one with the most of its way sailed, of those with a
			-- route of 120 tiles and more: a long wake to look at)
			local n, pick, best = 0, nil, -1
			for uid, u in st.units do
				if u.kind == kind then
					n += 1
					if words[4] == "long" then
						local d = math.min((st.tick - u.start_tick) * 100 / math.max(u.ticks_per_tile_x100, 1), #u.path)
						if #u.path >= 120 and d < #u.path - 10 and d > best then
							pick, best = u, d
						end
					elseif pick == nil or uid < pick.uid then
						pick = u
					end
				end
			end
			if pick == nil then
				return "none"
			end
			local path = pick.path
			local done = math.max(0, (st.tick - pick.start_tick) * 100 / math.max(pick.ticks_per_tile_x100, 1))
			local tile = path[math.clamp(math.floor(done * (if words[4] == "long" then 0.6 else 1)) + 1, 1, #path)]
			ui.ctx:world_call("focus_tile", { tile, tonumber(words[3]) })
			return ("%d of kind %d; focused uid %d (%d of %d tiles)"):format(n, kind, pick.uid, done, #path)
		elseif op == "myspawn" then
			-- where my capital is drawn (viewport px), to check taps land where the finger is
			if st == nil or st.local_owner == 0 then
				return "not in a match"
			end
			local o = st:get_owner(st.local_owner)
			local t = o and o.spawn_tile or -1
			if t == nil or t < 0 then
				return "no spawn"
			end
			local x, y = Main.world.rig:tile_to_screen(t)
			return ("spawn tile %d drawn at viewport (%.1f, %.1f); tile %.1f px"):format(t, x, y, Main.world.rig.scale)
		elseif op == "focus" then
			local ui = Main.ui
			if ui == nil or st == nil then
				return "no ui"
			end
			ui.ctx:world_call("focus_owner", { tonumber(words[2]) or st.local_owner })
			return "focused"
		elseif op == "party" then
			-- the title's party panel (layout checks): `party` opens it, `party list` the invite list,
			-- `party close` closes both
			local ui = Main.ui
			local pp = ui and ui.title and ui.title._party
			if pp == nil then
				return "no party panel"
			end
			if words[2] == "fake" then
				-- `party fake 30`: the invite list as on a full server
				local fakes = {}
				for i = 1, tonumber(words[3]) or 30 do
					table.insert(fakes, { UserId = -i, DisplayName = "Player" .. i, Name = "Player" .. i })
				end
				local PP = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("PartyPanel")) :: any
				PP.fake_players = fakes
				pp:open_list()
			elseif words[2] == "list" then
				pp:open_list()
			elseif words[2] == "close" then
				pp:close_list()
				pp._open = false
				pp:apply_layout()
			else
				pp._open = true
				pp:apply_layout()
			end
			return ("party visible=%s open=%s state=%s"):format(
				tostring(pp.visible),
				tostring(pp._open),
				tostring(pp.state ~= nil)
			)
		elseif op == "jointeam" then
			-- Quick Play: a seat in the soonest team game (team games on)
			session:join_public("team")
			return "asked for a team game"
		elseif op == "takebig" then
			-- solo only: the local player falls and takes over the nation with the most land (the real
			-- take-over path), to look at a big nation's own label
			local sim = session:local_sim()
			if sim == nil or session.mode ~= 1 or st == nil or st.local_owner == 0 then
				return "not in a solo match"
			end
			local best, id = 0, 0
			for o = 1, sim.owner_total do
				if sim.o_kind[o] == 0 and sim.o_alive[o] == 1 and sim.o_tiles[o] > best then
					best, id = sim.o_tiles[o], o
				end
			end
			if id == 0 then
				return "no nation"
			end
			if sim.o_alive[st.local_owner] == 1 then
				sim:_eliminate(st.local_owner, id)
			end
			return ("take over %d (%s, %d tiles): %s"):format(id, sim.o_name[id], best, tostring(session:take_over(id)))
		elseif op == "feed" then
			-- the event feed's toasts and, with `ally <id>`, an alliance request card (layout checks)
			local ui = Main.ui
			if ui == nil or ui.feed == nil then
				return "no ui"
			end
			local Defs = require(game:GetService("ReplicatedStorage").Airfront.Core.Defs)
			ui.feed:toast(Defs.MSG_GOOD, "You captured a City from Poland")
			ui.feed:toast(Defs.MSG_INFO, "Your warship captured a trade ship from Siberia")
			if words[2] == "ally" and st ~= nil then
				ui.feed:alliance_request(tonumber(words[3]) or 0)
			end
			return "fed"
		elseif op == "gold" then
			-- solo only: set the local player's gold (placement previews, build tests)
			local sim = session:local_sim()
			if sim == nil or session.mode ~= 1 or st == nil or st.local_owner == 0 then
				return "not in a solo match"
			end
			sim.o_gold[st.local_owner] = tonumber(words[2]) or 10000000
			return ("gold %.0f"):format(sim.o_gold[st.local_owner])
		elseif op == "conquer" then
			-- solo only: the local player conquers the owner whose start is nearest its own (or owner
			-- <id>), so the conquest popup (the flag + "+ gold") shows near the camera.
			local sim = session:local_sim()
			if sim == nil or session.mode ~= 1 or st == nil or st.local_owner == 0 then
				return "not in a solo match"
			end
			local me = st.local_owner
			local victim = tonumber(words[2]) or 0
			local mine = sim.o_spawn_tile[me]
			if victim == 0 and mine >= 0 then
				local best = math.huge
				for id = 1, sim.owner_total do
					local t = sim.o_spawn_tile[id]
					if id ~= me and sim.o_alive[id] == 1 and t >= 0 and sim.dist2(t, mine) < best then
						best = sim.dist2(t, mine)
						victim = id
					end
				end
			end
			if victim == 0 then
				return "nobody to conquer"
			end
			local gold = sim.o_gold[victim]
			sim:_eliminate(victim, me)
			return ("conquered %d (%s, gold %.0f)"):format(victim, sim.o_name[victim], gold)
		elseif op == "boot" then
			-- code-fixer: boot order (the title world is requested before the UI is built)
			local b = Main.boot or {}
			local t0 = b.start or 0
			local function ms(k: string): string
				return if b[k] then ("%.0f"):format((b[k] - t0) * 1000) else "-"
			end
			return ("session=%s ui=%s first_state=%s (ms after Main.start)"):format(
				ms("session"),
				ms("ui"),
				ms("first_state")
			)
		elseif op == "audio" then
			local root = game:GetService("SoundService"):FindFirstChild("AirfrontAudio")
			if words[2] == "failtest" and root ~= nil then
				-- a sound of ours that can't load: the load-failure hook names it 4 s later
				local s = Instance.new("Sound")
				s.Name = "Sfx_failtest"
				s.SoundId = "rbxassetid://3"
				s.Parent = root
				s:Play()
				return "log hook " .. tostring(audio._log_conn ~= nil) .. ", a broken sound added"
			end
			local a = root and root:FindFirstChild("MusicA")
			local b = root and root:FindFirstChild("MusicB")
			return ("holding=%s music_on=%s theme=%s A(vol %.3f playing %s t %.1f) B(vol %.3f playing %s t %.1f)"):format(
				tostring(audio.is_holding and audio:is_holding()),
				tostring(audio:is_music_enabled()),
				audio:current_theme(),
				a and a.Volume or -1,
				tostring(a and a.IsPlaying),
				a and a.TimePosition or -1,
				b and b.Volume or -1,
				tostring(b and b.IsPlaying),
				b and b.TimePosition or -1
			)
		elseif op == "uifault" then
			-- code-fixer: inject faults into the live UI frame loop (review_code.md #4)
			local W = require(script.Parent.Parent.UI.Widgets) :: any
			local ui = Main.ui
			local kind = words[2] or "all"
			if kind == "update" or kind == "all" then
				-- a HUD component whose per-frame update throws every frame
				local feed = ui.feed
				feed._diag_update = feed._diag_update or feed.update
				feed.update = function()
					error("diag: EventFeed.update fault")
				end
			end
			if kind == "tween" or kind == "all" then
				local t = ui.top:create_tween()
				t:tween_callback(function()
					error("diag: tween callback fault")
				end)
			end
			if kind == "timer" or kind == "all" then
				W.timer(0.1, function()
					error("diag: timer fault")
				end)
			end
			if kind == "deferred" or kind == "all" then
				W.defer(function()
					error("diag: deferred fault")
				end)
			end
			if kind == "clear" then
				local feed = ui.feed
				if feed._diag_update then
					feed.update = feed._diag_update
					feed._diag_update = nil
				end
			end
			return ("errors caught=%d reported=%d kit step %.3f ms"):format(
				W.errors.caught,
				W.errors.reported,
				W.stats.step_ms
			)
		elseif op == "campan" then
			-- campan [seconds] [zoomed out 0|1]: the camera pans (and zooms in and out) every frame, as a
			-- phone player's thumb does, then the frame times and the map's per-layer costs while it moved
			local world = Main.world
			if world == nil or world.rig == nil then
				return "no map"
			end
			local secs = math.clamp(tonumber(words[2]) or 5, 1, 20)
			if words[3] == "1" then
				world.rig:set_scale_immediate(0)
			end
			local RunService = game:GetService("RunService")
			local t, frames, total, worst = 0.0, 0, 0.0, 0.0
			local conn = RunService.RenderStepped:Connect(function(dt: number)
				t += dt
				frames += 1
				total += dt
				worst = math.max(worst, dt)
				world.rig:pan(Vector2.new(math.cos(t * 0.7), math.sin(t * 0.7)), dt * 0.25)
				world.rig:zoom_by(1 + 0.6 * math.sin(t * 1.3) * dt)
			end)
			task.wait(secs)
			conn:Disconnect()
			local ps = if world.perf_stats then world:perf_stats() else {}
			local keys = {}
			for k in ps do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				return ps[a] > ps[b]
			end)
			local parts = {}
			for _, k in keys do
				table.insert(parts, ("%s %.2f"):format(k, ps[k]))
			end
			return ("moving: fps %.1f  frame avg %.1f ms  worst %.1f | map ms: %s"):format(
				frames / math.max(total, 1e-6),
				total / math.max(frames, 1) * 1000,
				worst * 1000,
				table.concat(parts, "  ")
			)
		elseif op == "prof" then
			-- prof [seconds]: frame times over a window, the map's per-layer costs (EMA ms), the UI
			-- kit's step, the local sim's steps, and how much is on screen / in the state
			local secs = math.clamp(tonumber(words[2]) or 5, 1, 20)
			local RunService = game:GetService("RunService")
			local frames, total, worst = 0, 0.0, 0.0
			local dts = {}
			local conn = RunService.RenderStepped:Connect(function(dt: number)
				frames += 1
				total += dt
				worst = math.max(worst, dt)
				table.insert(dts, dt)
			end)
			local perf = session.perf
			local steps0, step_s0 = perf.steps, perf.step_s
			perf.step_s_max = 0
			task.wait(secs)
			conn:Disconnect()
			table.sort(dts)
			local p95 = dts[math.max(1, math.floor(#dts * 0.95))] or 0
			local out = {}
			table.insert(
				out,
				("fps %.1f  frame avg %.1f ms  p95 %.1f  worst %.1f"):format(
					frames / math.max(total, 1e-6),
					total / math.max(frames, 1) * 1000,
					p95 * 1000,
					worst * 1000
				)
			)
			local ns = perf.steps - steps0
			table.insert(
				out,
				("sim steps %d (%.1f/s)  avg %.2f ms  max %.2f ms"):format(
					ns,
					ns / secs,
					if ns > 0 then (perf.step_s - step_s0) / ns * 1000 else 0,
					perf.step_s_max * 1000
				)
			)
			local W = require(script.Parent.Parent.UI.Widgets) :: any
			table.insert(out, ("ui kit step %.2f ms"):format(W.stats.step_ms))
			local okS, Stats = pcall(function()
				return game:GetService("Stats")
			end)
			if okS then
				local function rd(k: string): string
					local ok, v = pcall(function()
						return (Stats :: any)[k]
					end)
					return if ok and type(v) == "number" then ("%.2f"):format(v) else "-"
				end
				table.insert(
					out,
					("engine: render cpu %s ms  gpu %s ms  heartbeat %s ms  frame %s  instances %s  mem %s MB"):format(
						rd("RenderCPUFrameTime"),
						rd("RenderGPUFrameTime"),
						rd("HeartbeatTimeMs"),
						rd("FrameTime"),
						rd("InstanceCount"),
						(function()
							local ok, v = pcall(function()
								return Stats:GetTotalMemoryUsageMb()
							end)
							return if ok then ("%.0f"):format(v) else "-"
						end)()
					)
				)
			end
			local world = Main.world
			if world ~= nil and world.perf_stats then
				local ps = world:perf_stats()
				local keys = {}
				for k in ps do
					table.insert(keys, k)
				end
				table.sort(keys, function(a, b)
					return ps[a] > ps[b]
				end)
				local parts = {}
				for _, k in keys do
					table.insert(parts, ("%s %.2f"):format(k, ps[k]))
				end
				table.insert(out, "map ms: " .. table.concat(parts, "  "))
			end
			if st ~= nil then
				local alive, units, structs, attacks, nukes, roads = 0, 0, 0, 0, 0, 0
				for _, o in st.owners do
					if o.alive and o.tiles > 0 then
						alive += 1
					end
				end
				for _ in st.units do
					units += 1
				end
				for _ in st.structures do
					structs += 1
				end
				for _ in st.attacks do
					attacks += 1
				end
				for _ in st.nukes do
					nukes += 1
				end
				for _ in st.roads or {} do
					roads += 1
				end
				table.insert(
					out,
					("state: owners %d  units %d  structures %d  attacks %d  nukes %d  roads %d  tick %d"):format(
						alive,
						units,
						structs,
						attacks,
						nukes,
						roads,
						st.tick
					)
				)
			end
			local function count_gui(root: Instance?): (number, number)
				if root == nil then
					return 0, 0
				end
				local n, vis = 0, 0
				for _, d in root:GetDescendants() do
					if d:IsA("GuiObject") then
						n += 1
						if d.Visible then
							vis += 1
						end
					end
				end
				return n, vis
			end
			local pg = player:FindFirstChildOfClass("PlayerGui")
			local mn, mv = 0, 0
			local parts = {}
			for _, name in { "RofrontMap", "RofrontMapUnits", "RofrontMapLabels" } do
				local n1, v1 = count_gui(pg and pg:FindFirstChild(name))
				mn += n1
				mv += v1
				table.insert(parts, tostring(n1))
			end
			local an, av = count_gui(pg)
			table.insert(
				out,
				("gui objects: map %d = %s (%d visible)  all %d (%d visible)"):format(
					mn,
					table.concat(parts, " + "),
					mv,
					an,
					av
				)
			)
			table.insert(out, ("lua heap %.0f MB"):format(collectgarbage("count") / 1024))
			return table.concat(out, "\n")
		elseif op == "mem" then
			-- mem: the biggest buffers / array tables held by the session's sim, state, map and the
			-- map view's surface (bytes estimated: buffers exact, arrays 16 B per slot)
			local rows = {}
			local seen = {}
			local function scan(label: string, obj: any, depth: number)
				if type(obj) ~= "table" or seen[obj] or depth > 1 then
					return
				end
				seen[obj] = true
				for k, v in obj do
					if type(k) ~= "string" then
						continue
					end
					if type(v) == "buffer" then
						table.insert(rows, { label .. "." .. k, buffer.len(v) })
					elseif type(v) == "table" and not seen[v] then
						local n = #v
						if n > 5000 then
							table.insert(rows, { label .. "." .. k, n * 16 })
						else
							local c = 0
							for _ in v do
								c += 1
								if c > 200000 then
									break
								end
							end
							if c > 5000 then
								table.insert(rows, { label .. "." .. k .. " (dict)", c * 40 })
							end
						end
						if depth < 1 and getmetatable(v) == nil and n == 0 then
							scan(label .. "." .. k, v, depth + 1)
						end
					end
				end
			end
			scan("sim", session._sim, 0)
			scan("state", session.state, 0)
			scan("map", session.state and session.state.map, 0)
			local world = Main.world
			scan("view", world, 0)
			scan("surface", world and world.surface, 0)
			table.sort(rows, function(a, b)
				return a[2] > b[2]
			end)
			local out = { ("lua heap %.0f MB"):format(collectgarbage("count") / 1024) }
			local total = 0
			for _, r in rows do
				total += r[2]
			end
			table.insert(out, ("listed total %.0f MB in %d items"):format(total / 1048576, #rows))
			for i = 1, math.min(25, #rows) do
				table.insert(out, ("%7.2f MB  %s"):format(rows[i][2] / 1048576, rows[i][1]))
			end
			return table.concat(out, "\n")
		elseif op == "uistats" then
			local W = require(script.Parent.Parent.UI.Widgets) :: any
			return ("errors caught=%d reported=%d time=%.2f"):format(W.errors.caught, W.errors.reported, W.time)
		elseif op == "gf" then
			-- gameplay-fixer probe (review_gameplay.md verification)
			local P = script.Parent:FindFirstChild("GameplayFixerProbe")
			return if P then (require :: any)(P).run(Main, words) else "no probe"
		elseif op == "r2" then
			-- r2-code-fixer probe (review_code.md Round 2 verification)
			local P = script.Parent:FindFirstChild("R2FixProbe")
			return if P then (require :: any)(P).run(Main, words) else "no probe"
		elseif op == "pf" then
			-- polish-fixer probe (round-2 polish items)
			local P = script.Parent:FindFirstChild("PolishFixProbe")
			return if P then (require :: any)(P).run(Main, words) else "no probe"
		else
			return "unknown " .. tostring(op)
		end
		return "ok " .. cmd
	end
	player:GetAttributeChangedSignal("af_cmd"):Connect(function()
		local cmd = player:GetAttribute("af_cmd")
		if type(cmd) ~= "string" or cmd == "" then
			return
		end
		player:SetAttribute("af_cmd", "")
		local ok, res = pcall(run, cmd)
		player:SetAttribute("af_cmd_result", if ok then res else "error: " .. tostring(res))
	end)
	-- Grid hash every 100 ticks (compare with the server's af_srv_hash at the same tick).
	local function grid_hash(st: any): number
		local b = st.owner
		local h = 0
		for i = 0, 1024 * 512 - 1, 1 do
			local v = buffer.readi32(b, i * 4)
			if v ~= 0 then
				h = (h + v * (i % 9973 + 1)) % 2147483647
			end
		end
		return h
	end
	local hooked = nil
	session.state_ready:Connect(function(st)
		if hooked then
			hooked:Disconnect()
		end
		hooked = st.ticked:Connect(function(tick)
			if session.mode == 2 and tick % 100 == 0 then
				player:SetAttribute("af_hash", ("%d:%d"):format(tick, grid_hash(st)))
			end
		end)
	end)
	-- Frame-time watch: worst frame and frames over 20 ms per second.
	local RunService = game:GetService("RunService")
	local worst, slow, frames = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt)
		frames += 1
		worst = math.max(worst, dt)
		if dt > 0.020 then
			slow += 1
		end
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			local s = session.state
			local perf = session.perf
			player:SetAttribute("af_mode", session.mode)
			player:SetAttribute("af_screen", (Main.ui and Main.ui.screen and Main.ui:screen()) or "title")
			player:SetAttribute("af_tick", if s then s.tick else -1)
			player:SetAttribute("af_render_tick", if s then s.render_tick else -1)
			player:SetAttribute("af_phase", if s then s.phase else -1)
			player:SetAttribute("af_owner", if s then s.local_owner else 0)
			local me = s and s.local_owner ~= 0 and s:get_owner(s.local_owner)
			player:SetAttribute("af_my_tiles", if me then me.tiles else 0)
			player:SetAttribute("af_building", session:is_building())
			player:SetAttribute("af_speed", session.local_speed)
			player:SetAttribute("af_paused", session.paused)
			player:SetAttribute("af_steps", perf.steps)
			player:SetAttribute("af_step_ms_avg", if perf.steps > 0 then perf.step_s / perf.steps * 1000 else 0)
			player:SetAttribute("af_step_ms_max", perf.step_s_max * 1000)
			player:SetAttribute("af_build_ms_total", perf.build_s * 1000)
			player:SetAttribute("af_build_slice_ms_max", perf.build_slice_max * 1000)
			player:SetAttribute("af_build_frames", perf.build_frames)
			local lb = perf.last_build
			if lb then
				player:SetAttribute(
					"af_last_build",
					("%.0f ms over %d frames, longest slice %.1f ms"):format(lb.ms, lb.frames, lb.slice_max_ms)
				)
			end
			player:SetAttribute(
				"af_lobby",
				("%s %.1f %d"):format(
					session.lobby.stage,
					session.lobby.countdown_s or 0,
					#(session.lobby.players or {})
				)
			)
			player:SetAttribute("af_mp", session:multiplayer_status())
			player:SetAttribute("af_music", audio:is_music_enabled())
			player:SetAttribute("af_theme", audio:current_theme())
			player:SetAttribute("af_frame_worst_ms", worst * 1000)
			player:SetAttribute("af_frames_slow", slow)
			player:SetAttribute("af_fps", frames)
			worst, slow, frames = 0, 0, 0
			perf.step_s_max = 0
		end
	end)
end

return Diag
