-- #abridge - spike test for the server-side command bridge.
--
-- THIS IS A TEST. It exists to answer one question before P2 is built on the
-- answer: can the deck make a bot command execute as the player, from outside
-- the game, without MacroQuest?
--
-- The mechanism, all of it already in EQEmu:
--
--   command.cpp:109  command_add("bot", ..., AccountStatus::Player, command_bot)
--   command.cpp:780  bot_command_dispatch(c, bot_message)      -- "#bot X" -> "^X"
--   lua_client.cpp   client:SendGMCommand(message)             -- run a command AS a client
--
-- `#bot` is registered at Player access, not GM, so this needs no elevated
-- account and grants none. The command still goes through the real bot command
-- parser, which means every ownership, class/race/slot/level/lore and
-- spawn-state check applies exactly as if the player had typed it. That is the
-- same property the MQ bridge was chosen for in the design doc - writes inherit
-- the server's own validation - reached without a plugin, Wine or a C++
-- toolchain.
--
-- Two things are being tested, and they are independent:
--
--   #abridge <bot command>   direct dispatch. Proves SendGMCommand reaches the
--                            bot parser at all. If this fails, nothing else
--                            matters.
--
--   #abridge queue           reports the queue bucket, which the deck backend
--                            writes from outside the game. The drain loop lives
--                            in global_player.lua on a 1s timer. This is the
--                            half that proves the deck can command bots with the
--                            player touching nothing.
--
-- Remove both this file and the global_player.lua timer once the answer is
-- recorded - see docs/ in eq-ai-raid-deck.

local BUCKET_CMD = "airaid:cmd:"
local BUCKET_ACK = "airaid:ack:"

local function airaid_bridge(e)
	local args = {}
	for i = 1, 20 do
		if e.args[i] == nil then break end
		args[#args + 1] = e.args[i]
	end

	if #args == 0 then
		e.self:Message(MT.Yellow, "#abridge <bot command>  - dispatch a ^ command as yourself, server-side.")
		e.self:Message(MT.Yellow, "#abridge queue          - show the pending queue bucket and last ack.")
		e.self:Message(MT.White, "e.g.  #abridge botlist        (runs ^botlist)")
		e.self:Message(MT.White, "      #abridge follow byname Kleric")
		return
	end

	local char_id = e.self:CharacterID()

	if args[1] == "queue" then
		-- Deliberately reads the same buckets the drain loop does, so this
		-- reports what the loop will actually see rather than a parallel guess.
		local pending = eq.get_data(BUCKET_CMD .. char_id)
		local ack = eq.get_data(BUCKET_ACK .. char_id)
		e.self:Message(MT.Yellow, "character id: " .. char_id)
		e.self:Message(MT.White, "  pending: " .. (pending ~= "" and pending or "(empty)"))
		e.self:Message(MT.White, "  last ack: " .. (ack ~= "" and ack or "(none)"))
		return
	end

	local command = table.concat(args, " ")

	-- SendGMCommand returns command_dispatch(...) >= 0. That is "the command was
	-- recognised and run", NOT "the bot did what you wanted" - a ^follow naming a
	-- bot you do not own still returns true and tells you off in chat. Coarse
	-- success is enough for the deck, which re-reads authoritative state from the
	-- database after any mutation (§4 treats done.ok as advisory anyway).
	local ok = e.self:SendGMCommand("#bot " .. command)

	e.self:Message(
		ok and MT.Green or MT.Red,
		string.format("[abridge] dispatched ^%s -> %s", command, ok and "accepted" or "REJECTED")
	)
end

return airaid_bridge;
