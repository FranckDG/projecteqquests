-- Wyn Farsight, the Cartographer. Reports exploration progress, pays for it,
-- and hands over a band's charm when it is finished.
--
-- Everything he pays is driven by the generated pools and charm tables, so
-- extending the system to a new era is a regeneration and no change here.
--
-- ---------------------------------------------------------------------------
-- TWO SCOPES, DELIBERATELY DIFFERENT.
--
-- Exploring is ACCOUNT-wide: a dungeon your main cleared counts for every alt,
-- which is the whole reason the flags are keyed by account. Being PAID is
-- PER-CHARACTER: each character collects its own XP and plat for that same
-- dungeon the first time it hails him. So an alt walks in already holding the
-- progress and still gets paid for it, which is the intended reward for having
-- done the exploring once.
--
-- ---------------------------------------------------------------------------
-- XP USES max_level, NOT A FLAT AWARD.
--
-- AddLevelBasedExp(pct, max_level) awards pct% of a level at
-- min(player_level, max_level) - see zone/exp.cpp:1099. Paying at the band's
-- reward level (the TOP of its range) therefore does two things at once: a
-- character who finishes the band on time is paid in full, and a level 50
-- returning for band 10 is capped at a level-20 award rather than a level-50
-- one. That is the design's "over-level claims pay little", for free.
local flags = require("airaid_flags")
local pools = require("airaid_pools")
local charms = require("airaid_charms")

-- The Explorer's Compass (migration 0019). Handed out on the first hail.
local COMPASS = 900500

-- Plain ASCII throughout: this renders in a 2013 client.
local function say(e, text)
	e.self:Say(text)
end

local function tell(e, text)
	e.other:Message(MT.Yellow, text)
end

local function join(list)
	return table.concat(list, ", ")
end

-- Title sets are ARITHMETIC, not a lookup table: 900 + band for level bands,
-- 950 + era for era-pure raid titles. Migration 0018 inserts rows using the same
-- formula, so there is no mapping on either side to fall out of step. A band
-- with no title row grants a set nothing uses - a cosmetic no-op, not an error.
--
-- eq.enable_title acts on the quest INITIATOR, which in event_say is the player
-- who spoke, and grants are per character (player_titlesets.char_id). So an alt
-- inheriting the account's exploring earns its own title when it hails.
local function grant_band_title(band)
	eq.enable_title(900 + band)
end

local function grant_era_title(era)
	eq.enable_title(950 + era)
end

-- ---------------------------------------------------------------------------
-- Paying.
-- ---------------------------------------------------------------------------

local function pay_dungeon(e, account_id, character_id, zone, reward_level)
	if flags.dungeon_paid(account_id, character_id, zone) then
		return false
	end

	flags.mark_dungeon_paid(account_id, character_id, zone)

	e.other:AddLevelBasedExp(25, reward_level)
	e.other:AddMoneyToPP(0, 0, 0, reward_level * 2)

	tell(e, "  " .. zone .. " - " .. (reward_level * 2) .. "pp and experience.")

	return true
end

local function pay_band(e, account_id, character_id, progress)
	if flags.band_paid(account_id, character_id, progress.band) then
		return false
	end

	flags.mark_band_paid(account_id, character_id, progress.band)

	e.other:AddLevelBasedExp(100, progress.reward_level)
	e.other:AddMoneyToPP(0, 0, 0, progress.reward_level * 20)
	grant_band_title(progress.band)

	-- The charm matches the character's own archetype. Which charm that is comes
	-- from the same class bitmask the item carries, so he can never hand over one
	-- the character cannot equip.
	local archetype = charms.archetype_for_class[e.other:GetClass()]
	local item_id = archetype and charms.charms[archetype]
		and charms.charms[archetype][progress.band]

	if item_id then
		e.other:SummonItem(item_id)
		tell(e, "Band " .. progress.band .. " complete. "
			.. (progress.reward_level * 20) .. "pp, a level of experience, and a "
			.. charms.archetype_name[archetype] .. " charm.")
	else
		-- Should be unreachable: every class maps to an archetype and every band
		-- has a charm. Say so rather than paying silently and losing the charm.
		tell(e, "Band " .. progress.band .. " complete, but I have no charm for your "
			.. "calling. Tell Brask - that is not supposed to happen.")
	end

	return true
end

-- ---------------------------------------------------------------------------
-- Reporting.
-- ---------------------------------------------------------------------------

local function report_band(e, account_id, character_id, band)
	local progress = flags.band_progress(account_id, band)

	if progress == nil or progress.available == 0 then
		return
	end

	-- Pay for anything cleared but not yet collected by THIS character, whether
	-- or not the band as a whole is finished.
	for _, zone in ipairs(progress.done_zones) do
		pay_dungeon(e, account_id, character_id, zone, progress.reward_level)
	end

	local claimed = flags.band_claimed(account_id, progress.band)
	local line = "Band " .. progress.band .. " (levels " .. pools.bands[band].range[1]
		.. "-" .. pools.bands[band].range[2] .. "): "
		.. progress.done .. " of " .. progress.required

	if claimed then
		tell(e, line .. " - claimed.")
	elseif progress.complete then
		flags.claim_band(account_id, progress.band)
		pay_band(e, account_id, character_id, progress)
	else
		tell(e, line .. ". Still to clear: " .. join(progress.missing))
	end

	-- A band already claimed on the account still owes THIS character its band
	-- payout the first time it hails.
	if claimed then
		pay_band(e, account_id, character_id, progress)
	end
end

local function report_raid(e, account_id, key)
	local progress = flags.raid_progress(account_id, key)

	if progress == nil or progress.era > flags.current_era() then
		return
	end

	if progress.complete then
		if progress.era_pure then
			grant_era_title(progress.era)
			tell(e, "The great powers of this age have fallen to you, and you were "
				.. "there when it mattered. That is worth a name.")
		else
			tell(e, "The great powers of this age have fallen to you - though the "
				.. "world had already moved on by the time you got there.")
		end
	elseif progress.killed then
		tell(e, "You have struck down a great power, but have yet to walk: "
			.. join(progress.missing))
	elseif progress.visited > 0 then
		tell(e, "You have walked " .. progress.visited .. " of " .. progress.total
			.. " great places. Still to walk: " .. join(progress.missing))
	end
end

-- ---------------------------------------------------------------------------

function event_say(e)
	if not e.other.valid then
		return
	end

	if not e.message:findi("hail") then
		return
	end

	local account_id = e.other:AccountID()
	local character_id = e.other:CharacterID()

	say(e, "Well met, " .. e.other:GetCleanName()
		.. ". I map what others only walk through. Tell me where you have been "
		.. "and I will tell you what it was worth.")

	-- The compass, on the first hail. Guarded by CountItem rather than a flag:
	-- SummonItem does not check lore, so without this a second hail would hand
	-- over a duplicate of a LORE item and the client would refuse it awkwardly.
	-- Counting also means a compass lost to a rollback simply comes back.
	if e.other:CountItem(COMPASS) == 0 then
		e.other:SummonItem(COMPASS)
		tell(e, "Take this compass. It knows the roads you have earned, and it "
			.. "will learn more as you earn them.")
	end

	for _, band in ipairs(flags.band_numbers()) do
		report_band(e, account_id, character_id, band)
	end

	for key, _ in pairs(pools.raids) do
		report_raid(e, account_id, key)
	end

	tell(e, "Sergeant Brask beside me trades in charms, for those who have earned them.")
end
