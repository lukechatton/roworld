-- sim-parity: the port must reproduce the ORIGINAL simulation exactly when both draw from the same
-- random numbers. Runs tools/parity/lockstep.luau (port + Godot-exact RNG) for four configs and
-- compares every 10th tick (RNG state, claimed land, attacks, tile checksum, troops, nukes,
-- structures, roads, units and a hash of the whole delta: events, messages, tiles, flags, stats)
-- with traces recorded from the original in the Airship Editor (tools/parity/ref/, regenerate with
-- tools/parity/make_ref.sh). On a mismatch, locate it with tools/parity/run_pair.sh (see
-- build/notes/sim-parity.md).
--   .bin/lune run tests/parity_lockstep.luau
local fs = require("@lune/fs")
local process = require("@lune/process")
local task = require("@lune/task")

-- name, seed, ticks, tribes, human (0 none, 2 scripted, 3 multiplayer script), difficulty
local CONFIGS = {
	{ "ai_s1", 1, 3600, 80, 0, 1 },
	{ "human_s7", 7, 3000, 80, 2, 1 },
	{ "mp_s3", 3, 4000, 150, 3, 2 },
	{ "ai_s5", 5, 6000, 80, 0, 1 },
}
local FIELDS =
	{ "tick", "rng", "claimed", "attacks", "tile_ck", "troops", "nukes", "structs", "roads", "units", "delta" }

local results = {}
local pending = #CONFIGS
for i, c in CONFIGS do
	task.spawn(function()
		local r = process.exec(".bin/lune", {
			"run",
			"tools/parity/lockstep.luau",
			"--",
			"--seed=" .. c[2],
			"--ticks=" .. c[3],
			"--tribes=" .. c[4],
			"--human=" .. c[5],
			"--diff=" .. c[6],
			"--out=/dev/stdout",
		})
		results[i] = r
		pending -= 1
	end)
end
while pending > 0 do
	task.wait(0.05)
end

local failures = 0
for i, c in CONFIGS do
	local name = c[1]
	local r = results[i]
	if not r.ok then
		failures += 1
		print(string.format("FAIL %s: port probe crashed\n%s", name, r.stderr))
		continue
	end
	local port_lines = string.split(r.stdout, "\n")
	local by_tick: { [string]: string } = {}
	local headers = {}
	for _, l in port_lines do
		local t = string.match(l, "^(%d+) ")
		if t then
			by_tick[t] = l
		elseif l ~= "" then
			table.insert(headers, l)
		end
	end
	local ref = string.split(fs.readFile("tools/parity/ref/" .. name .. ".txt"), "\n")
	local hi, compared, bad = 0, 0, nil
	for _, l in ref do
		if l == "" then
			continue
		end
		local t = string.match(l, "^(%d+) ")
		local got
		if t then
			got = by_tick[t]
		else
			hi += 1
			got = headers[hi]
		end
		compared += 1
		if got ~= l then
			bad = { l, got or "(missing)" }
			break
		end
	end
	if bad then
		failures += 1
		local a, b = string.split(bad[1], " "), string.split(bad[2], " ")
		local diffs = {}
		for k = 1, math.max(#a, #b) do
			if a[k] ~= b[k] then
				table.insert(diffs, FIELDS[k] or tostring(k))
			end
		end
		print(
			string.format(
				"FAIL %s: first mismatch (%s)\n  orig: %s\n  port: %s",
				name,
				table.concat(diffs, ", "),
				bad[1],
				bad[2]
			)
		)
	else
		print(string.format("  ok   %s: %d reference lines identical (%d ticks)", name, compared, c[3]))
	end
end
print(string.format("parity_lockstep: %d configs, %d failures", #CONFIGS, failures))
if failures > 0 then
	error("parity_lockstep failed")
end
