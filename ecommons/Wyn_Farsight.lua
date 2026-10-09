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

--[[
	An expansion line's title. The line NAMES its set; this does not compute one.

	Band titles are 900 + band, and that arithmetic is why band 50 points at 950 -
	which is the Classic raid band's "the Godslayer", not a band title at all.
	Nobody has hit it because band 50 needs Kunark, but it is the failure mode of
	deriving an id that has to exist as a row: the formula cannot tell you the row
	is missing or belongs to someone else.

	So the lines carry theirs in pools.spec.mjs, migration 0042 inserts exactly
	those ids, and a line with no row would grant a set nothing uses - visibly
	nothing, rather than someone else's title.
]]
local function grant_line_title(title_set)
	if title_set == nil then
		return
	end

	eq.enable_title(title_set)
end

-- The band says which title it grants; this no longer computes it.
--
-- It used to be eq.enable_title(950 + era), which was fine while eras and raid
-- bands were one to one. Classic has two tiers now and that arithmetic hands both
-- the same title, so the second would have awarded nothing and looked broken for
-- no visible reason. pools.spec.mjs names the set, gen-pools.mjs writes it into
-- airaid_pools.lua, and the arithmetic survives there as the default.
--
-- A set with no row in `titles` is a deliberate no-op, not a bug - see migration
-- 0018. Nine of the eleven bands are in that state today.
local function grant_raid_title(title_set)
	if title_set == nil then
		return
	end

	eq.enable_title(title_set)
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
	-- The fifth argument is not optional in practice. AddMoneyToPP's
	-- update_client defaults to FALSE (client.h:902), and SendMoneyUpdate is
	-- the only thing that refreshes the coin display. SaveCurrency runs either
	-- way, so without it the plat lands in the database and the player never
	-- sees it arrive - which is exactly how this was reported: "I got the charm
	-- but I never got the 400pp".
	e.other:AddMoneyToPP(0, 0, 0, reward_level * 2, true)

	tell(e, "  " .. zone .. " - " .. (reward_level * 2) .. "pp and experience.")

	return true
end

local function pay_band(e, account_id, character_id, progress)
	if flags.band_paid(account_id, character_id, progress.band) then
		return false
	end

	flags.mark_band_paid(account_id, character_id, progress.band)

	e.other:AddLevelBasedExp(100, progress.reward_level)
	e.other:AddMoneyToPP(0, 0, 0, progress.reward_level * 20, true)
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

--[[
	Paying for a finished expansion line.

	Deliberately the same shape and the same amounts as pay_band - a level of
	experience at the line's reward level, 20pp per level of it, a title and the
	archetype's charm - because a line IS the band at that point in the ladder,
	not a different kind of reward.

	The charm comes from charms.line_charms rather than charms.charms. Those are
	separate tables on purpose: a line key and a band number could not collide,
	but one lookup that takes either would quietly return nil for a typo instead
	of failing, and the whole reason the archetype is derived from the class
	bitmask is to make "wrong charm" impossible rather than unlikely.
]]
local function pay_line(e, account_id, character_id, progress)
	if flags.line_paid(account_id, character_id, progress.line) then
		return false
	end

	flags.mark_line_paid(account_id, character_id, progress.line)

	e.other:AddLevelBasedExp(100, progress.reward_level)
	e.other:AddMoneyToPP(0, 0, 0, progress.reward_level * 20, true)
	grant_line_title(progress.title_set)

	local archetype = charms.archetype_for_class[e.other:GetClass()]
	local item_id = archetype and charms.line_charms and charms.line_charms[archetype]
		and charms.line_charms[archetype][progress.line]

	if item_id then
		e.other:SummonItem(item_id)
		tell(e, progress.label .. " complete. "
			.. (progress.reward_level * 20) .. "pp, a level of experience, and a "
			.. charms.archetype_name[archetype] .. " charm.")
	else
		-- Should be unreachable: every class maps to an archetype and every line
		-- has a charm. Say so rather than paying silently and losing the charm.
		tell(e, progress.label .. " complete, but I have no charm for your calling. "
			.. "Tell Brask - that is not supposed to happen.")
	end

	return true
end

local function report_line(e, account_id, character_id, key)
	local progress = flags.line_progress(account_id, key)

	-- available == 0 means the expansion has not opened. Saying nothing is right:
	-- a line is all-or-nothing on era, so there is no partial progress to report
	-- and listing seven ages a player cannot reach yet would bury the one he can.
	if progress == nil or progress.available == 0 then
		return
	end

	for _, zone in ipairs(progress.done_zones) do
		pay_dungeon(e, account_id, character_id, zone, progress.reward_level)
	end

	local claimed = flags.line_claimed(account_id, progress.line)
	local line = progress.label .. ": " .. progress.done .. " of " .. progress.required

	if claimed then
		tell(e, line .. " - claimed.")
	elseif progress.complete then
		flags.claim_line(account_id, progress.line)
		pay_line(e, account_id, character_id, progress)
	else
		local targets = {}
		for _, zone in ipairs(progress.missing) do
			local boss = progress.missing_bosses and progress.missing_bosses[zone]
			table.insert(targets, boss and (zone .. " (" .. boss .. ")") or zone)
		end

		tell(e, line .. ". Still to clear: " .. join(targets))
	end

	-- A line already claimed on the account still owes THIS character its payout
	-- the first time it hails - the same per-character rule as the bands.
	if claimed then
		pay_line(e, account_id, character_id, progress)
	end
end

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
		-- Name the quarry, not just the place. A zone short name alone tells a
		-- player where to go and nothing about what finishes it, and the pool
		-- is keyed on the BOSS kill -- walking the dungeon does not count.
		local targets = {}
		for _, zone in ipairs(progress.missing) do
			local boss = progress.missing_bosses and progress.missing_bosses[zone]
			table.insert(targets, boss and (zone .. " (" .. boss .. ")") or zone)
		end

		local text = line .. ". Still to clear: " .. join(targets)

		-- A band whose era has not opened yet cannot be finished however much of
		-- it you clear - band 50 during Classic shows a pool of one against a
		-- requirement of four. Say so, or the count reads as a bug rather than a
		-- locked door.
		if progress.available < progress.required then
			text = text .. " - and the rest of this band lies in an age not yet opened."
		end

		tell(e, text)
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
			grant_raid_title(progress.title_set)
			tell(e, "The great powers of this age have fallen to you, and you were "
				.. "there when it mattered. That is worth a name.")
		else
			tell(e, "The great powers of this age have fallen to you - though the "
				.. "world had already moved on by the time you got there.")
		end
	elseif progress.killed then
		tell(e, "You have struck down " .. progress.kills .. " of the "
			.. progress.required_kills .. " great powers of this age.")
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

	-- The lines come after the bands because they continue the same ladder above
	-- level 50, and in era order so they read as a progression.
	for _, key in ipairs(flags.line_keys()) do
		report_line(e, account_id, character_id, key)
	end

	for key, _ in pairs(pools.raids) do
		report_raid(e, account_id, key)
	end

	tell(e, "Sergeant Brask beside me trades in charms, for those who have earned them.")
end
