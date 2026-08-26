-- #akill - kill your target and be credited for it.
--
-- #kill calls Mob::Kill(), which is Death(this, 0, SPELL_UNKNOWN, SkillHandtoHand)
-- - the mob is passed as its OWN killer. That is why airaid_era_triggers.killed_by
-- read "Lord Nagafen" and "Trakanon". The engine was reporting honestly; #kill
-- genuinely has no killer to report.
--
-- Changing #kill itself means patching zone/gm_commands/kill.cpp and rebuilding
-- the server, which forks this install from upstream and needs rebasing on every
-- EQEmu update - a poor trade for a log field. Lua cannot override it either:
-- EVENT_COMMAND only fires when command_dispatch returns -2, i.e. for commands
-- the engine did not recognise.
--
-- So this is a separate command that does the same job correctly, by dealing
-- lethal damage FROM the client. The death event then carries a real killer and
-- the era ladder records who actually did it.

local function airaid_kill(e)
	local target = e.self:GetTarget()

	if (target.null) then
		e.self:Message(MT.Red, "#akill - kills your target and credits you. Target something first.")
		return
	end

	if (target:IsClient()) then
		e.self:Message(MT.Red, "#akill will not target players.")
		return
	end

	local name = target:GetCleanName()

	-- Overkill by a wide margin so nothing survives on a rounding edge.
	target:Damage(e.self, target:GetHP() + 1000000, 0, 28)

	e.self:Message(MT.Yellow, "Killed " .. name .. " - credited to you.")
end

return airaid_kill;
