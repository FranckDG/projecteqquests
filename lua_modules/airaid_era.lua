-- AI Raid: pull the era forward when the controller unlocks a tier.
--
-- The zone gate reads WorldContentService::GetCurrentExpansion(), a cache that a
-- plain rules reload does NOT refresh - LoadRules updates the rule manager only.
-- The one call that refreshes both is SetExpansionContext()->ReloadContentFlags(),
-- which is Zone::ReloadStaticData, exposed here as eq.reloadzonestaticdata().
--
-- This lives in a module rather than in each global script because require()
-- caches modules per Lua state: every caller in a zone shares ONE generation
-- cache. When global_npc.lua and global_player.lua each kept their own local
-- copy, they took separate "first sync" passes - so entering a zone synced the
-- player hook while the NPC hook was still empty, and the first mob death in
-- that zone was always silent. That is why an unlock applied correctly but
-- announced nothing.
local M = {}

local era_generation = ""

function M.refresh()
	local generation = eq.get_data("airaid:era_generation")

	if generation == "" or generation == era_generation then
		return
	end

	-- The first generation a zone sees is a sync, not news; otherwise a server
	-- restart would announce an unlock that happened days ago.
	local first_sync = (era_generation == "")

	era_generation = generation
	eq.reloadzonestaticdata()

	if not first_sync then
		local label = eq.get_data("airaid:era_label")

		if label ~= "" then
			-- zone_emote, not world_emote: each zone tells its own players once as
			-- it catches up. world_emote from every zone would spam, and a "first
			-- zone announces" guard would race with nothing to arbitrate it.
			eq.zone_emote(MT.Yellow, "The world shifts. " .. label .. " is now open.")
		end
	end
end

return M
