-- #aspawn <npc_type_id> - spawn an NPC on top of you, for testing the era ladder.
--
-- #dbspawn2 takes a spawngroup id, not an npc type, and four of the gate bosses
-- are quest-spawned with no ordinary spawn entry to point at. eq.spawn2() takes
-- the npc_type_id directly, which is what the ladder matches on, so an NPC
-- spawned this way records exactly like one killed in its own zone.
--
-- Pair it with #akill to walk the whole ladder without running the raids.

local gate_bosses = {
	{ 32040,  "Lord Nagafen"        },
	{ 73057,  "Lady Vox"            },
	{ 89154,  "Trakanon"            },
	{ 108048, "Phara Dar"           },
	{ 124155, "Vulak`Aerr"          },
	{ 124103, "Lord Koi`Doken"      },
	{ 162227, "Emperor Ssraeshza"   },
	{ 158007, "Aten Ha Ra"          },
	{ 223201, "Quarm"               },
	{ 317109, "Overlord Mata Muram" },
}

local function airaid_spawn(e)
	local npc_type_id = tonumber(e.args[1])

	if npc_type_id == nil then
		e.self:Message(MT.Red, "#aspawn [npc_type_id] - spawns that NPC on top of you.")
		e.self:Message(MT.Yellow, "Era gate bosses:")

		for _, b in ipairs(gate_bosses) do
			e.self:Message(MT.Yellow, "  " .. b[1] .. "  " .. b[2])
		end

		return
	end

	local spawned = eq.spawn2(
		npc_type_id, 0, 0,
		e.self:GetX(), e.self:GetY(), e.self:GetZ(), e.self:GetHeading()
	)

	if spawned.valid then
		e.self:Message(MT.Yellow, "Spawned " .. spawned:GetCleanName() .. " (" .. npc_type_id .. ").")
	else
		e.self:Message(MT.Red, "Could not spawn npc_type_id " .. npc_type_id .. ".")
	end
end

return airaid_spawn;
