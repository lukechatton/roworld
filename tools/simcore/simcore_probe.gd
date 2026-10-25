extends Node
## sim-core probe (lives only in a scratch COPY of the project): dumps deterministic Sim facts as JSON
## for tests/sim_parity.luau in the Roblox port.

func _ready() -> void:
	var out := {}
	var map := WorldMap.shared()
	var sim := Sim.new(map, {"seed": 1, "difficulty": 1, "tribes": 0, "max_humans": 1})
	# nations: colours and tile counts after the deterministic capital spawns
	var cols := []
	var tiles := []
	var spawn := []
	for id in range(1, sim.owner_total + 1):
		cols.append(sim.o_color[id])
		tiles.append(sim.o_tiles[id])
		spawn.append(sim.o_spawn_tile[id])
	out["nation_colors"] = cols
	out["nation_tiles"] = tiles
	out["nation_spawn"] = spawn
	var owned := []
	for t in Defs.TILE_COUNT:
		if sim.owner[t] != 0:
			owned.append(t * 1024 + sim.owner[t])
	out["owned"] = owned
	var border := []
	for id in range(1, 11):
		border.append(sim.bcount[id])
	out["bcount"] = border
	out["human_palette"] = Array(SimColors.human_palette())
	out["tribe_palette"] = Array(SimColors.tribe_palette())
	var labs := []
	for c in [0xff0000ff, 0x00ff00ff, 0x3366ccff, 0x719bfaff, 0xffd23fff]:
		var l := SimColors.oklab(c)
		labs.append([l.x, l.y, l.z])
	out["oklab"] = labs
	# human colour at a few starts (depends only on the deterministic nations)
	var hid := sim.add_human("p", "P")
	var hc := []
	for t in [256574, 145 * 1024 + 300, 110 * 1024 + 530, 300 * 1024 + 800]:
		hc.append(SimColors.for_human(sim, hid, t, 120))
	out["human_colors"] = hc
	# nav paths between deterministic coastal pairs
	var nav := sim.nav
	var ct := map.coast_tiles
	var paths := []
	for i in 40:
		var a := ct[(i * 7919) % ct.size()]
		var b := ct[(i * 104729 + 17) % ct.size()]
		var body := map.coast_body[a]
		if map.coast_body[b] != body:
			paths.append([a, b, -1])
			continue
		var wa := nav.water_next_to(a, body)
		var wb := nav.water_next_to(b, body)
		var p := nav.find_path(wa, wb)
		var mid := p[p.size() / 2] if p.size() > 0 else -1
		paths.append([a, b, p.size(), wa, wb, mid])
	out["paths"] = paths
	out["regions"] = nav.reg_count
	# disk sizes
	var disks := []
	for i in 30:
		var c := (i * 97 + 3) % 512 * 1024 + (i * 331) % 1024
		var r := 1.5 + float(i) * 1.7
		disks.append([c, r, sim.disk_tiles(c, r, false).size(), sim.disk_tiles(c, r).size()])
	out["disks"] = disks
	# Rules samples
	var rs := []
	for k in 3:
		for tl in [0, 1, 50, 1000, 30000]:
			rs.append(Rules.max_troops(k, tl, 2, 1))
			rs.append(Rules.troop_growth(k, 50000.0 + tl, 200000.0, 1))
	rs.append(Rules.trade_gold(123))
	rs.append(Rules.train_spawn_rate(3, 40.0))
	rs.append(Rules.trade_spawn_rate(2, 150.0))
	rs.append(Rules.sam_range_at(3, 20))
	rs.append(Rules.large_territory_bonus(123456.0, 0.7))
	rs.append(Rules.warhead_death(300000.0, 1000000.0))
	out["rules"] = rs
	out["format"] = [Defs.format_troops(12345.0), Defs.format_troops(1234567.0), Defs.format_troops(99999.9), Defs.format_troops(-5.5), Defs.format_troops(9999999.0), Defs.format_troops(12350.0)]
	var f := FileAccess.open(OS.get_environment("PROBE_OUT"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("PROBE done")
	get_tree().quit(0)
