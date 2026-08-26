function event_spawn(e)
    -- peq_halloween
    if (eq.is_content_flag_enabled("peq_halloween")) then
        -- exclude mounts and pets
        if (e.self:GetCleanName():findi("mount") or e.self:IsPet()) then
            return;
        end

        -- soulbinders
        -- priest of discord
        if (e.self:GetCleanName():findi("soulbinder") or e.self:GetCleanName():findi("priest of discord")) then
            e.self:ChangeRace(eq.ChooseRandom(14,60,82,85));
            e.self:ChangeSize(6);
            e.self:ChangeTexture(1);
            e.self:ChangeGender(2);
        end

        -- Shadow Haven
        -- The Bazaar
        -- The Plane of Knowledge
        -- Guild Lobby
        local halloween_zones = eq.Set { 202, 150, 151, 344 }
        local not_allowed_bodytypes = eq.Set { 11, 60, 66, 67 }
        if (halloween_zones[eq.get_zone_id()] and not_allowed_bodytypes[e.self:GetBodyType()] == nil) then
            e.self:ChangeRace(eq.ChooseRandom(14,60,82,85));
            e.self:ChangeSize(6);
            e.self:ChangeTexture(1);
            e.self:ChangeGender(2);
        end
    end
end

-- ---------------------------------------------------------------------------
-- AI Raid: era ladder gate bosses.
--
-- Killing one of these leaves a breadcrumb in data_buckets. It deliberately
-- does nothing else, because a quest script cannot do the unlock itself:
-- eq.set_rule() resolves to RuleManager::SetRule(name, value) with the default
-- db=nullptr, db_save=false, so it is in-memory and zone-local - killing
-- Trakanon in Sebilis would open Velious for that one zone process and forget
-- it on restart. There is also no SQL binding in the quest API.
--
-- The controller (assets/era/airaid-era.sh, run every minute by cron in the
-- eqemu-server container) reads these breadcrumbs, decides whether a tier is
-- complete, and writes the unlock to rule_values, which IS persistent and
-- server-wide.
--
-- This lives in global_npc.lua rather than in seven per-boss scripts because
-- QuestParserCollection::EventNPC calls EventNPCLocal, EventNPCGlobal and
-- DispatchEventNPC unconditionally - the global fires for every NPC death,
-- whether or not that NPC has a script of its own. One file, and no PEQ file
-- is modified, so upstream merges stay clean.
--
-- Ids mirror the airaid_era_triggers table in the server repo. Retuning the
-- ladder means updating both.
-- ---------------------------------------------------------------------------
local airaid_gate_bosses = eq.Set {
    32040,   -- Lord Nagafen         tier 1  (with Lady Vox)
    73057,   -- Lady Vox             tier 1  (with Lord Nagafen)
    89154,   -- Trakanon             tier 2
    124155,  -- Vulak`Aerr           tier 3
    162227,  -- Emperor Ssraeshza    tier 4
    223201,  -- Quarm                tier 5
    317109,  -- Overlord Mata Muram  tier 6
}

-- Zone-local cache of the era "generation" the controller stamps on each unlock.
-- Each zone process has its own Lua state, so this persists for that zone.
local airaid_era_generation = ""

-- Pull the era forward without anyone typing a command.
--
-- The zone gate in zoning.cpp reads WorldContentService::GetCurrentExpansion(),
-- a cache that a plain rules reload does NOT refresh - LoadRules updates the
-- rule manager only. The one call that refreshes both is
-- SetExpansionContext()->ReloadContentFlags(), which is what Zone::ReloadStaticData
-- does, and that is exposed here as eq.reloadzonestaticdata().
--
-- So each zone refreshes itself the first time an NPC dies in it after an
-- unlock. Nothing else in the engine gives an external process a way to push a
-- global reload: the world console has no rules reload, there is no world CLI
-- for it, and the API route lives behind Spire auth.
local function airaid_refresh_era()
	local generation = eq.get_data("airaid:era_generation")

	if generation == "" or generation == airaid_era_generation then
		return
	end

	-- The first generation a zone sees is just a sync, not news. Without this a
	-- server restart would announce an unlock that happened days ago.
	local first_sync = (airaid_era_generation == "")

	airaid_era_generation = generation
	eq.reloadzonestaticdata()

	if not first_sync then
		local label = eq.get_data("airaid:era_label")

		if label ~= "" then
			-- zone_emote, not world_emote: each zone announces to its own players
			-- exactly once as it catches up. world_emote from every zone would
			-- spam, and a "first zone announces" guard would race across zones.
			-- This also means the message lands precisely when the unlock becomes
			-- true for that player.
			eq.zone_emote(MT.Yellow, "The world shifts. " .. label .. " is now open.")
		end
	end
end

function event_death_complete(e)
    airaid_refresh_era()

    local npc_type_id = e.self:GetNPCTypeID()

    if (airaid_gate_bosses[npc_type_id] == nil) then
        return
    end

    -- e.other is NOT the killer here - on a real kill it arrived as the dying
    -- NPC itself. The handler passes a separate e.killer_id entity id, which is
    -- the reliable one.
    local killer = "unknown"
    local killer_mob = eq.get_entity_list():GetMobID(e.killer_id)
    if (killer_mob.valid) then
        killer = killer_mob:GetCleanName()
    end

    eq.set_data("airaid:kill:" .. npc_type_id, killer)
    eq.debug("[airaid] gate boss " .. npc_type_id .. " killed by " .. killer)
end
