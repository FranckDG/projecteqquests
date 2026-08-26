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
-- The ladder itself, the breadcrumb, the progress message and the era refresh
-- all live in lua_modules/airaid_era.lua, so this file and global_player.lua
-- share one generation cache. A copy in each meant each took its own silent
-- "first sync", and the first mob death in a zone never announced.
--
-- Quest scripts cannot do the unlock: eq.set_rule() resolves to
-- RuleManager::SetRule(name, value) with db=nullptr, db_save=false, so it is
-- in-memory and zone-local, and there is no SQL binding in the quest API.
-- data_buckets is the only persistence available, so the controller
-- (assets/era/airaid-era.sh, cron) decides and applies.
--
-- Hooked here rather than in seven per-boss scripts because
-- QuestParserCollection::EventNPC calls EventNPCLocal, EventNPCGlobal and
-- DispatchEventNPC unconditionally - the global fires for every NPC death,
-- whether or not that NPC has a script of its own. Three of the seven have no
-- script at all and one is #Vulak-Aerr.pl, so per-boss files would have meant
-- creating some and editing others, each a future merge conflict.
-- ---------------------------------------------------------------------------
local airaid_era = require("airaid_era")

function event_death_complete(e)
	airaid_era.refresh()

	-- e.other is NOT the killer here - it arrives as the dying NPC itself, and
	-- under #kill it genuinely is: Mob::Kill() calls Death(this, ...), passing
	-- the mob as its own killer. e.killer_id is the reliable field. Use #akill
	-- for a GM instakill that credits you properly.
	local killer = "unknown"
	local killer_mob = eq.get_entity_list():GetMobID(e.killer_id)

	if killer_mob.valid then
		killer = killer_mob:GetCleanName()
	end

	airaid_era.record_kill(e.self:GetNPCTypeID(), killer)
end
