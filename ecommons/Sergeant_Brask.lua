-- Sergeant Brask, the Quartermaster. Issues any charm you have earned the band
-- for, and any raid sigil you have earned the era for, in unlimited copies,
-- FREE.
--
-- WHY FREE. He used to charge band * 10 pp. Two things make that wrong here.
--
-- Measured against the live items table, the charms were priced at two to four
-- times what comparable gear is actually worth - a band-20 charm is 25hp/5ac,
-- and 32 comparable items at that level average 51pp against the 200pp he asked.
--
-- The deeper problem is that platinum is not a resource on this server. There is
-- no player economy, no bazaar, and EQEmu has no coin multiplier rule to tune -
-- income is vendoring drops, which is tedium rather than content. So any price
-- was a grind tax on rewards the player had ALREADY earned, payable in the one
-- currency the server cannot generate interestingly.
--
-- The gate is the band flag. That is real content and it is enough.
--
-- He is also a quartermaster rather than a merchant, and a quartermaster issues
-- kit to soldiers entitled to it. Charging was always slightly out of character.
--
-- Unlimited is the point: you are equipping an army, not a character. That is
-- also why the charms are not lore - a lore charm could only be held one at a
-- time, which would make kitting six bots an afternoon of walking back and forth.
--
-- HE ISSUES ACROSS ARCHETYPES. A warrior may draw the Vessel charm for their
-- cleric bot. The item's own class bitmask still decides who can wear it, so
-- there is nothing to police here: drawing the wrong one costs nothing at all.
-- Gating the stores by the drawer's class would only stop people equipping the
-- bots this exists to equip.
--
-- What he checks is the BAND FLAG, which is account-wide. Earning band 20 on any
-- character opens band 20's whole shelf to every character on the account.
local flags = require("airaid_flags")
local pools = require("airaid_pools")
local charms = require("airaid_charms")

local function tell(e, text)
	e.other:Message(MT.Yellow, text)
end

-- eq.say_link(what_is_said, silent, what_is_shown). The spoken half is the
-- parser key below; the shown half is the item's own name, so the list reads as
-- a shelf rather than as commands.
local function offer(said, shown)
	return eq.say_link(said, true, shown)
end

local function issue(e, item_id, label)
	e.other:SummonItem(item_id)
	tell(e, label .. " - issued. Come back for as many as you have need of.")
end

-- ---------------------------------------------------------------------------

local function show_shelf(e, account_id)
	local shown = 0

	for _, band in ipairs(flags.band_numbers()) do
		if flags.band_claimed(account_id, band) then
			local line = "Band " .. band .. ": "
			local parts = {}

			for _, key in ipairs(charms.archetype_order) do
				local item_id = charms.charms[key] and charms.charms[key][band]

				if item_id then
					table.insert(parts, offer(key .. " " .. band, charms.archetype_name[key]))
				end
			end

			tell(e, line .. table.concat(parts, "  "))
			shown = shown + 1
		end
	end

	for key, _ in pairs(pools.raids) do
		local progress = flags.raid_progress(account_id, key)

		if progress ~= nil and progress.complete then
			local parts = {}

			for _, archetype in ipairs(charms.archetype_order) do
				local item_id = charms.augs[archetype] and charms.augs[archetype][progress.era]

				if item_id then
					table.insert(parts, offer("sigil " .. archetype .. " " .. progress.era,
						charms.archetype_name[archetype]))
				end
			end

			if #parts > 0 then
				tell(e, "Sigils of this age: " .. table.concat(parts, "  "))
				shown = shown + 1
			end
		end
	end

	if shown == 0 then
		tell(e, "You have earned nothing from me yet. Speak to Wyn - she keeps the maps.")
	end
end

-- ---------------------------------------------------------------------------

function event_say(e)
	if not e.other.valid then
		return
	end

	local account_id = e.other:AccountID()
	local message = e.message:lower()

	if message:findi("hail") then
		e.self:Say("Quartermaster Brask. Wyn marks the maps, I keep the stores. "
			.. "Anything you have earned, you may draw as often as you like - "
			.. "your companions need arming too, and they do not carry coin.")
		show_shelf(e, account_id)
		return
	end

	-- "sigil <archetype> <era>"
	local archetype, era = message:match("^sigil%s+(%a+)%s+(%d+)$")

	if archetype and charms.augs[archetype] then
		era = tonumber(era)

		local progress = nil

		for key, spec in pairs(pools.raids) do
			if spec.era == era then
				progress = flags.raid_progress(account_id, key)
			end
		end

		if progress == nil or not progress.complete then
			tell(e, "You have not earned the sigils of that age.")
			return
		end

		local item_id = charms.augs[archetype][era]

		if item_id == nil then
			tell(e, "No such sigil.")
			return
		end

		issue(e, item_id, "Sigil of the " .. charms.archetype_name[archetype])
		return
	end

	-- "<archetype> <band>"
	local key, band = message:match("^(%a+)%s+(%d+)$")

	if key and charms.charms[key] then
		band = tonumber(band)

		if not flags.band_claimed(account_id, band) then
			tell(e, "You have not earned band " .. band .. ". Wyn will tell you what is left.")
			return
		end

		local item_id = charms.charms[key][band]

		if item_id == nil then
			tell(e, "I keep no charm of that band.")
			return
		end

		issue(e, item_id, charms.archetype_name[key] .. " charm of band " .. band)
	end
end
