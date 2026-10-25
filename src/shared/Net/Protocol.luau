--!native
--!strict
-- Wire protocol for the multiplayer match: compact `buffer` encodings of Sim deltas, snapshots and
-- intents. Replaces session.gd's `var_to_bytes()` + zstd transport (DESIGN.md §9, PORT.md §9).
--
-- Every encoded message starts with an envelope byte:
--   0  raw        → body follows
--   1  zstd       → varuint raw_size, then EncodingService zstd frame of the body
-- `Protocol.compress(msg)` turns a raw message into a zstd one when that is worth it (> 1200 bytes, as
-- session.gd's COMPRESS_OVER_BYTES); `Protocol.open(msg)` undoes it. Without EncodingService (Lune, or
-- an engine without it) messages stay raw — every decoder handles both.
--
-- Primitive encodings: varuint = LEB128 (7 bits per byte, < 2^53); zz = zigzag varint for signed ints.
--
-- Generic values (events, snapshot rows, extra fields) are tagged:
--   0 nil  1 false  2 true  3 uint(varuint)  4 negint(varuint -v-1)  5 f64  6 string(varuint len+bytes)
--   7 array(varuint n, n values)  8 int array(varuint n, zz deltas from the previous element)
--   9 dense tile path(varuint n, varuint grid width, varuint first, (n-1) 4-bit step codes, then zz
--     deltas for escapes)
--   10 map(varuint n, n×(string key, value))  11 buffer(varuint len, bytes)  12 empty table
--   13 grid buffer RLE(u8 width 1|2|4, varuint cells, runs of (varuint value, varuint len))
--   14 int array RLE(varuint n, runs of (zz value, varuint len))
--   16..255 small uint 0..239 in the tag itself
-- Tile paths (units' water/road paths) are dense: each step moves to one of the 8 neighbours, so a
-- 4-bit code per step ((dy+1)*3 + dx+1, 15 = escape) makes them ~0.5 byte per tile. The map is a flat
-- grid of any size: the encoder needs its width (encode_delta's `grid_w`, the snapshot's map_w) and
-- writes it into each path; without it paths travel as plain int arrays (tag 8). Owner / flag grids
-- are recognised by the snapshot's map_w x map_h cell count (tag 13).
--
-- Delta body: u8 KIND_DELTA, u8 mask (1 tiles, 2 flags, 4 stats, 8 ev, 16 extra, 32 t), [varuint t],
--   tiles: u8 repr (0 table, 1 buffer of i32), varuint n, runs (varuint owner, varuint len, len × zz Δtile)
--   flags: same layout with (tile << 8 | flags) entries
--   stats: u8 repr, varuint n, n × zz
--   ev:    varuint n, n values (each event is an array value)
--   extra: map value with any other keys (future fields survive the trip)
-- Private events (MSG to one owner) travel in a per-recipient tail message so the shared delta is
-- encoded and compressed once per tick (session.gd re-encoded the whole delta per participant):
--   tail body: u8 KIND_TAIL, varuint n, n × (varuint position in the recipient's event list, value)
-- Snapshot body: u8 KIND_SNAPSHOT, then one map value (grids become tag 13/14 RLE automatically).
-- Intent body: u8 KIND_INTENT, u8 type index (INTENT_TYPES), u8 field mask, fields in mask order.

local Coop = require("./Coop")

local Protocol = {}

--- Owner ids are packed as tile * MAX_OWNERS + owner in tile lists.
local MAX_OWNERS = 1024
--- Upper bound for decoded grids / lists / tile indices (untrusted input guard): 16.7M cells.
local MAX_CELLS = 16777216
Protocol.MAX_CELLS = MAX_CELLS

Protocol.VERSION = 2
Protocol.COMPRESS_OVER_BYTES = 1200
Protocol.MAX_INTENT_BYTES = 128

Protocol.KIND_DELTA = 1
Protocol.KIND_SNAPSHOT = 2
Protocol.KIND_TAIL = 3
Protocol.KIND_INTENT = 4

--- RemoteEvent op codes (first argument of every ToServer / ToClient event).
Protocol.OP = {
	-- client → server
	HELLO = 1, -- client scripts are listening; start sending lobby info
	JOIN = 2, -- (display_name: string) queue for / join the match
	LEAVE = 3,
	INTENT = 4, -- (intent: buffer)
	SETTING = 5, -- (section: string, values: table) persist a per-player settings section (Net/Settings)
	RESYNC = 6, -- the client's mirror failed to decode / apply a delta: send me a fresh snapshot
	ACTIVE = 7, -- the player is at the controls (throttled; keeps watchers from being idle-dropped)
	JOIN_LOBBY = 8, -- (lobby_id: string) hub: teleport me to that public lobby's match server
	SPECTATE_LOBBY = 9, -- (lobby_id: string) hub: teleport me to that running match to watch it
	VOTE_START = 10, -- toggle my vote to start the waiting public match early
	ANALYTICS = 11, -- (kind: string, a, b, c) a milestone for the Creator Dashboard (server/Analytics)
	OPEN_CRATE = 13, -- open one bought crate (reply CRATE_RESULT; server/Purchases.open_crate)
	EQUIP = 14, -- (slot: "skin" | "flag", item_id: string | false) wear an owned cosmetic (or none)
	USE_CREDIT = 12, -- (kind: string, target: number?) spend one bought credit (Data/Products; reply
	-- CREDIT_RESULT); a public match's server takes over `target` for the player itself
	BUY_UNLOCK = 15, -- (key: string) unlock an Arsenal item with Stars (Data/Arsenal; reply UNLOCK_RESULT)
	SOLO_RESULT = 16, -- (report: table) a solo match's result, for its Stars (server/Rewards; reply STARS)
	SOLO_HOP = 17, -- (difficulty: number, map_id: string?) hub: I am starting a solo match and this server
	-- is outdated: teleport me to a fresh one to play it there (server/FreshServers; reply HOP_RESULT)
	NEW_PLAYER = 18, -- Rofront Staging / Studio only: make me a new player again (matches counted,
	-- the tutorial's Stars, the first crate's price); the settings and the inventory follow
	PARTY = 19, -- (action: "invite" | "accept" | "decline" | "leave" | "kick", user_id: number?) hub, team
	-- games on (ServerMain.team_games): server/Party (reply PARTY_STATE)
	-- server → client
	LOBBY = 20, -- (info: table)
	SNAPSHOT = 21, -- (owner_id: number, snapshot: buffer)
	DELTA = 22, -- (delta: buffer, tail: buffer?)
	NOTICE = 23, -- (text: string, severity: number)
	MATCH_CLOSED = 24, -- (reason: string)
	SETTINGS = 25, -- (settings: table) the player's saved settings
	LOBBIES = 26, -- (list: { {id, map, map_name, max, players, starts_in, joinable, live, elapsed, watchable} },
	-- kinds: { "ffa" | "team" | "world" }?) kinds: the public matches Quick Play offers here (JOIN_PUBLIC)
	JOIN_RESULT = 27, -- (ok: boolean, reason: string?) hub: a JOIN_LOBBY that did not teleport
	ADMIN_BOTS = 28, -- (bot_owner_ids: { number }) game admins only: which "players" are bot players
	CREDITS = 29, -- (credits: { [kind]: number }) the player's bought, unspent credits (server/Purchases)
	CREDIT_RESULT = 30, -- (kind: string, ok: boolean, reason: string?) a USE_CREDIT's answer
	OWNER_CHANGED = 31, -- (owner_id: number) public match: you now command this nation (a takeover)
	INVENTORY = 32, -- ({ owned = { id }, equipped = { skin?, flag? }, crates_bought, crates_allowed, stars,
	-- unlocks = { key }, starter = false | { state = "ready" } | { state = "active", left = s } })
	CRATE_RESULT = 33, -- (ok: boolean, item_id_or_reason: string) an OPEN_CRATE's answer
	COSMETICS = 34, -- ({ [owner_id] = { skin?, flag?, face? } }) the match's equipped cosmetics, whole map
	STARS = 35, -- ({ lines = { {key, amount} }, total, balance, double }) Stars paid for a match
	UNLOCK_RESULT = 36, -- (key: string, ok: boolean, reason: string?) a BUY_UNLOCK's answer
	HOP_RESULT = 37, -- (going: boolean) a SOLO_HOP's answer: true = the teleport is on its way, false =
	-- play here (no fresh server with room, or the teleport failed)
	PARTY_STATE = 38, -- ({ members = { {uid, name, leader} }, leader: boolean, invites = { {uid, name} },
	-- max }) the player's party (server/Party.state)
	-- Quick Play (2026-10-11; docs/lobby-service.md "Quick Play")
	JOIN_PUBLIC = 39, -- client → hub: (mode: "ffa" | "team" | "world" | false) a seat in the soonest public match of
	-- that kind (a party leader: for the party), or false to leave the line
	PUBLIC_STATE = 40, -- hub → client: (state: "joining" | "line" | "going" | "idle", mode: string?,
	-- info: { map, map_name }?) asking / waiting in line for a free seat / seated, on the way / neither
	STARTER_SEEN = 41, -- client → server: the starter pack's offer is on my screen: start its clock (once;
	-- server/Purchases.starter_seen; the INVENTORY that follows carries `starter`)
}

Protocol.INTENT_TYPES = {
	"spawn",
	"attack",
	"boat",
	"build",
	"nuke",
	"retreat",
	"move_warship",
	"ally_request",
	"ally_reply",
	"ally_break",
	"donate",
	"ally_extend", -- {target}: ask to renew the alliance with `target` (last 30 s before it expires)
	"reinforce", -- {}: the Arsenal's Reinforcements (gold for troops; Sim.reinforce)
}
local INTENT_INDEX: { [string]: number } = {}
for i, name in Protocol.INTENT_TYPES do
	INTENT_INDEX[name] = i
end
-- Integer intent fields in wire order (mask bits 1, 2, 4, 8, 16), then ratio (32), kind (64), accept (128).
-- An optional trailing byte is `amount` (build / nuke several at once: bulk upgrades and
-- stacked atom bombs, 1..MAX_INTENT_AMOUNT).
local INTENT_INT_FIELDS = { "tile", "target", "attack_id", "troops", "uid" }
--- The most levels (or bombs) one intent may ask for.
Protocol.MAX_INTENT_AMOUNT = 50

-- =============================================================================================
-- Compression (EncodingService zstd when available)
-- =============================================================================================

type Codec = { compress: (buffer) -> buffer, decompress: (buffer, number) -> buffer }
local codec: Codec? = nil

do
	local ok, es = pcall(function()
		return (game :: any):GetService("EncodingService")
	end)
	if ok and es ~= nil then
		local algo = (Enum :: any).CompressionAlgorithm.Zstd
		local probe_ok = pcall(function()
			local z = es:CompressBuffer(buffer.fromstring("airfront"), algo, 3)
			assert(buffer.tostring(es:DecompressBuffer(z, algo)) == "airfront", "zstd round trip")
		end)
		if probe_ok then
			codec = {
				compress = function(b: buffer): buffer
					return es:CompressBuffer(b, algo, 3)
				end,
				decompress = function(b: buffer, _raw_size: number): buffer
					return es:DecompressBuffer(b, algo)
				end,
			}
		end
	end
end

--- Plug a compressor (Lune tests use @lune/serde zstd). Pass nil to disable compression.
function Protocol.set_codec(c: Codec?)
	codec = c
end

function Protocol.has_codec(): boolean
	return codec ~= nil
end

-- =============================================================================================
-- Writer / reader
-- =============================================================================================

--- gw: grid width for tile paths (0 = unknown: paths go as int arrays); cells: grid cell count
--- for owner / flag grid detection (0 = none).
export type Writer = { b: buffer, n: number, gw: number, cells: number }
export type Reader = { b: buffer, n: number, len: number }

local function w_new(cap: number): Writer
	return { b = buffer.create(cap), n = 0, gw = 0, cells = 0 }
end

local function w_ensure(w: Writer, extra: number)
	local need = w.n + extra
	local cap = buffer.len(w.b)
	if need > cap then
		local nc = cap * 2
		while nc < need do
			nc *= 2
		end
		local nb = buffer.create(nc)
		buffer.copy(nb, 0, w.b, 0, w.n)
		w.b = nb
	end
end

local function w_u8(w: Writer, v: number)
	w_ensure(w, 1)
	buffer.writeu8(w.b, w.n, v)
	w.n += 1
end

local function w_var(w: Writer, v: number)
	w_ensure(w, 8)
	local b, n = w.b, w.n
	while v >= 128 do
		buffer.writeu8(b, n, v % 128 + 128)
		n += 1
		v = v // 128
	end
	buffer.writeu8(b, n, v)
	w.n = n + 1
end

local function w_zz(w: Writer, v: number)
	if v >= 0 then
		w_var(w, v * 2)
	else
		w_var(w, -v * 2 - 1)
	end
end

local function w_f64(w: Writer, v: number)
	w_ensure(w, 8)
	buffer.writef64(w.b, w.n, v)
	w.n += 8
end

local function w_str(w: Writer, s: string)
	local len = #s
	w_var(w, len)
	w_ensure(w, len)
	buffer.writestring(w.b, w.n, s)
	w.n += len
end

local function w_bytes(w: Writer, src: buffer, offset: number, len: number)
	w_ensure(w, len)
	buffer.copy(w.b, w.n, src, offset, len)
	w.n += len
end

local function w_finish(w: Writer): buffer
	local out = buffer.create(w.n)
	buffer.copy(out, 0, w.b, 0, w.n)
	return out
end

local function r_new(b: buffer, offset: number): Reader
	return { b = b, n = offset, len = buffer.len(b) }
end

local function r_u8(r: Reader): number
	local v = buffer.readu8(r.b, r.n)
	r.n += 1
	return v
end

local function r_var(r: Reader): number
	local b, n = r.b, r.n
	local v, mul = 0, 1
	while true do
		local byte = buffer.readu8(b, n)
		n += 1
		if byte < 128 then
			v += byte * mul
			break
		end
		v += (byte - 128) * mul
		mul *= 128
		if mul > 2 ^ 56 then
			error("Protocol: varint too long")
		end
	end
	r.n = n
	return v
end

local function r_zz(r: Reader): number
	local u = r_var(r)
	if u % 2 == 0 then
		return u // 2
	end
	return -(u + 1) // 2
end

local function r_f64(r: Reader): number
	local v = buffer.readf64(r.b, r.n)
	r.n += 8
	return v
end

local function r_str(r: Reader): string
	local len = r_var(r)
	if r.n + len > r.len then
		error("Protocol: string past end")
	end
	local s = buffer.readstring(r.b, r.n, len)
	r.n += len
	return s
end

-- =============================================================================================
-- Generic values
-- =============================================================================================

local TWO53 = 2 ^ 53
local TWO52 = 2 ^ 52
local floor = math.floor

local function step_code(W: number, prev: number, cur: number): number
	local dx = cur % W - prev % W
	local dy = cur // W - prev // W
	if dx >= -1 and dx <= 1 and dy >= -1 and dy <= 1 then
		return (dy + 1) * 3 + dx + 1
	end
	return 15
end

-- Is this all-integer array a dense tile path worth the path encoding?
local function path_escapes(W: number, v: { number }, n: number): number
	local esc = 0
	local prev = v[1]
	if prev < 0 or prev >= MAX_CELLS then
		return n
	end
	for i = 2, n do
		local cur = v[i]
		if cur < 0 or cur >= MAX_CELLS then
			return n
		end
		if step_code(W, prev, cur) == 15 then
			esc += 1
		end
		prev = cur
	end
	return esc
end

local function write_path(w: Writer, v: { number }, n: number)
	local W = w.gw
	w_u8(w, 9)
	w_var(w, n)
	w_var(w, W)
	w_var(w, v[1])
	local steps = n - 1
	local nbytes = (steps + 1) // 2
	w_ensure(w, nbytes)
	local b, base = w.b, w.n
	local escapes: { number }? = nil
	local prev = v[1]
	local byte = 0
	for i = 1, steps do
		local cur = v[i + 1]
		local code = step_code(W, prev, cur)
		if code == 15 then
			if escapes == nil then
				escapes = {}
			end
			table.insert(escapes :: { number }, cur - prev)
		end
		if i % 2 == 1 then
			byte = code
		else
			buffer.writeu8(b, base + (i // 2) - 1, byte + code * 16)
		end
		prev = cur
	end
	if steps % 2 == 1 then
		buffer.writeu8(b, base + nbytes - 1, byte)
	end
	w.n = base + nbytes
	if escapes then
		for _, d in escapes do
			w_zz(w, d)
		end
	end
end

local function read_path(r: Reader): { number }
	local n = r_var(r)
	local W = r_var(r)
	if W < 1 or n > MAX_CELLS then
		error("Protocol: bad path")
	end
	local first = r_var(r)
	local out = table.create(n)
	out[1] = first
	local steps = n - 1
	local nbytes = (steps + 1) // 2
	if r.n + nbytes > r.len then
		error("Protocol: path past end")
	end
	local codes_at = r.n
	r.n += nbytes
	local x, y = first % W, first // W
	local b = r.b
	for i = 1, steps do
		local byte = buffer.readu8(b, codes_at + (i - 1) // 2)
		local code = if i % 2 == 1 then byte % 16 else byte // 16
		if code == 15 then
			local t = out[i] + r_zz(r)
			out[i + 1] = t
			x, y = t % W, t // W
		else
			local dy = code // 3 - 1
			local dx = code % 3 - 1
			x += dx
			y += dy
			out[i + 1] = y * W + x
		end
	end
	return out
end

local write_value: (w: Writer, v: any) -> ()

local function write_table(w: Writer, v: { [any]: any })
	local n = #v
	if n == 0 then
		if next(v) == nil then
			w_u8(w, 12)
			return
		end
		-- string-keyed map
		local count = 0
		for k in v do
			if type(k) ~= "string" then
				error("Protocol: unsupported table key type " .. typeof(k))
			end
			count += 1
		end
		w_u8(w, 10)
		w_var(w, count)
		for k, x in v do
			w_str(w, k :: string)
			write_value(w, x)
		end
		return
	end
	local count = 0
	for _ in v do
		count += 1
	end
	if count ~= n then
		error("Protocol: mixed array/map tables are not supported")
	end
	local all_int = n >= 2
	if all_int then
		for i = 1, n do
			local x = v[i]
			if type(x) ~= "number" or x ~= floor(x) or x >= TWO52 or x <= -TWO52 then
				all_int = false
				break
			end
		end
	end
	if not all_int then
		w_u8(w, 7)
		w_var(w, n)
		for i = 1, n do
			write_value(w, v[i])
		end
		return
	end
	if n >= 4096 then
		-- big grid-like arrays: run-length encode when runs are long
		local runs = 1
		for i = 2, n do
			if v[i] ~= v[i - 1] then
				runs += 1
			end
		end
		if runs * 4 < n then
			w_u8(w, 14)
			w_var(w, n)
			local i = 1
			while i <= n do
				local x = v[i]
				local j = i + 1
				while j <= n and v[j] == x do
					j += 1
				end
				w_zz(w, x)
				w_var(w, j - i)
				i = j
			end
			return
		end
	end
	if n >= 4 and w.gw > 0 and path_escapes(w.gw, v, n) * 4 <= n then
		write_path(w, v, n)
		return
	end
	w_u8(w, 8)
	w_var(w, n)
	local prev = 0
	for i = 1, n do
		local x = v[i]
		w_zz(w, x - prev)
		prev = x
	end
end

local function write_grid_rle(w: Writer, b: buffer, width: number)
	local cells = buffer.len(b) // width
	w_u8(w, 13)
	w_u8(w, width)
	w_var(w, cells)
	-- Direct buffer.* calls (not an aliased local) so Luau uses its builtin fast paths.
	if width == 4 then
		local len = cells * 4
		local i = 0
		while i < len do
			local x = buffer.readu32(b, i)
			local j = i + 4
			while j < len and buffer.readu32(b, j) == x do
				j += 4
			end
			w_var(w, x)
			w_var(w, (j - i) // 4)
			i = j
		end
	elseif width == 1 then
		local i = 0
		while i < cells do
			local x = buffer.readu8(b, i)
			local j = i + 1
			while j < cells and buffer.readu8(b, j) == x do
				j += 1
			end
			w_var(w, x)
			w_var(w, j - i)
			i = j
		end
	else
		local i = 0
		while i < cells do
			local x = buffer.readu16(b, i * 2)
			local j = i + 1
			while j < cells and buffer.readu16(b, j * 2) == x do
				j += 1
			end
			w_var(w, x)
			w_var(w, j - i)
			i = j
		end
	end
end

write_value = function(w: Writer, v: any)
	local t = type(v)
	if t == "number" then
		if v == floor(v) and v < TWO53 and v > -TWO53 then
			if v >= 0 then
				if v < 240 then
					w_u8(w, 16 + v)
				else
					w_u8(w, 3)
					w_var(w, v)
				end
			else
				w_u8(w, 4)
				w_var(w, -v - 1)
			end
		else
			w_u8(w, 5)
			w_f64(w, v)
		end
	elseif t == "string" then
		w_u8(w, 6)
		w_str(w, v)
	elseif t == "boolean" then
		w_u8(w, if v then 2 else 1)
	elseif t == "table" then
		write_table(w, v)
	elseif t == "nil" then
		w_u8(w, 0)
	elseif t == "buffer" then
		local len = buffer.len(v)
		local cells = w.cells
		if
			cells > 0
			and len >= 4096
			and len % cells == 0
			and (len // cells == 1 or len // cells == 2 or len // cells == 4)
		then
			write_grid_rle(w, v, len // cells)
		else
			w_u8(w, 11)
			w_var(w, len)
			w_bytes(w, v, 0, len)
		end
	else
		error("Protocol: unsupported value type " .. typeof(v))
	end
end

local read_value: (r: Reader, depth: number) -> any

read_value = function(r: Reader, depth: number): any
	if depth > 32 then
		error("Protocol: nesting too deep")
	end
	local tag = r_u8(r)
	if tag >= 16 then
		return tag - 16
	elseif tag == 3 then
		return r_var(r)
	elseif tag == 7 then
		local n = r_var(r)
		if n > r.len then
			error("Protocol: array too long")
		end
		local out = table.create(n)
		for i = 1, n do
			out[i] = read_value(r, depth + 1)
		end
		return out
	elseif tag == 6 then
		return r_str(r)
	elseif tag == 9 then
		return read_path(r)
	elseif tag == 8 then
		local n = r_var(r)
		if n > r.len then
			error("Protocol: array too long")
		end
		local out = table.create(n)
		local prev = 0
		for i = 1, n do
			prev += r_zz(r)
			out[i] = prev
		end
		return out
	elseif tag == 4 then
		return -r_var(r) - 1
	elseif tag == 1 then
		return false
	elseif tag == 2 then
		return true
	elseif tag == 0 then
		return nil
	elseif tag == 5 then
		return r_f64(r)
	elseif tag == 10 then
		local n = r_var(r)
		local out = {}
		for _ = 1, n do
			local k = r_str(r)
			out[k] = read_value(r, depth + 1)
		end
		return out
	elseif tag == 12 then
		return {}
	elseif tag == 11 then
		local len = r_var(r)
		if r.n + len > r.len then
			error("Protocol: buffer past end")
		end
		local out = buffer.create(len)
		buffer.copy(out, 0, r.b, r.n, len)
		r.n += len
		return out
	elseif tag == 13 then
		local width = r_u8(r)
		local cells = r_var(r)
		if width ~= 1 and width ~= 2 and width ~= 4 then
			error("Protocol: bad grid width")
		end
		if cells > MAX_CELLS then
			error("Protocol: grid too large")
		end
		local out = buffer.create(cells * width)
		local i = 0
		local runs = 0
		while i < cells do
			local x = r_var(r)
			local len = r_var(r)
			if i + len > cells then
				error("Protocol: grid run past end")
			end
			if x ~= 0 then
				if width == 1 then
					buffer.fill(out, i, x, len)
				elseif width == 4 then
					for k = i, i + len - 1 do
						buffer.writeu32(out, k * 4, x)
					end
				else
					for k = i, i + len - 1 do
						buffer.writeu16(out, k * 2, x)
					end
				end
			end
			i += len
			runs += 1
			if runs % 512 == 0 then
				Coop.check()
			end
		end
		return out
	elseif tag == 14 then
		local n = r_var(r)
		if n > MAX_CELLS then
			error("Protocol: array too long")
		end
		local out = table.create(n)
		local i = 1
		local runs = 0
		while i <= n do
			local x = r_zz(r)
			local len = r_var(r)
			if i + len - 1 > n then
				error("Protocol: run past end")
			end
			for k = i, i + len - 1 do
				out[k] = x
			end
			i += len
			runs += 1
			if runs % 512 == 0 then
				Coop.check()
			end
		end
		return out
	end
	error("Protocol: bad tag " .. tag)
end

-- =============================================================================================
-- Envelope
-- =============================================================================================

--- Returns the body buffer and the offset its first byte is at.
function Protocol.open(msg: buffer): (buffer, number)
	local mode = buffer.readu8(msg, 0)
	if mode == 0 then
		return msg, 1
	elseif mode == 1 then
		local c = codec
		if c == nil then
			error("Protocol: compressed message but no codec")
		end
		local r = r_new(msg, 1)
		local raw_size = r_var(r)
		local z = buffer.create(buffer.len(msg) - r.n)
		buffer.copy(z, 0, msg, r.n, buffer.len(z))
		local body = c.decompress(z, raw_size)
		if buffer.len(body) ~= raw_size then
			error("Protocol: decompressed size mismatch")
		end
		return body, 0
	end
	error("Protocol: bad envelope " .. mode)
end

--- Compresses a raw message (envelope 0) when it is larger than `threshold` bytes and zstd helps.
function Protocol.compress(msg: buffer, threshold: number?): buffer
	local len = buffer.len(msg)
	local c = codec
	if c == nil or len <= (threshold or Protocol.COMPRESS_OVER_BYTES) or buffer.readu8(msg, 0) ~= 0 then
		return msg
	end
	local body = buffer.create(len - 1)
	buffer.copy(body, 0, msg, 1, len - 1)
	local z = c.compress(body)
	local w = w_new(buffer.len(z) + 10)
	w_u8(w, 1)
	w_var(w, len - 1)
	w_bytes(w, z, 0, buffer.len(z))
	if w.n >= len then
		return msg
	end
	return w_finish(w)
end

-- =============================================================================================
-- Delta
-- =============================================================================================

local function packed_len(v: any): number
	if type(v) == "buffer" then
		return buffer.len(v) // 4
	end
	return #v
end

local function packed_get(v: any, i: number): number
	-- 1-based index for both representations
	if type(v) == "buffer" then
		return buffer.readi32(v, (i - 1) * 4)
	end
	return v[i]
end

-- (tile << shift | value) lists: runs of equal value, zigzag deltas of the tile index.
local function write_tile_list(w: Writer, v: any, base: number)
	local n = packed_len(v)
	w_u8(w, if type(v) == "buffer" then 1 else 0)
	w_var(w, n)
	local prev_tile = 0
	local i = 1
	while i <= n do
		local x = packed_get(v, i)
		local val = x % base
		local j = i + 1
		while j <= n and packed_get(v, j) % base == val do
			j += 1
		end
		w_var(w, val)
		w_var(w, j - i)
		for k = i, j - 1 do
			local tile = packed_get(v, k) // base
			w_zz(w, tile - prev_tile)
			prev_tile = tile
		end
		i = j
	end
end

local function read_tile_list(r: Reader, base: number): any
	local repr = r_u8(r)
	local n = r_var(r)
	if n > MAX_CELLS then
		error("Protocol: tile list too long")
	end
	local out: any = if repr == 1 then buffer.create(n * 4) else table.create(n)
	local prev_tile = 0
	local i = 1
	while i <= n do
		local val = r_var(r)
		local len = r_var(r)
		if i + len - 1 > n then
			error("Protocol: tile run past end")
		end
		for k = i, i + len - 1 do
			prev_tile += r_zz(r)
			local x = prev_tile * base + val
			if repr == 1 then
				buffer.writei32(out, (k - 1) * 4, x)
			else
				out[k] = x
			end
		end
		i += len
	end
	return out
end

local function write_int_list(w: Writer, v: any)
	local n = packed_len(v)
	w_u8(w, if type(v) == "buffer" then 1 else 0)
	w_var(w, n)
	for i = 1, n do
		w_zz(w, packed_get(v, i))
	end
end

local function read_int_list(r: Reader): any
	local repr = r_u8(r)
	local n = r_var(r)
	if n > r.len * 2 then
		error("Protocol: int list too long")
	end
	if repr == 1 then
		local out = buffer.create(n * 4)
		for i = 0, n - 1 do
			buffer.writei32(out, i * 4, r_zz(r))
		end
		return out
	end
	local out = table.create(n)
	for i = 1, n do
		out[i] = r_zz(r)
	end
	return out
end

local DELTA_KEYS = { t = true, tiles = true, flags = true, stats = true, ev = true }

--- Encodes a Sim delta. `ev` (optional) replaces delta.ev (the server passes the public events);
--- `grid_w` is the map width (sim.W) so unit paths use the compact path encoding.
function Protocol.encode_delta(d: { [string]: any }, ev: { any }?, grid_w: number?): buffer
	local w = w_new(256)
	w.gw = grid_w or 0
	w_u8(w, 0)
	w_u8(w, Protocol.KIND_DELTA)
	local events = if ev ~= nil then ev else d.ev
	local extra: { [string]: any }? = nil
	for k, x in d do
		if not DELTA_KEYS[k] then
			if extra == nil then
				extra = {}
			end
			(extra :: any)[k] = x
		end
	end
	local mask = 0
	if d.tiles ~= nil then
		mask += 1
	end
	if d.flags ~= nil then
		mask += 2
	end
	if d.stats ~= nil then
		mask += 4
	end
	if events ~= nil then
		mask += 8
	end
	if extra ~= nil then
		mask += 16
	end
	if d.t ~= nil then
		mask += 32
	end
	w_u8(w, mask)
	if d.t ~= nil then
		w_var(w, d.t)
	end
	if d.tiles ~= nil then
		write_tile_list(w, d.tiles, 1024)
	end
	if d.flags ~= nil then
		write_tile_list(w, d.flags, 256)
	end
	if d.stats ~= nil then
		write_int_list(w, d.stats)
	end
	if events ~= nil then
		local list = events :: { any }
		w_var(w, #list)
		for _, e in list do
			write_value(w, e)
		end
	end
	if extra ~= nil then
		write_value(w, extra)
	end
	return w_finish(w)
end

--- Per-recipient private events: list of {position, event} (position = index in that recipient's
--- event list, ascending).
function Protocol.encode_tail(list: { { any } }, grid_w: number?): buffer
	local w = w_new(64)
	w.gw = grid_w or 0
	w_u8(w, 0)
	w_u8(w, Protocol.KIND_TAIL)
	w_var(w, #list)
	for _, pe in list do
		w_var(w, pe[1])
		write_value(w, pe[2])
	end
	return w_finish(w)
end

function Protocol.decode_delta(msg: buffer, tail: buffer?): { [string]: any }
	local body, off = Protocol.open(msg)
	local r = r_new(body, off)
	if r_u8(r) ~= Protocol.KIND_DELTA then
		error("Protocol: not a delta")
	end
	local mask = r_u8(r)
	local d: { [string]: any } = {}
	if mask // 32 % 2 == 1 then
		d.t = r_var(r)
	end
	if mask % 2 == 1 then
		d.tiles = read_tile_list(r, 1024)
	end
	if mask // 2 % 2 == 1 then
		d.flags = read_tile_list(r, 256)
	end
	if mask // 4 % 2 == 1 then
		d.stats = read_int_list(r)
	end
	if mask // 8 % 2 == 1 then
		local n = r_var(r)
		local evs = table.create(n)
		for i = 1, n do
			evs[i] = read_value(r, 1)
		end
		d.ev = evs
	end
	if mask // 16 % 2 == 1 then
		local extra = read_value(r, 1)
		for k, x in extra do
			d[k] = x
		end
	end
	if tail ~= nil then
		local tb, toff = Protocol.open(tail)
		local tr = r_new(tb, toff)
		if r_u8(tr) ~= Protocol.KIND_TAIL then
			error("Protocol: not a tail")
		end
		local n = r_var(tr)
		if n > 0 then
			local evs = d.ev
			if evs == nil then
				evs = {}
				d.ev = evs
			end
			for _ = 1, n do
				local pos = r_var(tr)
				local e = read_value(tr, 1)
				table.insert(evs, math.clamp(pos, 1, #evs + 1), e)
			end
		end
	end
	return d
end

--- Splits a delta's events into the shared list (everything but owner-addressed events) and the
--- private events per recipient owner with their positions in that recipient's list.
--- `is_private(ev) -> owner?` returns the recipient for a private event, nil for a public one.
function Protocol.split_events(evs: { any }?, is_private: (any) -> number?): ({ any }, { [number]: { { any } } }?)
	if evs == nil then
		return {}, nil
	end
	local public = {}
	local privates: { [number]: { { any } } }? = nil
	local private_count: { [number]: number } = {}
	for _, e in evs do
		local to = is_private(e)
		if to == nil then
			table.insert(public, e)
		else
			if privates == nil then
				privates = {}
			end
			local p = privates :: { [number]: { { any } } }
			local list = p[to]
			if list == nil then
				list = {}
				p[to] = list
			end
			local k = (private_count[to] or 0) + 1
			private_count[to] = k
			table.insert(list, { #public + k, e })
		end
	end
	return public, privates
end

-- =============================================================================================
-- Snapshot
-- =============================================================================================

--- Encodes a Sim.snapshot(); its map_w / map_h give the path width and the grid cell count.
function Protocol.encode_snapshot(snap: { [string]: any }): buffer
	local w = w_new(64 * 1024)
	local mw = tonumber(snap.map_w) or 0
	local mh = tonumber(snap.map_h) or 0
	w.gw = mw
	w.cells = mw * mh
	w_u8(w, 0)
	w_u8(w, Protocol.KIND_SNAPSHOT)
	write_value(w, snap)
	return w_finish(w)
end

--- Decodes a snapshot. Grid decoding calls Coop.check(), so inside a Coop job it spreads over frames.
function Protocol.decode_snapshot(msg: buffer): { [string]: any }
	local body, off = Protocol.open(msg)
	local r = r_new(body, off)
	if r_u8(r) ~= Protocol.KIND_SNAPSHOT then
		error("Protocol: not a snapshot")
	end
	local snap = read_value(r, 0)
	if type(snap) ~= "table" then
		error("Protocol: bad snapshot")
	end
	return snap
end

-- =============================================================================================
-- Intents (client → server; untrusted on decode)
-- =============================================================================================

local function as_int(v: any): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge or math.abs(v) >= 2147483647 then
		return nil
	end
	-- GDScript int(): truncate toward zero
	return if v >= 0 then floor(v) else -floor(-v)
end

--- Encodes an intent dictionary; returns nil for an unknown type or unusable field (never sent).
function Protocol.encode_intent(intent: { [string]: any }): buffer?
	local idx = INTENT_INDEX[tostring(intent.type)]
	if idx == nil then
		return nil
	end
	local w = w_new(32)
	w_u8(w, 0)
	w_u8(w, Protocol.KIND_INTENT)
	w_u8(w, idx)
	local mask = 0
	local ints = {}
	for bit, key in INTENT_INT_FIELDS do
		local v = intent[key]
		if v ~= nil then
			local iv = as_int(v)
			if iv == nil then
				return nil
			end
			mask += 2 ^ (bit - 1)
			ints[bit] = iv
		end
	end
	local ratio = intent.ratio
	if ratio ~= nil then
		if type(ratio) ~= "number" or ratio ~= ratio or math.abs(ratio) == math.huge then
			return nil
		end
		mask += 32
	end
	local kind = intent.kind
	if kind ~= nil then
		if type(kind) ~= "string" then
			return nil
		end
		mask += 64
	end
	local accept = intent.accept
	if accept ~= nil then
		if type(accept) ~= "boolean" then
			return nil
		end
		mask += 128
	end
	w_u8(w, mask)
	for bit = 1, #INTENT_INT_FIELDS do
		if ints[bit] ~= nil then
			w_zz(w, ints[bit])
		end
	end
	if ratio ~= nil then
		w_f64(w, ratio)
	end
	if kind ~= nil then
		w_str(w, string.sub(kind, 1, 16))
	end
	if accept ~= nil then
		w_u8(w, if accept then 1 else 0)
	end
	local amount = intent.amount
	if amount ~= nil then
		local av = as_int(amount)
		if av == nil or av < 1 or av > Protocol.MAX_INTENT_AMOUNT then
			return nil
		end
		w_u8(w, av)
	end
	return w_finish(w)
end

--- Decodes and sanitizes an intent from a client (port of session.gd `_sanitize_intent`): strict
--- whitelist, only known types and fields, finite numbers, tiles on the map, targets in range.
--- Returns nil for anything malformed. Never errors.
function Protocol.decode_intent(msg: any): { [string]: any }?
	if type(msg) ~= "buffer" then
		return nil
	end
	local len = buffer.len(msg)
	if len < 4 or len > Protocol.MAX_INTENT_BYTES or buffer.readu8(msg, 0) ~= 0 then
		return nil
	end
	local ok, out = pcall(function(): { [string]: any }?
		local r = r_new(msg, 1)
		if r_u8(r) ~= Protocol.KIND_INTENT then
			return nil
		end
		local name = Protocol.INTENT_TYPES[r_u8(r)]
		if name == nil then
			return nil
		end
		local mask = r_u8(r)
		local it: { [string]: any } = { type = name }
		for bit, key in INTENT_INT_FIELDS do
			if mask // (2 ^ (bit - 1)) % 2 == 1 then
				local v = r_zz(r)
				if math.abs(v) >= 2147483647 then
					return nil
				end
				it[key] = v
			end
		end
		if mask // 32 % 2 == 1 then
			local ratio = r_f64(r)
			if ratio ~= ratio or math.abs(ratio) == math.huge then
				return nil
			end
			it.ratio = math.clamp(ratio, 0.01, 1.0)
		end
		if mask // 64 % 2 == 1 then
			local s = r_str(r)
			if #s > 16 then
				return nil
			end
			it.kind = s
		end
		if mask // 128 % 2 == 1 then
			local a = r_u8(r)
			if a > 1 then
				return nil
			end
			it.accept = a == 1
		end
		if r.n == len - 1 then
			local amount = r_u8(r)
			if amount < 1 or amount > Protocol.MAX_INTENT_AMOUNT then
				return nil
			end
			it.amount = amount
		end
		if r.n ~= len then
			return nil
		end
		if it.tile ~= nil and (it.tile < 0 or it.tile >= MAX_CELLS) then
			return nil
		end
		if it.target ~= nil and (it.target < 0 or it.target >= MAX_OWNERS) then
			return nil
		end
		if it.troops ~= nil then
			it.troops = math.max(0, it.troops)
		end
		return it
	end)
	if ok then
		return out
	end
	return nil
end

-- Test hooks
Protocol._write_value = function(v: any, grid_w: number?, cells: number?): buffer
	local w = w_new(64)
	w.gw = grid_w or 0
	w.cells = cells or 0
	w_u8(w, 0)
	write_value(w, v)
	return w_finish(w)
end
Protocol._read_value = function(b: buffer): any
	local r = r_new(b, 1)
	return read_value(r, 0)
end

return Protocol
