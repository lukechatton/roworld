require("./prelude")
local process = require("@lune/process")
local fs = require("@lune/fs")
local Grids = require("../src/shared/Data/Grids")
local t0 = os.clock()
local terr = Grids.terrain()
local wb = Grids.water_body()
print(("decode %.1f ms"):format((os.clock() - t0) * 1000))
-- compare against raw bytes dumped by Python
local res = process.exec(
	".venv/bin/python",
	{
		"-c",
		[[
from PIL import Image; import os, sys
for n in ("terrain", "water_body"):
    sys.stdout.buffer.write(Image.open(os.path.expanduser("~/games/airfront/assets/world/%s.png" % n)).convert("L").tobytes())
]],
	}
)
assert(res.ok, res.stderr)
local raw = res.stdout
assert(#raw == 2 * 524288, "raw len " .. #raw)
assert(buffer.tostring(terr) == string.sub(raw, 1, 524288), "terrain mismatch")
assert(buffer.tostring(wb) == string.sub(raw, 524289), "water_body mismatch")
print("grids_test ok")
