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

return M
