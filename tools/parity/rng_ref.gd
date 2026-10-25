extends Node

func _h(x: float) -> String:
	return PackedFloat64Array([x]).to_byte_array().hex_encode()

## sim-parity: prints Godot RandomNumberGenerator reference values (compared by tests/parity_rng.luau).
func _ready() -> void:
	var out := []
	for s in [1, 2, 3, 12345, 0, -7]:
		out.append("hash %d %d" % [s, hash(s)])
	for s in [1, 2, 3, 12345]:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(s)
		out.append("seed %d state %d" % [s, rng.state])
		var line := "randi"
		for i in 8:
			line += " %d" % rng.randi()
		out.append(line)
		line = "randf"
		for i in 8:
			line += " " + _h(rng.randf())
		out.append(line)
		line = "randi_range"
		for i in 8:
			line += " %d" % rng.randi_range(-3, 3)
		for i in 8:
			line += " %d" % rng.randi_range(0, 600)
		for i in 4:
			line += " %d" % rng.randi_range(5, 5)
		for i in 4:
			line += " %d" % rng.randi_range(0, 2147483646)
		out.append(line)
		line = "randf_range"
		for i in 8:
			line += " " + _h(rng.randf_range(0.8, 1.25))
		for i in 8:
			line += " " + _h(rng.randf_range(0.35, 0.65))
		out.append(line)
		out.append("state_after %d" % rng.state)
	# many randf to catch rounding cases
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = hash(99)
	var acc := ""
	for i in 2000:
		acc += _h(rng2.randf()) + "\n"
	var f := FileAccess.open(OS.get_environment("RNG_OUT"), FileAccess.WRITE)
	for l in out:
		f.store_line(l)
	f.store_string(acc)
	var acc2 := ""
	for i in 2000:
		acc2 += _h(rng2.randf_range(0.5, 1.5)) + "\n"
	f.store_string(acc2)
	f.close()
	get_tree().quit(0)
