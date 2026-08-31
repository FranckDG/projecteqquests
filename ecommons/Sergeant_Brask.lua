-- Sergeant Brask, the Quartermaster. Sells any charm you have earned the band
-- for, and any raid augment you have earned the era for, in unlimited copies.
--
-- Unlimited is the point: you are equipping an army, not a character. That is
-- also why the charms are not lore - a lore charm could only be held one at a
-- time, which would make kitting six bots an afternoon of walking back and forth.
--
-- HE SELLS ACROSS ARCHETYPES. A warrior may buy the Vessel charm for their
-- cleric bot. The item's own class bitmask still decides who can wear it, so
-- there is nothing to police here: buying the wrong one wastes plat, not
-- progress. Gating the shop by the buyer's class would only stop people
-- equipping the bots this exists to equip.
--
-- What he checks is the BAND FLAG, which is account-wide. Earning band 20 on any
-- character opens band 20's whole shelf to every character on the account.
local flags = require("airaid_flags")
local pools = require("airaid_pools")
local charms = require("airaid_charms")

local COPPER_PER_PLATINUM = 1000

-- The design prices charms at band * 10 pp and raid augments at the era's level
-- cap * 20. Keyed to the band NUMBER rather than the reward level, matching the
-- stat curve, so price and power move together.
local function charm_price(band)
	return band * 10
end

local function aug_price()
	local cap = tonumber(eq.get_rule("Character:MaxLevel")) or 50

	return cap * 20
end

local function tell(e, text)
	e.other:Message(MT.Yellow, text)
end

-- eq.say_link(what_is_said, silent, what_is_shown). The spoken half is the
-- parser key below; the shown half is the item's own name, so the list reads as
-- a shelf rather than as commands.
local function offer(said, shown)
	return eq.say_link(said, true, shown)
end

local function sell(e, item_id, price_pp, label)
	if not e.other:TakeMoneyFromPP(price_pp * COPPER_PER_PLATINUM, true) then
		tell(e, "That is " .. price_pp .. "pp, and you do not have it on you.")
		return
	end

	e.other:SummonItem(item_id)
	tell(e, label .. " - " .. price_pp .. "pp. Buy as many as you have need of.")
end

-- ---------------------------------------------------------------------------

local function show_shelf(e, account_id)
	local shown = 0

	for _, band in ipairs(flags.band_numbers()) do
		if flags.band_claimed(account_id, band) then
			local line = "Band " .. band .. " (" .. charm_price(band) .. "pp): "
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
				tell(e, "Sigils of this age (" .. aug_price() .. "pp): "
					.. table.concat(parts, "  "))
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
		e.self:Say("Quartermaster Brask. Wyn marks the maps, I keep what they are "
			.. "worth. Everything here is bought as often as you like - your "
			.. "companions need arming too.")
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

		sell(e, item_id, aug_price(), "Sigil of the " .. charms.archetype_name[archetype])
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

		sell(e, item_id, charm_price(band),
			charms.archetype_name[key] .. " charm of band " .. band)
	end
end
