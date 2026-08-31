-- #aexplore - inspect and repair exploration flags.
--
-- WHY THIS EXISTS. The visit and kill flags are not retroactive: a dungeon
-- cleared before the hooks shipped counts for nothing, and there is no way to
-- put that right from in-game. The design calls for a repair command in §10 and
-- this is it.
--
-- It is also the only way to exercise Wyn without re-clearing four dungeons,
-- which matters because nothing here has ever been tested in a live zone.
--
--   #aexplore                      what the flags say about you
--   #aexplore show <account>       ...about someone else
--   #aexplore visit <zone>         set the visit flag on yourself
--   #aexplore kill <zone>          set the kill flag on yourself
--   #aexplore clear <zone>         drop both, and any payment record for them
--   #aexplore reset                drop EVERY exploration flag on your account
--
-- Flags are account-scoped, so every form works on the invoker's account unless
-- an account id is given. Payment records are per character and are cleared
-- alongside the flags they paid for, so a repaired dungeon pays again rather
-- than being silently owed.
--
-- Access 100: it hands out rewards by proxy, so it sits with #aspawn rather
-- than with #akill.
local flags = require("airaid_flags")
local pools = require("airaid_pools")

local function usage(e)
	e.self:Message(MT.Yellow, "#aexplore - exploration flags")
	e.self:Message(MT.Yellow, "  #aexplore                  show your own progress")
	e.self:Message(MT.Yellow, "  #aexplore show <account>   show another account's")
	e.self:Message(MT.Yellow, "  #aexplore visit <zone>     set a visit flag")
	e.self:Message(MT.Yellow, "  #aexplore kill <zone>      set a kill flag")
	e.self:Message(MT.Yellow, "  #aexplore clear <zone>     drop both, and its payment record")
	e.self:Message(MT.Yellow, "  #aexplore reset            drop every flag on your account")
end

local function show(e, account_id)
	e.self:Message(MT.Yellow, "Exploration flags for account " .. account_id
		.. " (era " .. flags.current_era() .. "):")

	for _, band in ipairs(flags.band_numbers()) do
		local p = flags.band_progress(account_id, band)

		if p ~= nil then
			local state = p.done .. "/" .. p.required

			if flags.band_claimed(account_id, band) then
				state = state .. " CLAIMED"
			elseif p.complete then
				state = state .. " ready to claim"
			end

			local line = "  band " .. band .. "  " .. state
				.. "  (pool " .. p.available .. " of " .. #pools.bands[band].dungeons .. " open)"

			e.self:Message(MT.Yellow, line)

			if #p.missing > 0 then
				e.self:Message(MT.Yellow, "      missing: " .. table.concat(p.missing, ", "))
			end
		end
	end

	-- Raid bands, oldest era first. pairs() has no order, so without this the
	-- list reshuffles on every invocation and reads like noise.
	local raid_keys = {}

	for key, _ in pairs(pools.raids) do
		table.insert(raid_keys, key)
	end

	table.sort(raid_keys, function(a, b)
		return pools.raids[a].era < pools.raids[b].era
	end)

	local era = flags.current_era()
	local sealed = 0

	for _, key in ipairs(raid_keys) do
		local p = flags.raid_progress(account_id, key)

		-- A raid band whose expansion has not opened cannot be started, let
		-- alone finished. Counting them rather than listing them keeps this
		-- readable: at Classic there are ten, and nine of them are noise.
		if p ~= nil and p.era > era then
			sealed = sealed + 1
		elseif p ~= nil then
			e.self:Message(MT.Yellow, "  " .. key .. "  bosses " .. p.kills .. "/"
				.. p.required_kills .. ", era-pure " .. tostring(p.era_pure))
		end
	end

	if sealed > 0 then
		e.self:Message(MT.Yellow, "  " .. sealed
			.. " further raid band(s) await an age that has not opened.")
	end
end

-- Only zones the pools actually use. Setting a flag for a zone no band contains
-- would write a bucket nothing ever reads, which looks like it worked.
local function known_zone(zone)
	return pools.visit_index[zone] == true
end

local function airaid_explore(e)
	-- e.args is a TABLE of words, not the raw argument string.
	local args = e.args or {}

	local account_id = e.self:AccountID()
	local character_id = e.self:CharacterID()
	local verb = args[1] and args[1]:lower() or nil

	if verb == nil then
		show(e, account_id)
		return
	end

	if verb == "show" then
		show(e, tonumber(args[2]) or account_id)
		return
	end

	if verb == "reset" then
		local dropped = 0

		for zone, _ in pairs(pools.visit_index) do
			for _, key in ipairs({
				"airaid:" .. account_id .. ":visit:" .. zone,
				"airaid:" .. account_id .. ":kill:" .. zone,
				"airaid:" .. account_id .. ":char:" .. character_id .. ":paid:" .. zone,
			}) do
				if eq.get_data(key) ~= "" then
					eq.delete_data(key)
					dropped = dropped + 1
				end
			end
		end

		-- Raid flags are keyed by boss id, so they are not reachable by walking
		-- zones. Walk the boss index instead.
		for npc_type_id, boss in pairs(pools.boss_index) do
			if boss.is_raid then
				for _, key in ipairs({
					"airaid:" .. account_id .. ":raidkill:" .. npc_type_id,
					"airaid:" .. account_id .. ":raidera:" .. npc_type_id,
				}) do
					if eq.get_data(key) ~= "" then
						eq.delete_data(key)
						dropped = dropped + 1
					end
				end
			end
		end

		for _, band in ipairs(flags.band_numbers()) do
			for _, key in ipairs({
				"airaid:" .. account_id .. ":band:" .. band,
				"airaid:" .. account_id .. ":char:" .. character_id .. ":paid:band:" .. band,
			}) do
				if eq.get_data(key) ~= "" then
					eq.delete_data(key)
					dropped = dropped + 1
				end
			end
		end

		e.self:Message(MT.Yellow, "Dropped " .. dropped
			.. " flags for account " .. account_id .. ".")
		return
	end

	local zone = args[2] and args[2]:lower() or nil

	if zone == nil or not known_zone(zone) then
		if zone ~= nil then
			e.self:Message(MT.Red, "\"" .. zone .. "\" is not in any band or raid pool.")
		end
		usage(e)
		return
	end

	if verb == "visit" then
		eq.set_data("airaid:" .. account_id .. ":visit:" .. zone, "1")
		e.self:Message(MT.Yellow, "Visited " .. zone .. ".")
	elseif verb == "kill" then
		eq.set_data("airaid:" .. account_id .. ":kill:" .. zone, "1")

		-- Raid kills are per BOSS, not per zone, so flag every raid boss this
		-- zone holds. Setting only the zone flag would leave a raid band looking
		-- untouched however many times the command was run.
		local raid_bosses = 0

		for npc_type_id, boss in pairs(pools.boss_index) do
			if boss.zone == zone and boss.is_raid then
				eq.set_data("airaid:" .. account_id .. ":raidkill:" .. npc_type_id, "1")
				eq.set_data("airaid:" .. account_id .. ":raidera:" .. npc_type_id,
					tostring(flags.current_era()))
				raid_bosses = raid_bosses + 1
			end
		end

		local text = "Killed " .. zone .. "'s boss (era " .. flags.current_era() .. ")."

		if raid_bosses > 0 then
			text = text .. " " .. raid_bosses .. " raid boss(es) here also flagged."
		end

		e.self:Message(MT.Yellow, text)
	elseif verb == "clear" then
		for npc_type_id, boss in pairs(pools.boss_index) do
			if boss.zone == zone and boss.is_raid then
				eq.delete_data("airaid:" .. account_id .. ":raidkill:" .. npc_type_id)
				eq.delete_data("airaid:" .. account_id .. ":raidera:" .. npc_type_id)
			end
		end

		-- The payment record goes too. Leaving it would mean re-earning the
		-- dungeon and never being paid for it, which is worse than not clearing.
		for _, key in ipairs({
			"airaid:" .. account_id .. ":visit:" .. zone,
			"airaid:" .. account_id .. ":kill:" .. zone,
			"airaid:" .. account_id .. ":killera:" .. zone,
			"airaid:" .. account_id .. ":char:" .. character_id .. ":paid:" .. zone,
		}) do
			eq.delete_data(key)
		end

		e.self:Message(MT.Yellow, "Cleared " .. zone .. ".")
	else
		usage(e)
	end
end

return airaid_explore;
