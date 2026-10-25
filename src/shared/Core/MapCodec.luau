--!native
-- Decoding of map terrain blobs (tools/maps/import_maps.py writes base64(zstd(tile bytes))).
-- zstd comes from EncodingService in Roblox and from @lune/serde under Lune (tests, tools); other
-- hosts can plug a decompressor with MapCodec.set_zstd. Base64 is portable Luau (EncodingService's
-- Base64Decode is used when the engine has it).
local MapCodec = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = buffer.create(256)
for i = 1, 64 do
	buffer.writeu8(DEC, string.byte(B64, i), i - 1)
end

--- Portable base64 → buffer.
function MapCodec.b64decode_luau(s: string): buffer
	local n = #s
	local pad = 0
	if n > 0 and string.byte(s, n) == 61 then
		pad += 1
	end
	if n > 1 and string.byte(s, n - 1) == 61 then
		pad += 1
	end
	local len = n // 4 * 3 - pad
	local out = buffer.create(len)
	local src = buffer.fromstring(s)
	local readu8 = buffer.readu8
	local o = 0
	local full = (n // 4) - (if pad > 0 then 1 else 0)
	for q = 0, full - 1 do
		local i = q * 4
		local v = readu8(DEC, readu8(src, i)) * 262144
			+ readu8(DEC, readu8(src, i + 1)) * 4096
			+ readu8(DEC, readu8(src, i + 2)) * 64
			+ readu8(DEC, readu8(src, i + 3))
		buffer.writeu8(out, o, v // 65536)
		buffer.writeu8(out, o + 1, (v // 256) % 256)
		buffer.writeu8(out, o + 2, v % 256)
		o += 3
	end
	if pad > 0 then
		local i = full * 4
		local a = readu8(DEC, readu8(src, i))
		local b = readu8(DEC, readu8(src, i + 1))
		local c = if pad == 1 then readu8(DEC, readu8(src, i + 2)) else 0
		local v = a * 262144 + b * 4096 + c * 64
		buffer.writeu8(out, o, v // 65536)
		if pad == 1 then
			buffer.writeu8(out, o + 1, (v // 256) % 256)
		end
	end
	return out
end

type Zstd = (buffer) -> buffer
local zstd: Zstd? = nil
local b64: ((string) -> buffer)? = nil

do
	local ok, es = pcall(function()
		return (game :: any):GetService("EncodingService")
	end)
	if ok and es ~= nil then
		local algo = (Enum :: any).CompressionAlgorithm.Zstd
		local ok_z = pcall(function()
			local z = es:CompressBuffer(buffer.fromstring("rofront"), algo, 3)
			assert(buffer.tostring(es:DecompressBuffer(z, algo)) == "rofront", "zstd round trip")
		end)
		if ok_z then
			zstd = function(b: buffer): buffer
				return es:DecompressBuffer(b, algo)
			end
		end
		local ok_b = pcall(function()
			assert(buffer.tostring(es:Base64Decode(buffer.fromstring("cm9mcm9udA=="))) == "rofront", "base64")
		end)
		if ok_b then
			b64 = function(s: string): buffer
				return es:Base64Decode(buffer.fromstring(s))
			end
		end
	elseif (script :: any) == nil then
		-- Lune (tests / tools)
		local ok_s, serde = pcall(require, "@lune/serde")
		if ok_s and serde ~= nil then
			zstd = function(b: buffer): buffer
				return buffer.fromstring((serde :: any).decompress("zstd", buffer.tostring(b)))
			end
		end
	end
end

--- Plug a zstd decompressor (buffer → buffer); nil disables.
function MapCodec.set_zstd(fn: Zstd?)
	zstd = fn
end

function MapCodec.has_zstd(): boolean
	return zstd ~= nil
end

function MapCodec.b64decode(s: string): buffer
	if b64 ~= nil then
		return (b64 :: any)(s)
	end
	return MapCodec.b64decode_luau(s)
end

function MapCodec.zstd_decompress(b: buffer): buffer
	local z = zstd
	if z == nil then
		error("MapCodec: no zstd decompressor available (EncodingService / @lune/serde)")
	end
	return z(b)
end

--- Tile bytes of a map data table: `terrain` is either a buffer (raw bytes, or zstd bytes when
--- `codec` is "zstd" — what MapFetch downloads) or a string in `codec` ("zstd+base64", default).
--- Checks the size.
function MapCodec.terrain_bytes(data: { [string]: any }): buffer
	local t = data.terrain
	local size = data.size or (data.width * data.height)
	local out: buffer
	if typeof(t) == "buffer" then
		out = if data.codec == "zstd" then MapCodec.zstd_decompress(t) else t
	elseif type(t) == "string" then
		local codec = data.codec or "zstd+base64"
		if codec == "zstd+base64" then
			out = MapCodec.zstd_decompress(MapCodec.b64decode(t))
		elseif codec == "zstd" then
			out = MapCodec.zstd_decompress(buffer.fromstring(t))
		elseif codec == "raw" then
			out = buffer.fromstring(t)
		else
			error("MapCodec: unknown codec " .. tostring(codec))
		end
	else
		error("MapCodec: map data has no terrain")
	end
	if buffer.len(out) ~= size then
		error(string.format("MapCodec: terrain is %d bytes, expected %d", buffer.len(out), size))
	end
	return out
end

return MapCodec
