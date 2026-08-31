-- The wayfinder. Summoned by the Explorer's Compass, offers the destinations
-- its summoner has unlocked, ports them, and leaves.
--
-- Lives in global/ rather than a zone directory because the compass can be
-- clicked anywhere: a zone-scoped script would only work where it was filed.
--
-- ---------------------------------------------------------------------------
-- WHERE THE COORDINATES COME FROM.
--
-- Every destination in airaid_pools.lua is the game's own EXIT point from one of
-- that band's dungeons - `zone_points.target_*` for the route out. That is solid,
-- reachable ground by construction, and crucially it is NOT the inbound zone
-- line: arriving on `zone_points.x/y/z` would land inside the trigger volume and
-- bounce the player straight into the dungeon.
local flags = require("airaid_flags")
local pools = require("airaid_pools")

local DEFAULT_LIFETIME_MS = 60 * 1000

local function account_of(e)
	return tonumber(e.self:GetEntityVariable("airaid_account"))
end

-- Which destinations this account may use: the hub always, plus one per claimed
-- band. Ordered, because pairs() over a table with numeric keys has no order and
-- a list that reshuffles every click looks broken.
local function unlocked(account_id)
	local list = {}

	if pools.destinations.hub then
		table.insert(list, { key = "hub", spec = pools.destinations.hub })
	end

	for _, band in ipairs(flags.band_numbers()) do
		local spec = pools.destinations[band]

		if spec ~= nil and flags.band_claimed(account_id, band) then
			table.insert(list, { key = tostring(band), spec = spec })
		end
	end

	return list
end

function event_spawn(e)
	local lifetime = tonumber(e.self:GetEntityVariable("airaid_lifetime"))
		or DEFAULT_LIFETIME_MS

	eq.set_timer("fade", lifetime)
end

function event_timer(e)
	if e.timer == "fade" then
		eq.stop_timer("fade")
		e.self:Depop()
	end
end

function event_say(e)
	if not e.other.valid then
		return
	end

	local account_id = account_of(e)

	-- Summoned for one person. Without this, anyone standing nearby could ride
	-- someone else's compass to a destination they have not earned.
	if account_id == nil or e.other:AccountID() ~= account_id then
		e.self:Say("I was not called for you.")
		return
	end

	local destinations = unlocked(account_id)

	if e.message:findi("hail") then
		e.self:Say("Name a place and I will set you on the road to it.")

		for _, entry in ipairs(destinations) do
			e.other:Message(MT.Yellow, "  "
				.. eq.say_link("go " .. entry.key, true, entry.spec.label))
		end

		if #destinations <= 1 then
			e.other:Message(MT.Yellow,
				"Earn a band from Wyn Farsight and I will know more roads.")
		end

		return
	end

	local choice = e.message:lower():match("^go%s+(%w+)$")

	if choice == nil then
		return
	end

	for _, entry in ipairs(destinations) do
		if entry.key == choice then
			-- Checked again here, not just at summon time: the wayfinder stands
			-- around for a minute and a fight can start in that minute.
			if e.other:IsEngaged() then
				e.self:Say("Not while something is trying to kill you.")
				return
			end

			local d = entry.spec

			e.other:MovePC(d.zone_id, d.x, d.y, d.z, d.h)
			e.self:Depop()

			return
		end
	end

	e.self:Say("That road is not yours yet.")
end
