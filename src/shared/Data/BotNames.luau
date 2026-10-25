--!strict
-- Names for bot players (the AI commanders that fill empty public-match slots). By design they look
-- like ordinary player names (2026-09-26, so that bots pass for real
-- players): gamer-style handles built from word lists, e.g. "IronFalcon", "nova_ryder",
-- "Blaze27", "QuietStorm_9". Deterministic for a given random source (the Sim's RNG), unique within
-- one call's `taken` set.

local BotNames = {}

local FIRST = {
	"Iron",
	"Nova",
	"Shadow",
	"Silent",
	"Frost",
	"Blaze",
	"Storm",
	"Lunar",
	"Solar",
	"Crimson",
	"Echo",
	"Rogue",
	"Swift",
	"Atlas",
	"Ember",
	"Onyx",
	"Cobalt",
	"Viper",
	"Rapid",
	"Quiet",
	"Night",
	"Golden",
	"Wild",
	"Bright",
	"Dark",
	"Lucky",
	"Mighty",
	"Neon",
	"Pixel",
	"Turbo",
	"Arctic",
	"Stealth",
	"Hyper",
	"Royal",
	"Sly",
	"Brave",
	"Cosmic",
	"Mystic",
	"Rusty",
	"Titan",
	"Zen",
	"Aqua",
	"Lazy",
	"Epic",
	"Chill",
	"Sonic",
	"Venom",
	"Ghost",
	"Alpha",
	"Omega",
	"Red",
	"Blue",
	"Grey",
	"Jade",
	"Scarlet",
	"Amber",
	"Polar",
	"Desert",
	"Jungle",
	"Coastal",
}

local SECOND = {
	"Falcon",
	"Ryder",
	"Wolf",
	"Storm",
	"Tide",
	"Fox",
	"Hawk",
	"Knight",
	"Raven",
	"Tiger",
	"Comet",
	"Pilot",
	"Ranger",
	"Viking",
	"Ninja",
	"Dragon",
	"Panther",
	"Orbit",
	"Arrow",
	"Bolt",
	"Blade",
	"Spark",
	"Rider",
	"Hunter",
	"Legend",
	"Sniper",
	"Warden",
	"Captain",
	"Baron",
	"Rebel",
	"Nomad",
	"Phantom",
	"Racer",
	"Sparrow",
	"Bear",
	"Lynx",
	"Cobra",
	"Shark",
	"Owl",
	"Stag",
	"Mage",
	"Scout",
	"Pirate",
	"Samurai",
	"Duke",
	"General",
	"Major",
	"Titan",
	"Golem",
	"Kraken",
	"Moose",
	"Otter",
	"Badger",
	"Falcon",
	"Jester",
	"Maverick",
	"Voyager",
	"Spectre",
	"Drifter",
	"Ace",
}

local SINGLE = {
	"Kaizen",
	"Morrow",
	"Zephyr",
	"Quill",
	"Brixton",
	"Marlow",
	"Juniper",
	"Oakley",
	"Rowan",
	"Sable",
	"Tobias",
	"Wren",
	"Kestrel",
	"Lachlan",
	"Nico",
	"Ezra",
	"Milo",
	"Jasper",
	"Felix",
	"Leo",
	"Arlo",
	"Silas",
	"Theo",
	"Ivy",
	"Luna",
	"Nova",
	"Aria",
	"Zara",
	"Kira",
	"Maya",
}

--- A name from `rand` (a function returning [0, 1)).
function BotNames.one(rand: () -> number): string
	local function pick(list: { string }): string
		return list[math.floor(rand() * #list) + 1]
	end
	local style = rand()
	if style < 0.35 then
		return pick(FIRST) .. pick(SECOND)
	elseif style < 0.55 then
		return string.lower(pick(FIRST)) .. "_" .. string.lower(pick(SECOND))
	elseif style < 0.75 then
		return pick(FIRST) .. pick(SECOND) .. tostring(math.floor(rand() * 99) + 1)
	elseif style < 0.9 then
		return pick(SINGLE) .. tostring(math.floor(rand() * 900) + 100)
	end
	return pick(FIRST) .. "_" .. pick(SINGLE)
end

--- `n` distinct names not in `taken` (a set of names already used in the match; updated).
function BotNames.many(n: number, rand: () -> number, taken: { [string]: boolean }?): { string }
	local used = taken or {}
	local out = {}
	local guard = 0
	while #out < n and guard < n * 50 do
		guard += 1
		local name = BotNames.one(rand)
		if not used[name] then
			used[name] = true
			table.insert(out, name)
		end
	end
	-- the word lists are large; this never runs short in practice
	while #out < n do
		local name = "Player" .. tostring(#out + 1000)
		used[name] = true
		table.insert(out, name)
	end
	return out
end

return BotNames
