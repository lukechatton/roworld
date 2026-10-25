extends Node
## sim-parity: Godot sort_custom reference (ties!) for tests/parity_sort.luau.
## Arrays of [key, id] with keys from a small range (many ties), sorted by key only; prints ids.
func _ready() -> void:
	var f := FileAccess.open(OS.get_environment("SORT_OUT"), FileAccess.WRITE)
	var x := 7
	for n: int in [1, 2, 3, 5, 8, 15, 16, 17, 18, 31, 33, 50, 64, 100, 170, 257, 600, 1500]:
		for rep in 3:
			var arr: Array = []
			var keys := PackedInt32Array()
			for i in n:
				x = (x * 16807) % 2147483647
				var k := x % (3 + rep * n / 4 + 1)
				keys.append(k)
				arr.append([k, i])
			arr.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
			var line := "%d" % n
			for k2 in keys:
				line += " %d" % k2
			line += " |"
			for e: Array in arr:
				line += " %d" % int(e[1])
			f.store_line(line)
	f.close()
	get_tree().quit(0)
