--!strict
-- The Arsenal: units and boosters a player unlocks for good (2026-10-04: units like Artillery and
-- special nukes, unlocked either by grinding Stars in game or by buying them with Robux — the same model
-- as Pixel Conquest's extra-buildings passes, with its prices).
--
--   stars    the price in Stars, the currency earned by playing (Data/Stars); nil: Robux only
--   product  the developer product that unlocks it for Robux (Data/Products; its `robux` is the
--            price shown until Roblox answers with the real one)
--   bonus    Stars paid once with the unlock, however it was bought
--   bit      the Defs.UNLOCK bit the Sim checks (0: the Sim doesn't care — 2x Stars)
--
-- An unlock is saved on the player's record (server/Purchases: `unlocks`), by ProcessReceipt for a
-- Robux purchase or by Purchases.buy_unlock for Stars. The rules and numbers of each unit are the
-- Sim's (Core/Rules "The Arsenal", Core/SimArsenal); the copy here only describes them.
local IS_ROBLOX = typeof(game) == "Instance"
local Defs: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Core.Defs)
	else require("../Core/Defs")

local Arsenal = {}

export type Item = {
	key: string,
	title: string,
	--- "structure" (built on your land), "nuke" (launched from a silo), "strike" (fired from its
	--- structure), "call" (an instant order), "boost" (always on)
	kind: string,
	icon: string,
	tagline: string,
	blurb: string,
	perks: { string },
	--- the shop's one sentence: what it does, in plain words (2026-10-24: the Arsenal UI was too
	--- confusing and had to be simpler)
	plain: string,
	--- the shop's two short facts
	facts: { string },
	stars: number?,
	product: string,
	bonus: number?,
	bit: number,
	--- the build / launch kinds it opens in a match (UIRules kinds)
	opens: { string },
	--- card colours (top, bottom), 0xRRGGBB
	color: { number },
}

--- In shop order: cheapest in Stars first, the Robux-only boosters last.
Arsenal.ITEMS = {
	{
		key = "mega",
		title = "Mega Nuke",
		kind = "nuke",
		icon = "mega",
		tagline = "4x the blast of an Atom Bomb",
		blurb = "A warhead with twice an Atom Bomb's radius: four times the ground, gone. Launches from your Missile Silos.",
		perks = { "4X BLAST AREA", "2.5M GOLD A LAUNCH" },
		plain = "A nuke that blows up 4 times the area of an Atom Bomb. Launch it from your Missile Silos.",
		facts = { "4x blast", "Launch from silos" },
		stars = 20000,
		product = "unlock_mega",
		bit = Defs.UNLOCK.mega,
		opens = { "mega" },
		color = { 0xE2483A, 0x7A1420 },
	},
	{
		key = "scatter",
		title = "Scattershot",
		kind = "nuke",
		icon = "scatter",
		tagline = "A nuke that brings 4 to 6 warheads",
		blurb = "An Atom Bomb with 4 to 6 extra warheads that come down all around it. One SAM can't stop them all.",
		perks = { "4-6 EXTRA WARHEADS", "BEATS A LONE SAM" },
		plain = "One nuke that splits into 4 to 6 warheads. A single SAM can't stop them all.",
		facts = { "4-6 warheads", "Beats SAMs" },
		stars = 40000,
		product = "unlock_scatter",
		bit = Defs.UNLOCK.scatter,
		opens = { "scatter" },
		color = { 0xF08A24, 0x8A3A0C },
	},
	{
		key = "reinforce",
		title = "Reinforcements",
		kind = "call",
		icon = "reinforce",
		tagline = "Troops for gold, on call",
		blurb = "Call in a fifth of your troop cap at once for 100K gold. Ready again every 30 seconds.",
		perks = { "+20% ARMY AT ONCE", "EVERY 30 SECONDS" },
		plain = "Pay gold to get 20% more troops at once. Ready again every 30 seconds.",
		facts = { "+20% troops", "Every 30 s" },
		stars = 40000,
		product = "unlock_reinforce",
		bit = Defs.UNLOCK.reinforce,
		opens = { "reinforce" },
		color = { 0x35B86B, 0x0E5A34 },
	},
	{
		key = "artillery",
		title = "Artillery",
		kind = "structure",
		icon = "artillery",
		tagline = "Shells every enemy in range",
		blurb = "A battery that fires on its own at every enemy within 45 tiles: their troops, and the structures it can reach.",
		perks = { "FIRES ON ITS OWN", "+5,000 STARS" },
		plain = "Build cannons that fire by themselves at every enemy within 45 tiles.",
		facts = { "Fires by itself", "+5,000 free Stars" },
		stars = 50000,
		product = "unlock_artillery",
		bonus = 5000,
		bit = Defs.UNLOCK.artillery,
		opens = { "artillery" },
		color = { 0x4C8DF0, 0x1A3A8A },
	},
	{
		key = "airfield",
		title = "Air Strike",
		kind = "structure",
		icon = "airfield",
		-- (2026-10-12: the tagline says this unlock is what lets you build Airfields)
		tagline = "Build Airfields that bomb 156 tiles away",
		blurb = "Build Airfields and call air strikes: a 15-tile carpet that kills troops and wrecks structures. No SAM can stop one. Rearms in 30 seconds.",
		perks = { "BUILD AIRFIELDS", "+5,000 STARS" },
		plain = "Build airfields and bomb anything up to 156 tiles away. SAMs can't stop it.",
		facts = { "156-tile range", "+5,000 free Stars" },
		stars = 200000,
		product = "unlock_airfield",
		bonus = 5000,
		bit = Defs.UNLOCK.airfield,
		opens = { "airfield", "airstrike" },
		color = { 0x2FB7C9, 0x0D5670 },
	},
	{
		key = "railgun",
		title = "Railgun",
		kind = "structure",
		icon = "railgun",
		tagline = "Snipe anything, anywhere on the map",
		blurb = "No range limit. One slug takes a level off every structure it hits and razes the small ones. Nothing intercepts it. Reloads in 25 seconds.",
		perks = { "NO RANGE LIMIT", "CAN'T BE INTERCEPTED" },
		plain = "Hit any building anywhere on the map. Nothing can stop the shot.",
		facts = { "No range limit", "Unstoppable" },
		stars = 500000,
		product = "unlock_railgun",
		bit = Defs.UNLOCK.railgun,
		opens = { "railgun", "slug" },
		color = { 0xA35BFF, 0x3D1A8A },
	},
	{
		key = "stars2x",
		title = "2x Stars",
		kind = "boost",
		icon = "star",
		tagline = "Every match pays double, forever",
		blurb = "Doubles the Stars every match pays you, for good.",
		perks = { "DOUBLE STARS", "EVERY MATCH" },
		plain = "Every match pays you double Stars, forever.",
		facts = { "2x Stars", "Every match" },
		product = "unlock_stars2x",
		bit = 0,
		opens = {},
		color = { 0xFFC83D, 0x9A6200 },
	},
	{
		key = "reload2x",
		title = "Rapid Reload",
		kind = "boost",
		icon = "reload",
		tagline = "Everything you own reloads twice as fast",
		blurb = "Your Missile Silos, SAMs, Artillery, Airfields and Railguns all reload in half the time.",
		perks = { "2X RELOAD SPEED", "ALL STRUCTURES" },
		plain = "Your silos, SAMs, cannons, airfields and railguns reload twice as fast.",
		facts = { "2x reload", "Everything you build" },
		product = "unlock_reload2x",
		bit = Defs.UNLOCK.reload2x,
		opens = {},
		color = { 0xE85BB0, 0x7A1A5A },
	},
} :: { Item }

local BY_KEY: { [string]: Item } = {}
--- build / launch kind -> the item that opens it
local BY_KIND: { [string]: Item } = {}
for _, it in Arsenal.ITEMS do
	BY_KEY[it.key] = it
	for _, k in it.opens do
		BY_KIND[k] = it
	end
end

function Arsenal.item(key: any): Item?
	return if type(key) == "string" then BY_KEY[key] else nil
end

--- The item a build / launch kind ("artillery", "mega", "airstrike", "reinforce"...) belongs to, or nil
--- for the kinds everyone has.
function Arsenal.item_for(kind: string): Item?
	return BY_KIND[kind]
end

--- The Defs.UNLOCK mask of a set of unlock keys ({ [key] = true } or a list of keys).
function Arsenal.mask(unlocks: any): number
	local m = 0
	if type(unlocks) ~= "table" then
		return m
	end
	for k, v in unlocks do
		local it = BY_KEY[if type(k) == "string" then k else v]
		if it ~= nil and (v == true or type(k) == "number") then
			m = bit32.bor(m, it.bit)
		end
	end
	return m
end

--- The cheapest item (in Stars) the player doesn't own yet: what the Stars they earn go towards.
function Arsenal.next_goal(owned: { [string]: boolean }): Item?
	for _, it in Arsenal.ITEMS do
		if it.stars ~= nil and not owned[it.key] then
			return it
		end
	end
	return nil
end

return Arsenal
