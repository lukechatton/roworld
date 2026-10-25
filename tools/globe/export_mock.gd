extends SceneTree
## Export tests/view_mock_world.gd's mock world (seed 1234) for the Roblox globe port harness.

func _init() -> void:
	var MockWorld = load("res://tests/view_mock_world.gd")
	var mock = MockWorld.new()
	var snap: Dictionary = mock.call("build", 1234)
	var st := GameState.new(WorldMap.shared())
	st.load_snapshot(snap)
	var out := {}
	out["local_id"] = int(mock.get("local_id"))
	var owners := []
	for o in st.owners.values():
		owners.append([o.id, o.name, o.color.to_html(false), o.kind, o.tiles, o.traitor_until])
	out["owners"] = owners
	var allies := []
	for k in st.alliances.keys():
		allies.append([int(k) / 1024, int(k) % 1024])
	out["allies"] = allies
	out["tick"] = st.tick
	var f := FileAccess.open("/private/tmp/claude-501/afexport/mock_meta.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	var g := FileAccess.open("/private/tmp/claude-501/afexport/mock_owner.bin", FileAccess.WRITE)
	g.store_buffer(st.owner.to_byte_array())
	g.close()
	var h := FileAccess.open("/private/tmp/claude-501/afexport/mock_flags.bin", FileAccess.WRITE)
	h.store_buffer(st.flags)
	h.close()
	print("EXPORT ok local=", out["local_id"], " owners=", owners.size())
	quit()
