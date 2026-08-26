-- AI Raid: era ladder, zone side.
--
-- Two jobs:
--
--   record_kill()  a gate boss died. Leave a breadcrumb for the controller and
--                  tell the zone how far along the tier now is.
--   refresh()      the controller unlocked something. Pull this zone's era
--                  forward and announce it.
--
-- Neither does the unlock. eq.set_rule() resolves to RuleManager::SetRule with
-- db=nullptr, db_save=false - in-memory and zone-local - and the quest API has
-- no SQL binding. data_buckets is the only persistence available here, so the
-- controller (assets/era/airaid-era.sh, cron) does the deciding.
--
-- This is a module rather than code in each global script because require()
-- caches per Lua state: every hook in a zone shares ONE generation cache. When
-- the two globals each kept a local copy they took separate "first sync"
-- passes, and the first mob death after entering a zone never announced.
--
-- The ladder, mirroring airaid_era_tiers / airaid_era_triggers in the server
-- repo. Labels must match airaid_era_tiers.label exactly: the kill-progress
-- line is named from here, the unlock line from the database, and if they
-- drift the same unlock gets announced under two different names.
--
-- Tiers 4 and 5 bundle a small expansion each, and the labels say so: killing
-- Emperor Ssraeshza opens Ykesha alongside Planes of Power, and Quarm opens
-- Gates of Discord alongside Lost Dungeons of Norrath.
local tiers = {
	{
		label  = "The Ruins of Kunark",
		bosses = { [32040] = "Lord Nagafen", [73057] = "Lady Vox" },
	},
	{
		label  = "The Scars of Velious",
		bosses = { [89154] = "Trakanon" },
	},
	{
		label  = "The Shadows of Luclin",
		bosses = { [124155] = "Vulak`Aerr" },
	},
	{
		label  = "The Planes of Power and the Legacy of Ykesha",
		bosses = { [162227] = "Emperor Ssraeshza" },
	},
	{
		label  = "Lost Dungeons of Norrath and the Gates of Discord",
		bosses = { [223201] = "Quarm" },
	},
	{
		label  = "Omens of War",
		bosses = { [317109] = "Overlord Mata Muram" },
	},
}

local era_generation = ""

-- Which tier does this npc gate, if any?
local function tier_for(npc_type_id)
	for _, tier in ipairs(tiers) do
		if tier.bosses[npc_type_id] ~= nil then
			return tier
		end
	end
	return nil
end

function M.record_kill(npc_type_id, killer)
	local tier = tier_for(npc_type_id)

	if tier == nil then
		return false
	end

	eq.set_data("airaid:kill:" .. npc_type_id, killer)

	-- Count the tier's progress from the breadcrumbs, including the one just
	-- written. The controller is the authority on unlocking; this is only to
	-- tell the people standing here where they are.
	local total, done, fallen = 0, 0, tier.bosses[npc_type_id]

	for id, _ in pairs(tier.bosses) do
		total = total + 1
		if eq.get_data("airaid:kill:" .. id) ~= "" then
			done = done + 1
		end
	end

	-- Lead with the era, then the kill. Putting the label first avoids both
	-- "The way to The Ruins of Kunark" and the verb disagreement the bundled
	-- tiers cause ("...and the Gates of Discord IS now open"). The count only
	-- appears when a tier actually needs more than one kill.
	--
	-- Plain ASCII: this renders in a 2013 client.
	local progress = tier.label .. " - " .. fallen .. " has fallen."

	if total > 1 then
		progress = progress .. " " .. done .. " of " .. total .. "."
	end

	if done >= total then
		progress = progress .. " The way opens shortly."
	end

	eq.zone_emote(MT.Yellow, progress)

	return true
end

function M.refresh()
	local generation = eq.get_data("airaid:era_generation")

	if generation == "" or generation == era_generation then
		return
	end

	-- The first generation a zone sees is a sync, not news; otherwise a server
	-- restart would announce an unlock that happened days ago.
	local first_sync = (era_generation == "")

	era_generation = generation

	-- The zone gate reads WorldContentService::GetCurrentExpansion(), a cache a
	-- plain rules reload does NOT refresh. Zone::ReloadStaticData is the one call
	-- that refreshes both, and this is it.
	eq.reloadzonestaticdata()

	if not first_sync then
		local label = eq.get_data("airaid:era_label")

		if label ~= "" then
			-- zone_emote, not world_emote: each zone tells its own players once as
			-- it catches up, so no spam and no cross-zone race.
			eq.zone_emote(MT.Yellow, "The world shifts. Now open: " .. label .. ".")
		end
	end
end

return M
