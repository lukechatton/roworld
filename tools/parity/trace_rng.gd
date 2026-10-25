class_name TraceRng
extends RefCounted
## sim-parity (scratch copy only): RandomNumberGenerator wrapper that logs call sites.
static var log_from: int = -1
static var log_to: int = -1
static var cur_tick: int = 0
static var lines: PackedStringArray = PackedStringArray()
var r := RandomNumberGenerator.new()
var seed: int:
	set(v):
		r.seed = v
	get:
		return r.seed
var state: int:
	get:
		return r.state


func _site() -> String:
	var st := get_stack()
	if st.size() < 3:
		return "?"
	var s: Dictionary = st[2]
	var s2: Dictionary = st[3] if st.size() > 3 else {}
	return "%s:%d %s < %s:%d %s" % [String(s["source"]).get_file(), s["line"], s["function"],
		String(s2.get("source", "")).get_file(), s2.get("line", 0), s2.get("function", "")]


func _on() -> bool:
	return cur_tick >= log_from and cur_tick <= log_to


func randi() -> int:
	var v := r.randi()
	if _on():
		lines.append("%d randi %d @ %s" % [cur_tick, v, _site()])
	return v


func randf() -> float:
	var v := r.randf()
	if _on():
		lines.append("%d randf %.9f @ %s" % [cur_tick, v, _site()])
	return v


func randi_range(a: int, b: int) -> int:
	var v := r.randi_range(a, b)
	if _on() and a != b:
		lines.append("%d randi_range(%d,%d) %d @ %s" % [cur_tick, a, b, v, _site()])
	return v


func randf_range(a: float, b: float) -> float:
	var v := r.randf_range(a, b)
	if _on():
		lines.append("%d randf_range %.9f @ %s" % [cur_tick, v, _site()])
	return v
