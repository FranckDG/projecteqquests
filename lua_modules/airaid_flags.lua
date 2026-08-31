-- AI Raid: exploration flags — "I have been here" and "this dungeon's boss died".
--
-- Two hooks, both cheap, both on paths that fire constantly:
--
--   record_visit(client)      event_enter_zone
--   record_kill(npc_type_id)  event_death_complete, for EVERY npc in the zone
--
-- The pools are a generated module (airaid_pools.lua) rather than a table walked
-- at runtime precisely because of that second one. Both hooks are a single hash
-- probe against a reverse index, and everything else happens only on a hit.
--
-- ---------------------------------------------------------------------------
-- BUCKETS MUST BE GLOBAL, AND THE ACCOUNT ID GOES IN THE KEY.
--
-- DataBucket::CanCache returns true for any bucket scoped to a character,
-- account, bot or zone, so a scoped bucket is served from a zone-local cache and
-- a write made anywhere else is invisible until the zone reloads. eq.set_data's
-- Lua binding is global-scope only, which is the behaviour we want anyway: the
-- flags are account-scoped by CONVENTION, with the account id in the key name,
-- so alts share progress exactly as §4 of the design requires.
--
-- Keys, per the design's §3:
--   airaid:<acct>:visit:<zone>      "1"
--   airaid:<acct>:kill:<zone>       "1"
--   airaid:<acct>:killera:<zone>    the expansion number at the time of the kill
--
-- Nothing here expires. eq.set_data with two arguments sets no expiry; passing a
-- third would quietly give these a lifetime, and a flag that evaporates is worse
-- than one that was never set because the player has already spent the trip.
--
-- ---------------------------------------------------------------------------
-- WRITES ARE GUARDED BY A READ.
--
-- Both hooks check before they write. Entering Crushbone for the hundredth time,
-- or killing a repeatedly-respawning boss, must not generate a bucket write each
-- time. This also makes killera "first kill wins", which is the generous reading:
-- eras only ever move forward, so the earliest kill is the most era-pure one and
-- re-killing later must not downgrade a title already earned.
local pools = require("airaid_pools")

local M = {}

local function visit_key(account_id, zone)
	return "airaid:" .. account_id .. ":visit:" .. zone
end

local function kill_key(account_id, zone)
	return "airaid:" .. account_id .. ":kill:" .. zone
end

local function killera_key(account_id, zone)
	return "airaid:" .. account_id .. ":killera:" .. zone
end

-- The era controller stamps this on every unlock. There is no Lua binding that
-- returns the current expansion as a number - only is_current_expansion_<name>()
-- predicates - so the bucket is the accessor, and it is the same one
-- airaid_era.lua uses to decide whether Classic's bot limit still applies.
local function current_era()
	local era = eq.get_data("airaid:era_expansion")

	if era == "" then
		return 0
	end

	return tonumber(era) or 0
end

-- ---------------------------------------------------------------------------
-- Entering a zone. Called from global_player.lua's event_enter_zone.
-- ---------------------------------------------------------------------------
function M.record_visit(client)
	if not client.valid then
		return false
	end

	local zone = eq.get_zone_short_name()

	if not pools.visit_index[zone] then
		return false
	end

	local key = visit_key(client:AccountID(), zone)

	if eq.get_data(key) ~= "" then
		return false
	end

	eq.set_data(key, "1")

	return true
end

-- ---------------------------------------------------------------------------
-- A boss died. Called from global_npc.lua's event_death_complete.
--
-- Credited to every client in the zone rather than to the killer, because bot
-- kills count by design and e.other is not the killer on this event anyway (it
-- arrives as the dying NPC; under #kill the mob genuinely is its own killer).
-- Whoever is standing here did the dungeon.
--
-- The zone comes from the pool entry, not from get_zone_short_name(), so the
-- flag names the dungeon the boss belongs to even if something spawns him
-- somewhere unexpected.
-- ---------------------------------------------------------------------------
function M.record_kill(npc_type_id)
	local boss = pools.boss_index[npc_type_id]

	if boss == nil then
		return false
	end

	local client_list = eq.get_entity_list():GetClientList()

	if client_list == nil then
		return false
	end

	local era = current_era()
	local credited = 0

	for client in client_list.entries do
		if client.valid then
			local account_id = client:AccountID()
			local key = kill_key(account_id, boss.zone)

			if eq.get_data(key) == "" then
				eq.set_data(key, "1")
				credited = credited + 1
			end

			-- Raid bands pay an era-pure title when the kill happened while the
			-- era was current, so the era has to be recorded at kill time - it
			-- cannot be recovered later.
			if boss.is_raid then
				local era_key = killera_key(account_id, boss.zone)

				if eq.get_data(era_key) == "" then
					eq.set_data(era_key, tostring(era))
				end
			end
		end
	end

	return credited > 0
end

-- ---------------------------------------------------------------------------
-- Reading progress, for the Cartographer.
--
-- Two scopes, and the difference matters. A dungeon being DONE and a band being
-- CLAIMED are account-wide, so alts share the exploring. Being PAID is
-- per-character, so each character earns its own XP and plat for the same
-- dungeon - which is the point of sharing the flags in the first place.
-- ---------------------------------------------------------------------------

function M.has_visit(account_id, zone)
	return eq.get_data(visit_key(account_id, zone)) ~= ""
end

function M.has_kill(account_id, zone)
	return eq.get_data(kill_key(account_id, zone)) ~= ""
end

-- A dungeon counts only when it has been both entered and cleared.
function M.dungeon_done(account_id, zone)
	return M.has_visit(account_id, zone) and M.has_kill(account_id, zone)
end

function M.kill_era(account_id, zone)
	local value = eq.get_data(killera_key(account_id, zone))

	if value == "" then
		return nil
	end

	return tonumber(value)
end

-- How far along a band is, counting only dungeons whose era has actually opened.
--
-- Dungeons from a locked era are not merely hidden from the dialogue, they are
-- left out of the count, because showing "2 of 3" against a pool the player
-- cannot reach yet reads as a bug rather than as a locked door.
function M.band_progress(account_id, band)
	local spec = pools.bands[band]

	if spec == nil then
		return nil
	end

	local era = current_era()
	local progress = {
		band = band,
		required = spec.required,
		reward_level = spec.reward_level,
		done = 0,
		available = 0,
		done_zones = {},
		missing = {},
	}

	for _, dungeon in ipairs(spec.dungeons) do
		if dungeon.era <= era then
			progress.available = progress.available + 1

			if M.dungeon_done(account_id, dungeon.zone) then
				progress.done = progress.done + 1
				table.insert(progress.done_zones, dungeon.zone)
			else
				table.insert(progress.missing, dungeon.zone)
			end
		end
	end

	progress.complete = progress.done >= spec.required

	return progress
end

-- Raid bands want every listed zone visited and any one of the bosses dead.
function M.raid_progress(account_id, key)
	local spec = pools.raids[key]

	if spec == nil then
		return nil
	end

	local progress = { key = key, era = spec.era, visited = 0, missing = {}, killed = false }

	for _, zone in ipairs(spec.visits) do
		if M.has_visit(account_id, zone) then
			progress.visited = progress.visited + 1
		else
			table.insert(progress.missing, zone)
		end

		if M.has_kill(account_id, zone) then
			progress.killed = true

			-- The EARLIEST kill across the band's zones is the purest one, since
			-- eras only move forward. Taking the minimum means a later re-kill in
			-- a further era can never cost a title already earned.
			local era = M.kill_era(account_id, zone)

			if era ~= nil and (progress.killed_era == nil or era < progress.killed_era) then
				progress.killed_era = era
			end
		end
	end

	progress.total = #spec.visits
	progress.complete = (progress.visited >= progress.total) and progress.killed

	-- Era-pure: the boss fell while this era was the current one, not on a
	-- sightseeing trip after the server had moved on.
	progress.era_pure = progress.complete and progress.killed_era == spec.era

	return progress
end

-- ---------------------------------------------------------------------------
-- Claim and payment bookkeeping.
-- ---------------------------------------------------------------------------

local function band_key(account_id, band)
	return "airaid:" .. account_id .. ":band:" .. band
end

local function paid_dungeon_key(account_id, character_id, zone)
	return "airaid:" .. account_id .. ":char:" .. character_id .. ":paid:" .. zone
end

local function paid_band_key(account_id, character_id, band)
	return "airaid:" .. account_id .. ":char:" .. character_id .. ":paid:band:" .. band
end

function M.band_claimed(account_id, band)
	return eq.get_data(band_key(account_id, band)) ~= ""
end

function M.claim_band(account_id, band)
	eq.set_data(band_key(account_id, band), "1")
end

function M.dungeon_paid(account_id, character_id, zone)
	return eq.get_data(paid_dungeon_key(account_id, character_id, zone)) ~= ""
end

function M.mark_dungeon_paid(account_id, character_id, zone)
	eq.set_data(paid_dungeon_key(account_id, character_id, zone), "1")
end

function M.band_paid(account_id, character_id, band)
	return eq.get_data(paid_band_key(account_id, character_id, band)) ~= ""
end

function M.mark_band_paid(account_id, character_id, band)
	eq.set_data(paid_band_key(account_id, character_id, band), "1")
end

-- Bands in ascending order. pairs() over a table with numeric keys gives no
-- order at all, and a Cartographer that lists bands differently every hail looks
-- broken even though it is only unordered.
function M.band_numbers()
	local numbers = {}

	for band, _ in pairs(pools.bands) do
		table.insert(numbers, band)
	end

	table.sort(numbers)

	return numbers
end

M.current_era = current_era

return M
