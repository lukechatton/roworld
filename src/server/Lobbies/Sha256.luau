--!strict
--!native
-- SHA-256 and HMAC-SHA256 in pure Luau (buffer + bit32), for signing lobby-service requests
-- (docs/lobby-service.md "Auth"; from the Tribes matchmaker). Luau/Roblox has no built-in hash. Server-only.
--
--   Sha256.Digest(msg: string) -> string        32 raw bytes
--   Sha256.Hex(msg: string) -> string           64 lowercase hex chars
--   Sha256.Hmac(key: string, msg: string) -> string   32 raw bytes (RFC 2104)
--   Sha256.HmacHex(key: string, msg: string) -> string
--   Sha256.ToHex(raw: string) -> string
--   Sha256.Equal(a: string, b: string) -> boolean     constant-time compare (equal lengths)
--   Sha256.SelfTest() -> (ok: boolean, failures: {string})   NIST + RFC 4231 vectors
--
-- Tested by tools/mm/test_sha256.luau (standalone .bin/luau) and cross-checked against Node's crypto in
-- services/matchmaker (npm test: random messages hashed on both sides).

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local rrotate, rshift, byteswap = bit32.rrotate, bit32.rshift, bit32.byteswap
local readu32, writeu32 = buffer.readu32, buffer.writeu32

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local w = table.create(64, 0) :: { number } -- message schedule (reused; Digest never yields)

local function digest(msg: string): string
	local len = #msg
	local total = ((len + 8) // 64 + 1) * 64 -- message + 0x80 + zero pad + 64-bit length
	local buf = buffer.create(total)
	buffer.writestring(buf, 0, msg)
	buffer.writeu8(buf, len, 0x80)
	local bits = len * 8
	writeu32(buf, total - 8, byteswap(bits // 4294967296))
	writeu32(buf, total - 4, byteswap(bits % 4294967296))

	local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

	for off = 0, total - 1, 64 do
		for i = 1, 16 do
			w[i] = byteswap(readu32(buf, off + (i - 1) * 4))
		end
		for i = 17, 64 do
			local w15, w2 = w[i - 15], w[i - 2]
			local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
			local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
			w[i] = bor(w[i - 16] + s0 + w[i - 7] + s1, 0)
		end
		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = h + S1 + ch + K[i] + w[i]
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			h = g
			g = f
			f = e
			e = bor(d + t1, 0)
			d = c
			c = b
			b = a
			a = bor(t1 + S0 + maj, 0)
		end
		h0 = bor(h0 + a, 0)
		h1 = bor(h1 + b, 0)
		h2 = bor(h2 + c, 0)
		h3 = bor(h3 + d, 0)
		h4 = bor(h4 + e, 0)
		h5 = bor(h5 + f, 0)
		h6 = bor(h6 + g, 0)
		h7 = bor(h7 + h, 0)
	end

	local out = buffer.create(32)
	writeu32(out, 0, byteswap(h0))
	writeu32(out, 4, byteswap(h1))
	writeu32(out, 8, byteswap(h2))
	writeu32(out, 12, byteswap(h3))
	writeu32(out, 16, byteswap(h4))
	writeu32(out, 20, byteswap(h5))
	writeu32(out, 24, byteswap(h6))
	writeu32(out, 28, byteswap(h7))
	return buffer.tostring(out)
end

local function toHex(raw: string): string
	return (string.gsub(raw, ".", function(ch)
		return string.format("%02x", string.byte(ch))
	end))
end

local function xorPad(key: string, byte: number): string
	local b = buffer.create(64)
	for i = 0, 63 do
		local k = if i < #key then string.byte(key, i + 1) else 0
		buffer.writeu8(b, i, bxor(k, byte))
	end
	return buffer.tostring(b)
end

local function hmac(key: string, msg: string): string
	if #key > 64 then
		key = digest(key)
	end
	local inner = digest(xorPad(key, 0x36) .. msg)
	return digest(xorPad(key, 0x5c) .. inner)
end

local Sha256 = {}

Sha256.Digest = digest
Sha256.ToHex = toHex
Sha256.Hmac = hmac

function Sha256.Hex(msg: string): string
	return toHex(digest(msg))
end

function Sha256.HmacHex(key: string, msg: string): string
	return toHex(hmac(key, msg))
end

-- Constant-time for equal lengths (signatures are fixed-length hex).
function Sha256.Equal(a: string, b: string): boolean
	if #a ~= #b then
		return false
	end
	local diff = 0
	for i = 1, #a do
		diff = bor(diff, bxor(string.byte(a, i), string.byte(b, i)))
	end
	return diff == 0
end

-- NIST FIPS 180-2 examples + RFC 4231 HMAC-SHA256 test cases 1, 2, 3, 4, 6, 7.
function Sha256.SelfTest(): (boolean, { string })
	local failures = {}
	local function check(name: string, got: string, want: string)
		if got ~= want then
			table.insert(failures, `{name}: got {got}, want {want}`)
		end
	end
	check("sha256('')", Sha256.Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	check("sha256('abc')", Sha256.Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	check(
		"sha256(448 bits)",
		Sha256.Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
		"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
	)
	check(
		"sha256(896 bits)",
		Sha256.Hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
		"cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
	)
	-- boundary lengths around the 55/56/64-byte padding edges
	check("sha256(55 x 'a')", Sha256.Hex(string.rep("a", 55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
	check("sha256(56 x 'a')", Sha256.Hex(string.rep("a", 56)), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
	check("sha256(64 x 'a')", Sha256.Hex(string.rep("a", 64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
	check("hmac rfc4231 #1", Sha256.HmacHex(string.rep("\x0b", 20), "Hi There"), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
	check("hmac rfc4231 #2", Sha256.HmacHex("Jefe", "what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
	check("hmac rfc4231 #3", Sha256.HmacHex(string.rep("\xaa", 20), string.rep("\xdd", 50)), "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
	local key4 = ""
	for i = 1, 25 do
		key4 ..= string.char(i)
	end
	check("hmac rfc4231 #4", Sha256.HmacHex(key4, string.rep("\xcd", 50)), "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
	check(
		"hmac rfc4231 #6",
		Sha256.HmacHex(string.rep("\xaa", 131), "Test Using Larger Than Block-Size Key - Hash Key First"),
		"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
	)
	check(
		"hmac rfc4231 #7",
		Sha256.HmacHex(
			string.rep("\xaa", 131),
			"This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
		),
		"9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"
	)
	check("equal", tostring(Sha256.Equal("abc", "abc") and not Sha256.Equal("abc", "abd") and not Sha256.Equal("ab", "abc")), "true")
	return #failures == 0, failures
end

return Sha256
