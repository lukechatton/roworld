-- Shared helpers for tests/net_*.luau: deep equality, zstd codec for Protocol, fake data.
local serde = require("@lune/serde")

local U = {}

--- Plug Lune's zstd into Protocol so size measurements match EncodingService's zstd.
function U.use_zstd(Protocol)
	Protocol.set_codec({
		compress = function(b: buffer): buffer
			return buffer.fromstring(serde.compress("zstd", buffer.tostring(b)))
		end,
		decompress = function(b: buffer, _n: number): buffer
			return buffer.fromstring(serde.decompress("zstd", buffer.tostring(b)))
		end,
	})
end

local function describe(v)
	if type(v) == "buffer" then
		return "buffer(" .. buffer.len(v) .. ")"
	end
	return tostring(v)
end

--- Deep equality (buffers by content, NaN == NaN). Returns ok, path-of-first-difference.
function U.deep_eq(a, b, path)
	path = path or "$"
	if type(a) ~= type(b) then
		return false, path .. ": type " .. type(a) .. " vs " .. type(b)
	end
	if type(a) == "number" then
		if a ~= a and b ~= b then
			return true
		end
		return a == b, path .. ": " .. describe(a) .. " vs " .. describe(b)
	end
	if type(a) == "buffer" then
		if buffer.len(a) ~= buffer.len(b) then
			return false, path .. ": " .. describe(a) .. " vs " .. describe(b)
		end
		if buffer.tostring(a) ~= buffer.tostring(b) then
			return false, path .. ": buffer content differs"
		end
		return true
	end
	if type(a) ~= "table" then
		return a == b, path .. ": " .. describe(a) .. " vs " .. describe(b)
	end
	for k, v in a do
		local ok, why = U.deep_eq(v, b[k], path .. "." .. tostring(k))
		if not ok then
			return false, why
		end
	end
	for k in b do
		if a[k] == nil then
			return false, path .. "." .. tostring(k) .. ": missing on the left"
		end
	end
	return true
end

function U.assert_eq(a, b, what)
	local ok, why = U.deep_eq(a, b)
	if not ok then
		error((what or "values differ") .. " — " .. tostring(why), 2)
	end
end

local fails = 0
function U.check(cond, what)
	if cond then
		print("  ok - " .. what)
	else
		fails += 1
		print("  FAIL - " .. what)
	end
end
function U.failures()
	return fails
end

return U
