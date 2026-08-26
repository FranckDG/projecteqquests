-- The Keeper of Legends - AI Raid bot epic registrar.
--
-- Earn a class epic once the honest way, then arm every bot of that class.
--
--   hand him an epic     registers that class on your ACCOUNT and hands it back
--   say the class name   summons a copy, free, as often as you like
--
-- The community's usual answer to bot epics sells equivalents for platinum,
-- which removes the grind and the achievement together. This keeps the first
-- one earned and only removes the absurdity of running the same chain twelve
-- times to arm a roster.
--
-- Registration uses SetAccountBucket rather than SetBucket deliberately: the
-- character who ran the quest and the characters who benefit are rarely the
-- same one.
--
-- Gated behind Kunark - epics are Kunark content, and the ladder is the point
-- of the server.

local item_lib = require("items")

local epics = {
	{ class = "warrior",      item = 10908, name = "Jagged Blade of War" },
	{ class = "cleric",       item =  5532, name = "Water Sprinkler of Nem Ankh" },
	{ class = "paladin",      item = 10099, name = "Fiery Defender" },
	{ class = "ranger",       item = 20488, name = "Earthcaller" },
	{ class = "shadowknight", item = 14383, name = "Innoruuk's Curse" },
	{ class = "druid",        item = 20490, name = "Nature Walkers Scimitar" },
	{ class = "monk",         item = 10652, name = "Celestial Fists" },
	{ class = "bard",         item = 20542, name = "Singing Short Sword" },
	{ class = "rogue",        item = 11057, name = "Ragebringer" },
	{ class = "shaman",       item = 10651, name = "Spear of Fate" },
	{ class = "necromancer",  item = 20544, name = "Scythe of the Shadowed Soul" },
	{ class = "wizard",       item = 14341, name = "Staff of the Four" },
	{ class = "magician",     item = 28034, name = "Orb of Mastery" },
	{ class = "enchanter",    item = 10650, name = "Staff of the Serpent" },
}
-- Beastlord and Berserker have no 1.0 epic; they arrived with Luclin and Gates
-- of Discord.

local BUCKET_PREFIX = "airaid:epic:"

-- Kunark is expansion 1. The era controller stamps the current era for us.
local function kunark_is_open()
	local expansion = tonumber(eq.get_data("airaid:era_expansion"))
	return expansion ~= nil and expansion >= 1
end

local function is_registered(client, entry)
	return client:GetAccountBucket(BUCKET_PREFIX .. entry.class) ~= ""
end

function event_say(e)
	if not kunark_is_open() then
		e.self:Say("These weapons are not yet forged in this age. Return when Kunark has given up its secrets.")
		return
	end

	for _, entry in ipairs(epics) do
		if e.message:findi(entry.class) then
			if not is_registered(e.other, entry) then
				e.self:Say("I hold no memory of you bearing the " .. entry.name ..
					". Bring it to me once and I shall remember it always.")
				return
			end

			e.other:SummonItem(entry.item)
			e.self:Say("Carry it well. " .. entry.name .. ", as it was and shall be again.")
			return
		end
	end

	local known = {}

	for _, entry in ipairs(epics) do
		if is_registered(e.other, entry) then
			table.insert(known, entry.class)
		end
	end

	e.self:Say("I am the Keeper of Legends. Hand me an epic and I shall remember it. " ..
		"Name its class thereafter and I shall forge another, freely, for as many companions as you can muster.")

	if #known == 0 then
		e.self:Say("You have brought me nothing yet.")
	else
		e.self:Say("I remember, for you: " .. table.concat(known, ", ") .. ".")
	end
end

function event_trade(e)
	if not kunark_is_open() then
		e.self:Say("Not in this age.")
		item_lib.return_items(e.self, e.other, e.trade)
		return
	end

	local registered = {}

	for _, entry in ipairs(epics) do
		if item_lib.check_turn_in(e.trade, { item1 = entry.item }) then
			if not is_registered(e.other, entry) then
				e.other:SetAccountBucket(BUCKET_PREFIX .. entry.class, "1")
				table.insert(registered, entry.name)
			else
				e.self:Say("I already remember the " .. entry.name .. ".")
			end

			-- check_turn_in consumes what it matched, so hand it straight back.
			e.other:SummonItem(entry.item)
		end
	end

	item_lib.return_items(e.self, e.other, e.trade)

	if #registered > 0 then
		e.self:Say("So it is remembered: " .. table.concat(registered, ", ") ..
			". Ask, and I shall forge another.")
	end
end
