-- sim-parity: Defs.godot_sort must order equal elements exactly like Godot's Array.sort_custom
-- (expected order tools/parity/sort_ref.txt from tools/parity/sort_ref.gd in the Airship Editor).
--   .bin/lune run tests/parity_sort.luau
local fs = require("@lune/fs")
local Defs = require("../src/shared/Core/Defs")

local failures, checks = 0, 0
for _, line in string.split(fs.readFile("tools/parity/sort_ref.txt"), "\n") do
	if line == "" then
		continue
	end
	local lhs, rhs = string.match(line, "^(.-) |(.*)$")
	local nums = string.split(lhs :: string, " ")
	local n = tonumber(nums[1]) :: number
	local arr = {}
	for i = 1, n do
		arr[i] = { tonumber(nums[i + 1]), i - 1 }
	end
	Defs.godot_sort(arr, function(a, b)
		return a[1] < b[1]
	end)
	local got = {}
	for i = 1, n do
		got[i] = tostring(arr[i][2])
	end
	checks += 1
	local want = string.gsub(rhs :: string, "^ ", "")
	if table.concat(got, " ") ~= want then
		failures += 1
		if failures <= 5 then
			print(string.format("FAIL n=%d\n  want %s\n  got  %s", n, want, table.concat(got, " ")))
		end
	end
end
print(string.format("parity_sort: %d arrays, %d failures", checks, failures))
if failures > 0 then
	error("parity_sort failed")
end
