-- zstd helper for tools/maps/import_maps.py (Python's standard library has no zstd).
-- Usage: lune run tools/maps/zstd.luau compress <in> <out> [level]
--        lune run tools/maps/zstd.luau decompress <in> <out>
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local mode, src, dst, level = process.args[1], process.args[2], process.args[3], process.args[4]
assert(src and dst, "usage: zstd.luau compress|decompress <in> <out> [level]")
local data = fs.readFile(src)
if mode == "compress" then
	fs.writeFile(dst, serde.compress("zstd", data, tonumber(level) or 19))
elseif mode == "decompress" then
	fs.writeFile(dst, serde.decompress("zstd", data))
else
	error("unknown mode " .. tostring(mode))
end
