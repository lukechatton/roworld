--!nonstrict
-- gameplay-fixer dev probe (never in the shipped flow): read-only UI/world state plus a few test
-- levers for docs/review_gameplay.md verification. Reached through Dev/SessionDiag (workspace
-- attribute AF_DIAG = true): LocalPlayer attribute af_cmd = "gf <op> ..." -> af_cmd_result.
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")

local Probe = {}

local function W_scale(): number
	local ok, W = pcall(function()
		return require(script.Parent.Parent.UI.Widgets) :: any
	end)
	return if ok then W.scale() else -1
end

local function r2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

--- Logical kit rect -> user_mouse_input coordinates (viewport px minus the top-bar inset).
local function mouse_rect(ctx: any, r: Rect): { number }
	local a = ctx:to_view(r.Min) - GuiService:GetGuiInset()
	local b = ctx:to_view(r.Max) - GuiService:GetGuiInset()
	return { r2(a.X), r2(a.Y), r2(b.X), r2(b.Y) }
end

local function node_rect(ctx: any, n: any): any
	if n == nil or n.get_global_rect == nil then
		return nil
	end
	local ok, r = pcall(function()
		return n:get_global_rect()
	end)
	if not ok then
		return nil
	end
	return {
		vis = n:is_visible_in_tree(),
		mouse = mouse_rect(ctx, r),
		logical = { r2(r.Min.X), r2(r.Min.Y), r2(r.Max.X), r2(r.Max.Y) },
	}
end

--- A land tile owned by `id` (label tile first), or -1.
local function tile_of(st: any, id: number): number
	local t = st:label_tile(id)
	if t >= 0 then
		return t
	end
	for _, lt in st.map.land_tiles do
		if st:tile_owner(lt) == id then
			return lt
		end
	end
	return -1
end

function Probe.run(Main: any, words: { string }): string
	local op = words[2] or "state"
	local session = Main.session
	local ui = Main.ui
	local world = Main.world
	local ctx = ui and ui.ctx
	local st = session.state
	local sim = session:local_sim()
	local me = if st ~= nil then st.local_owner else 0
	if op == "state" then
		local o = {
			screen = ui and ui:screen(),
			mode = session.mode,
			phase = st and st.phase,
			tick = st and st.tick,
			me = me,
			vp = ctx and { ctx.vp.X, ctx.vp.Y },
			compact = ctx and ctx.compact,
			scale = ctx and ui.root and ui.root.scale,
			viewport = { workspace.CurrentCamera.ViewportSize.X, workspace.CurrentCamera.ViewportSize.Y },
			inset = { GuiService:GetGuiInset().X, GuiService:GetGuiInset().Y },
			over = ui and {
				open = ui.over.is_open,
				visible = ui.over.visible,
				kind = ui.over._kind,
				a = ui.over.modulate_a,
				title = ui.over._title.text,
			},
			hover = world and world.input._hover_tile,
			tooltip = ui and ui.tooltip:is_shown(),
			coach = ui and {
				current = ui.coach.current,
				card = node_rect(ctx, ui.coach._card),
				point = { r2(ui.coach._point.X), r2(ui.coach._point.Y) },
				arrow = ui.coach._arrow.Visible,
			},
			pause = ui and {
				open = ui.pause.is_open,
				confirm = ui.pause._confirm.visible,
				text = ui.pause._confirm_text.text,
				panel = node_rect(ctx, ui.pause._panel),
				label = node_rect(ctx, ui.pause._confirm_text),
			},
			clock = ui and ui.top._clock.text,
			phase_label = ui and ui.top._phase.text,
			target_card = ui and {
				open = ui.target_card.is_open,
				kind = ui.target_card.kind,
				confirming = ui.target_card.confirming,
				age = r2(ui.target_card._age),
			},
			rig = world and { lat = r2(world.rig.lat), lon = r2(world.rig.lon), dist = r2(world.rig.dist) },
			gold = st and me ~= 0 and st:get_owner(me) and st:get_owner(me).gold,
			troops = st and me ~= 0 and st:get_owner(me) and st:get_owner(me).troops,
		}
		return HttpService:JSONEncode(o)
	elseif op == "rect" then
		-- gf rect bar|top|board|attacks|coach|tray|donate|go|keep|break|pause_go|over_again
		local what = words[3]
		local map = {
			bar = ui.bar.panel,
			top = ui.top.panel,
			board = ui.board.panel,
			attacks = ui.attacks.panel,
			coach = ui.coach._card,
			tray = ui.bar.tray,
			card = ui.target_card._panel,
			donate = ui.target_card._donate,
			go = ui.target_card._go,
			keep = ui.target_card._keep,
			["break"] = ui.target_card._break_only,
			pause = ui.pause._panel,
			leave = ui.pause._leave,
			restart = ui.pause._restart,
			over_again = ui.over._again,
			over_spec = ui.over._spec,
			m_stats = ui.bar._m_stats,
		}
		return HttpService:JSONEncode(node_rect(ctx, map[what]) or {})
	elseif op == "tilepos" then
		-- gf tilepos <owner id | "me"> : user_mouse_input position of one of their tiles
		local id = if words[3] == "me" then me else tonumber(words[3]) or 0
		local t = if words[4] then tonumber(words[4]) else tile_of(st, id)
		local p = world:screen_pos_of_tile(t)
		local m = p - GuiService:GetGuiInset()
		return HttpService:JSONEncode({ tile = t, view = { r2(p.X), r2(p.Y) }, mouse = { r2(m.X), r2(m.Y) } })
	elseif op == "pick" then
		-- gf pick x y (mouse coords) -> tile + owner under that point
		local p = Vector2.new(tonumber(words[3]) or 0, tonumber(words[4]) or 0) + GuiService:GetGuiInset()
		local t = world:tile_at_screen(p)
		return HttpService:JSONEncode({ tile = t, owner = if t >= 0 then st:tile_owner(t) else -1 })
	elseif op == "endtime" then
		if sim == nil then
			return "no local sim"
		end
		sim.time_limit_ticks = sim.tick + (tonumber(words[3]) or 3)
		return "time limit at " .. sim.time_limit_ticks
	elseif op == "gold" then
		sim.o_gold[me] = tonumber(words[3]) or 1e7
		return "gold " .. sim.o_gold[me]
	elseif op == "troops" then
		local id = if words[3] == "me" then me else tonumber(words[3]) or 0
		sim.o_troops[id] = tonumber(words[4]) or 1e5
		return "troops " .. id .. " " .. sim.o_troops[id]
	elseif op == "neighbors" then
		-- nations bordering me: id, name, troops, max_troops
		local seen, out = {}, {}
		for _, t in st.map.land_tiles do
			if st:tile_owner(t) == me then
				for _, n in st.map:neighbors4(t) do
					local o = st:tile_owner(n)
					if o ~= 0 and o ~= me and not seen[o] then
						seen[o] = true
						local info = st:get_owner(o)
						table.insert(out, {
							id = o,
							name = info.name,
							kind = info.kind,
							troops = info.troops,
							max = info.max_troops,
							ally = st:are_allies(me, o),
						})
					end
				end
			end
		end
		return HttpService:JSONEncode(out)
	elseif op == "ally" then
		-- gf ally <id>: form an alliance (request + accept through the Sim's own rules)
		local id = tonumber(words[3]) or 0
		sim:ally_request(me, id)
		local ok = sim:ally_reply(id, me, true)
		return "ally " .. id .. " " .. tostring(ok) .. " allied=" .. tostring(sim:allied(me, id))
	elseif op == "speed" then
		session.local_speed = tonumber(words[3]) or 1
		return "speed " .. session.local_speed
	elseif op == "cam" then
		local rig = world.rig
		rig.lat = tonumber(words[3]) or rig.lat
		rig.lon = tonumber(words[4]) or rig.lon
		if words[5] then
			rig:set_distance_immediate(tonumber(words[5]) :: number)
		end
		rig:_apply()
		return "cam"
	elseif op == "coachpt" then
		-- gf coachpt <x> <y> (mouse coords) [id]: offer a tip pointing at that screen point
		local mp = Vector2.new(tonumber(words[3]) or 0, tonumber(words[4]) or 0) + GuiService:GetGuiInset()
		local lp = ctx:to_logical(mp)
		local id = words[5] or "contact"
		ui.coach:reset()
		ui.coach:offer(id, function()
			return lp
		end, "Vietnam")
		return "offered " .. id .. " at logical " .. tostring(lp)
	elseif op == "coach" then
		-- gf coach reset: forget seen tips
		ui.coach:reset()
		return "coach reset"
	elseif op == "sfxlog" then
		-- IsLoaded of every SFX voice at the moment it starts playing (P2-7)
		local root = game:GetService("SoundService"):FindFirstChild("AirfrontAudio")
		if words[3] == "arm" then
			Probe._sfx = {}
			for _, s in root:GetDescendants() do
				if s:IsA("Sound") and string.sub(s.Name, 1, 3) == "Sfx" then
					s.Played:Connect(function()
						table.insert(
							Probe._sfx,
							string.format("%s:%s:%s", s.Name, tostring(s.IsLoaded), tostring(s.TimeLength > 0))
						)
					end)
				end
			end
			return "armed"
		end
		local n = 0
		if root then
			for _, s in root:GetDescendants() do
				if s:IsA("Sound") then
					n += 1
				end
			end
		end
		return string.format("sounds=%d log=%s", n, table.concat(Probe._sfx or {}, " "))
	elseif op == "askleave" then
		-- gf askleave [mp]: open the game menu's surrender confirm (optionally with the MP copy)
		if not ui.pause.is_open then
			ui:open_pause_menu()
		end
		local old, old_sm = ctx.mode, ctx.state_mode
		if words[3] == "mp" then
			ctx.mode = function()
				return 2
			end
			ctx.state_mode = 2
		end
		local ok, err = pcall(function()
			ui.pause:_ask_leave()
		end)
		ctx.mode = old
		ctx.state_mode = old_sm
		local lbl = ui.pause._confirm_text
		local tl = lbl._tl
		return HttpService:JSONEncode({
			ok = ok,
			err = tostring(err),
			text = lbl.text,
			label = node_rect(ctx, lbl),
			panel = node_rect(ctx, ui.pause._panel),
			min = { lbl:get_combined_minimum_size().X, lbl:get_combined_minimum_size().Y },
			size = { lbl.size.X, lbl.size.Y },
			bounds = tl and { tl.TextBounds.X, tl.TextBounds.Y, tl.AbsoluteSize.X, tl.AbsoluteSize.Y, tl.TextSize }
				or "no _tl",
			scale = W_scale(),
		})
	elseif op == "timebind" then
		-- gf timebind: time every synchronous piece of the next state_ready rebind (P2-9)
		Probe._times = {}
		local function wrap(obj: any, name: string, label: string)
			if obj == nil or type(obj[name]) ~= "function" then
				return
			end
			local orig = obj[name]
			obj[name] = function(...)
				local t0 = os.clock()
				local r = table.pack(orig(...))
				table.insert(Probe._times, string.format("%s %.2f", label, (os.clock() - t0) * 1000))
				return table.unpack(r, 1, r.n)
			end
		end
		wrap(world, "bind_state", "world.bind_state")
		wrap(world, "unbind", "world.unbind")
		wrap(world.territory, "bind", "territory.bind")
		wrap(world.territory, "unbind", "territory.unbind")
		wrap(world.globe, "bind_textures", "globe.bind_textures")
		for _, k in { "roads", "ranges", "icons", "units", "fx", "combat", "labels" } do
			wrap(world[k], "bind", k .. ".bind")
			wrap(world[k], "unbind", k .. ".unbind")
		end
		wrap(ui, "_on_state_ready", "ui._on_state_ready")
		wrap(ui, "_bind_state", "ui._bind_state")
		wrap(ui, "_apply_screen", "ui._apply_screen")
		wrap(ui.title, "on_show", "title.on_show")
		return "wrapped"
	elseif op == "times" then
		return table.concat(Probe._times or {}, "; ")
	elseif op == "bootabs" then
		local b = Main.boot or {}
		local out = {}
		for k, v in b do
			table.insert(out, string.format("%s=%.3f", k, v))
		end
		table.sort(out)
		local wb = {}
		for _, e in (world and world.boot_ms) or {} do
			table.insert(wb, string.format("%s %.1f", e[1], e[2]))
		end
		return table.concat(out, " ") .. " | world: " .. table.concat(wb, ", ")
	elseif op == "key" then
		-- gf key One: the UIInteract hotkey handler as a real keypress reaches it (gp = false)
		local kc = (Enum.KeyCode :: any)[words[3] or "One"]
		local handled = ui.interact:_on_key(kc, false)
		return string.format("handled=%s aim=%s", tostring(handled), tostring(ui.interact.aim_kind))
	elseif op == "perf" then
		local p = session.perf
		return HttpService:JSONEncode(p and p.last_build or {})
	end
	return "unknown gf op " .. tostring(op)
end

return Probe
