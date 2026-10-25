extends Node
## sim-parity: lockstep trace of the ORIGINAL Sim. Copy this file (and lockstep.tscn) into the tests/
## folder of a scratch copy of ~/games/airfront (never the original) and run headless:
##   LS_SEED=1 LS_TICKS=9000 LS_OUT=/path/orig.txt "$AE" --headless --path <copy> \
##       --scene res://tests/parity_lockstep.tscn --quit-after 100000000
## env: LS_SEED, LS_TICKS, LS_TRIBES (80), LS_DIFF (1), LS_HUMAN (0 = AI only, 1 = passive human,
## 2 = scripted human sending every kind of intent), LS_OUT, LS_LOG_FROM/LS_LOG_TO/LS_RNGLOG (traced
## copy only). One line per tick: tick, RNG state, claimed tiles, live attacks, owner-tile checksum,
## troops sum, nukes, structures, roads, units, delta hash (events, tiles, flags, stats).
## tools/parity/lockstep.luau prints the same for the port with GodotRng injected; the first
## differing line pinpoints where the two simulations part ways.

var sim: Sim
var hid := 0
var hid_b := 0
var hid_c := 0
var lcg := 12345


func _env(k: String, d: int) -> int:
	return int(OS.get_environment(k)) if OS.get_environment(k) != "" else d


func _ready() -> void:
	var seed_v := _env("LS_SEED", 1)
	var ticks := _env("LS_TICKS", 600)
	var tribes := _env("LS_TRIBES", 80)
	var diff := _env("LS_DIFF", 1)
	var human := _env("LS_HUMAN", 0)
	var out := OS.get_environment("LS_OUT")
	var map := WorldMap.shared()
	var cfg := {"seed": seed_v, "difficulty": diff, "tribes": tribes, "max_humans": 1 if human > 0 else 0, "time_limit_s": 0}
	if human == 3:
		# Multiplayer: 4 slots, spawn phase, 15 min limit (see _mp_script).
		cfg = {"seed": seed_v, "difficulty": diff, "tribes": tribes, "max_humans": 4, "time_limit_s": 900}
	sim = Sim.new(map, cfg)
	var f := FileAccess.open(out, FileAccess.WRITE)
	var ck := 0
	for id in range(1, sim.owner_total + 1):
		ck += sim.o_tiles[id] * id
	f.store_line("init %d owners %d ck %d" % [sim.rng.state, sim.owner_total, ck])
	if human == 3:
		hid = sim.add_human("alpha", "Alpha")
		hid_b = sim.add_human("bravo", "Bravo")
		var st0 := _find_start(map)
		sim.submit(hid, {"type": "spawn", "tile": st0})
		f.store_line("mp humans %d %d start %d" % [hid, hid_b, st0])
	elif human > 0:
		hid = sim.add_human("bench", "Bench Commander")
		var st := _find_start(map)
		var ok := sim.human_start(hid, st)
		f.store_line("human %d start %d ok %s" % [hid, st, str(ok).to_lower()])
	var log_from := _env("LS_LOG_FROM", -1)
	var log_to := _env("LS_LOG_TO", -1)
	var tr_script: Script = load("res://scripts/core/trace_rng.gd") if ResourceLoader.exists("res://scripts/core/trace_rng.gd") else null
	if tr_script != null:
		tr_script.set("log_from", log_from)
		tr_script.set("log_to", log_to)
	var dump_from := _env("LS_DUMP_FROM", -1)
	var dump_to := _env("LS_DUMP_TO", -1)
	var dumps := PackedStringArray()
	for i in ticks:
		if tr_script != null:
			tr_script.set("cur_tick", sim.tick + 1)
		if human == 2 or human == 3:
			_policy()
		if human == 3:
			_mp_script(f)
		var d := sim.step()
		if sim.tick >= dump_from and sim.tick <= dump_to:
			_dump(d, dumps)
		var claimed := 0
		var cks := 0
		var tr := 0.0
		for id in range(1, sim.owner_total + 1):
			if sim.o_alive[id] == 1:
				claimed += sim.o_tiles[id]
			cks += sim.o_tiles[id] * id
			tr += sim.o_troops[id]
		var live := 0
		for a in sim.attacks:
			if not a.dead:
				live += 1
		f.store_line("%d %d %d %d %d %d %d %d %d %d %d" % [sim.tick, sim.rng.state, claimed, live, cks, int(tr), sim.nukes_launched,
			sim.structs.size(), sim.roads.size(), sim.units.size(), _dhash(d)])
	f.close()
	if OS.get_environment("LS_RNGLOG") != "":
		var g := FileAccess.open(OS.get_environment("LS_RNGLOG"), FileAccess.WRITE)
		if tr_script != null:
			for l: String in tr_script.get("lines"):
				g.store_line(l)
		for l in dumps:
			g.store_line(l)
		g.close()
	get_tree().quit(0)


# ---------------------------------------------------------------------------------------------
# Delta hash: every event field, tile/flag change and stats row (numbers as floor(x * 1000)).
# ---------------------------------------------------------------------------------------------

const HM := 1000000007


func _hv(h: int, v: Variant) -> int:
	match typeof(v):
		TYPE_BOOL:
			return (h * 31 + (1 if v else 0) + 7) % HM
		TYPE_INT, TYPE_FLOAT:
			var x := int(floor(float(v) * 1000.0))
			return (h * 1000003 + posmod(x, HM) + 11) % HM
		TYPE_STRING, TYPE_STRING_NAME:
			var hh := (h * 17 + 3) % HM
			for b in String(v).to_utf8_buffer():
				hh = (hh * 257 + b + 1) % HM
			return hh
		TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_BYTE_ARRAY:
			var hh := (h * 13 + 5) % HM
			for e: Variant in v:
				hh = _hv(hh, e)
			return (hh * 7 + 9) % HM
	return (h * 3 + 1) % HM


func _fmt(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_INT, TYPE_FLOAT:
			return str(int(floor(float(v) * 1000.0)))
		TYPE_STRING, TYPE_STRING_NAME:
			return "'" + String(v) + "'"
		TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_BYTE_ARRAY:
			var parts := PackedStringArray()
			for e: Variant in v:
				parts.append(_fmt(e))
			return "[" + " ".join(parts) + "]"
	return "?"


## Delta dump (LS_DUMP_FROM..LS_DUMP_TO) into the RNG log: one line per event + tiles/flags/stats.
func _dump(d: Dictionary, lines: PackedStringArray) -> void:
	for e: Array in d["ev"]:
		lines.append("%d EV %s" % [sim.tick, _fmt(_norm(e))])
	lines.append("%d TILES %s" % [sim.tick, _fmt(d["tiles"])])
	lines.append("%d FLAGS %s" % [sim.tick, _fmt(d["flags"])])
	if d.has("stats"):
		lines.append("%d STATS %s" % [sim.tick, _fmt(d["stats"])])


## Godot keeps RGBA8 colours in PackedInt32Arrays, so OWNER_ADD carries some of them as negative
## ints; the port always sends them unsigned (GameState accepts both): compare them unsigned.
func _norm(e: Array) -> Array:
	if int(e[0]) == Ev.OWNER_ADD:
		var c := e.duplicate()
		c[3] = int(c[3]) & 0xFFFFFFFF
		return c
	return e


func _dhash(d: Dictionary) -> int:
	var h := 1
	for e: Array in d["ev"]:
		h = _hv(h, _norm(e))
	h = _hv(h, d["tiles"])
	h = _hv(h, d["flags"])
	if d.has("stats"):
		h = _hv(h, d["stats"])
	return h


# ---------------------------------------------------------------------------------------------
# Deterministic human (no Sim RNG): same policy as lockstep.luau.
# ---------------------------------------------------------------------------------------------

func _rand() -> int:
	lcg = (lcg * 16807) % 2147483647
	return lcg


func _find_start(map: WorldMap) -> int:
	var c := map.latlon_to_tile(2.0, 22.0)
	var cx := c & 1023
	var cy := c >> 10
	for r in range(0, 80):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var y := cy + dy
				if y < 1 or y >= Defs.H - 1:
					continue
				var t := y * Defs.W + ((cx + dx) & 1023)
				if sim.land[t] == 1 and sim.owner[t] == 0 and _free_around(t, 7):
					return t
	return map.land_tiles[0]


## Multiplayer script: Bravo never picks (random start at spawn end) and leaves 5 min in;
## Charlie joins 2 min in on the first unowned claimable tile found from (−20°, 130°).
func _mp_script(f: FileAccess) -> void:
	if sim.phase != Defs.PHASE_PLAYING:
		return
	var age := sim.tick + 1 - sim.playing_since
	if age == 1200 and hid_c == 0:
		hid_c = sim.add_human("charlie", "Charlie")
		var c := sim.map.latlon_to_tile(-20.0, 130.0)
		var found := -1
		for k in 200000:
			var t := (c + k * 7) % Defs.TILE_COUNT
			if sim.land[t] == 1 and sim.owner[t] == 0 and (sim.flags[t] & 1) == 0:
				found = t
				break
		if found >= 0:
			sim.submit(hid_c, {"type": "spawn", "tile": found})
		f.store_line("mp charlie %d tile %d" % [hid_c, found])
	if age == 3000 and hid_b > 0:
		sim.remove_human(hid_b)


func _free_around(t: int, r: int) -> bool:
	var cx := t & 1023
	var cy := t >> 10
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var y := clampi(cy + dy, 0, Defs.H - 1)
			if sim.owner[y * Defs.W + ((cx + dx) & 1023)] != 0:
				return false
	return true


## Up to 64 contact tiles (land next to the human's border, not the human's), border-list order.
func _contacts() -> PackedInt32Array:
	var out := PackedInt32Array()
	var b := sim.bhead[hid]
	var steps := 0
	while b != -1 and steps < 400 and out.size() < 64:
		var row := b & -1024
		var x := b & 1023
		for n: int in [row | ((x + 1023) & 1023), row | ((x + 1) & 1023), b - Defs.W if b >= Defs.W else -1, b + Defs.W if b < Defs.TILE_COUNT - Defs.W else -1]:
			if n >= 0 and sim.land[n] == 1 and sim.owner[n] != hid and not out.has(n):
				out.append(n)
		b = sim.bnext[b]
		steps += 1
	return out


func _own_tile() -> int:
	var n := mini(sim.bcount[hid], 300)
	if n <= 0:
		return -1
	var k := _rand() % n
	var b := sim.bhead[hid]
	for i in k:
		b = sim.bnext[b]
	# step one tile inland when possible
	var row := b & -1024
	var x := b & 1023
	for c: int in [row | ((x + 1023) & 1023), row | ((x + 1) & 1023), b - Defs.W, b + Defs.W]:
		if c >= 0 and c < Defs.TILE_COUNT and sim.owner[c] == hid and sim.in_border[c] == 0:
			return c
	return b


func _policy() -> void:
	if sim.phase != Defs.PHASE_PLAYING or hid <= 0 or sim.o_alive[hid] == 0 or sim.o_spawned[hid] == 0:
		return
	if (sim.tick + 1) % 7 != 0:
		return
	var r := _rand() % 20
	var kinds := ["city", "port", "factory", "defense", "sam", "silo"]
	if r < 7:
		var cs := _contacts()
		if cs.size() > 0 and sim.o_troops[hid] >= 0.6 * sim.o_cap[hid]:
			var t := -1
			for c in cs:
				if sim.owner[c] == 0:
					t = c
					break
			if t < 0:
				var c2 := cs[_rand() % cs.size()]
				if sim.o_troops[sim.owner[c2]] < sim.o_troops[hid] * 0.8:
					t = c2
			if t >= 0:
				sim.submit(hid, {"type": "attack", "tile": t, "ratio": 0.2 + float(_rand() % 4) * 0.1})
	elif r < 11:
		var t2 := _own_tile()
		if t2 >= 0 and sim.o_gold[hid] >= 150000.0:
			sim.submit(hid, {"type": "build", "kind": kinds[_rand() % kinds.size()], "tile": t2})
	elif r == 11:
		var ct := sim.map.coast_tiles
		for i in 30:
			var c := ct[_rand() % ct.size()]
			if sim.owner[c] != hid and sim.land[c] == 1:
				sim.submit(hid, {"type": "boat", "tile": c, "ratio": 0.2})
				break
	elif r == 12 and sim.o_gold[hid] >= 1000000.0:
		var nk := ["atom", "hydrogen", "mirv"]
		var lt := sim.map.land_tiles
		for i in 30:
			var c2 := lt[_rand() % lt.size()]
			if sim.owner[c2] > 0 and sim.owner[c2] != hid and not sim.allied(hid, sim.owner[c2]):
				sim.submit(hid, {"type": "nuke", "kind": nk[_rand() % 3], "tile": c2})
				break
	elif r == 13:
		sim.submit(hid, {"type": "ally_request", "target": 1 + _rand() % sim.owner_total})
	elif r == 14:
		for id in range(1, sim.owner_total + 1):
			if sim.has_request(id, hid):
				sim.submit(hid, {"type": "ally_reply", "target": id, "accept": _rand() % 2 == 0})
	elif r == 15:
		for id in range(1, sim.owner_total + 1):
			if sim.allied(hid, id):
				if _rand() % 3 == 0:
					sim.submit(hid, {"type": "ally_break", "target": id})
				else:
					sim.submit(hid, {"type": "donate", "target": id, "troops": int(sim.o_troops[hid] * 0.05)})
				break
	elif r == 16:
		for a in sim.attacks:
			if not a.dead and a.attacker == hid:
				sim.submit(hid, {"type": "retreat", "attack_id": a.aid})
				break
	elif r == 17:
		for u in sim.unit_list:
			if not u.dead and u.owner == hid and u.kind == Defs.U_WARSHIP:
				var p := sim.unit_tile(u)
				var dst := ((p >> 10) + (_rand() % 21) - 10) * Defs.W + (((p & 1023) + (_rand() % 41) - 20) & 1023)
				sim.submit(hid, {"type": "move_warship", "uid": u.uid, "tile": clampi(dst, 0, Defs.TILE_COUNT - 1)})
				break
	else:
		var cs2 := _contacts()
		if cs2.size() > 0:
			sim.submit(hid, {"type": "attack", "tile": cs2[0], "ratio": 0.5})
