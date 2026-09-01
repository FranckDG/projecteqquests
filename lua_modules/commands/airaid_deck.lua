-- #adeck - pair a browser with this account, without a password.
--
--   #adeck            issue a pairing code
--   #adeck cancel     revoke the pending one
--
-- WHY THIS EXISTS. The deck signs people in by checking a password against
-- `login_accounts`, which is the SELF-HOSTED loginserver's table. That works
-- exactly as long as this server owns the accounts. The moment world also
-- registers with login.eqemulator.net, players authenticate there instead, the
-- login server never sends us their password, and there is nothing local left to
-- verify - see eq-ai-raid-server/docs/public-loginserver.md.
--
-- Pairing sidesteps the whole question. Somebody standing in the world has
-- ALREADY proved they control the account; whichever login server did that, it
-- did it properly. So the deck does not need to re-check a password, it needs the
-- game to vouch once. This command is that vouching.
--
-- It is also strictly better than a password even where a password still works:
-- it proves control right now rather than proving knowledge of a secret, it
-- expires, it is single use, and nothing worth stealing is ever typed into a
-- browser.
--
-- Access 0. This grants access to your own account and nobody else's, which is
-- the same thing logging in already does.

local BUCKET = "airaid:decklink:"
local TTL = "5m"

-- No 0/O/1/I/L: these get read off a chat window and typed into a browser, and
-- an ambiguous glyph there is a support question rather than a security problem.
local ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
local CODE_LENGTH = 8

--[[
	Generating the code.

	zone->random is mt19937 seeded from std::random_device (common/random.h), so
	this is not a cryptographic generator and should not be described as one. What
	makes that acceptable is the shape of the thing being guessed, not the
	generator: the code is bound to ONE character, lives five minutes, is consumed
	on first use, and the deck rate limits attempts against it. An attacker must
	therefore guess ~40 bits, for a named character, inside that window, through a
	limiter - rather than sweep a space of live codes.

	If that ever stops being enough, the fix is to move generation to the deck and
	have this command confirm rather than issue. It is not needed today and the
	extra round trip would make the command worse.
]]
local function generate_code()
	local out = {}

	for i = 1, CODE_LENGTH do
		local n = Random.Int(1, #ALPHABET)
		out[i] = ALPHABET:sub(n, n)
	end

	return table.concat(out)
end

-- Grouped for reading, ungrouped on the wire. The deck strips separators before
-- comparing, so it does not matter whether the dash gets typed.
local function pretty(code)
	return code:sub(1, 4) .. "-" .. code:sub(5)
end

local function airaid_deck(e)
	-- e.args is a TABLE of words, not the raw argument string.
	local args = e.args or {}
	local verb = args[1] and args[1]:lower() or nil

	local account_id = e.self:AccountID()
	local key = BUCKET .. account_id

	if verb == "cancel" then
		eq.delete_data(key)
		e.self:Message(MT.Yellow, "Any pending deck pairing code has been cancelled.")
		return
	end

	if verb ~= nil then
		e.self:Message(MT.Yellow, "#adeck - pair a browser with this account")
		e.self:Message(MT.Yellow, "  #adeck          issue a pairing code")
		e.self:Message(MT.Yellow, "  #adeck cancel   revoke the pending one")
		return
	end

	local code = generate_code()

	-- Keyed by ACCOUNT, with the code as the value - not the other way round.
	-- Keying by the code would make every live code a valid key on its own, so a
	-- guess would only have to hit *some* pending pairing. This way a guess has
	-- to hit the code for a particular character, which is what the deck asks
	-- for. Issuing again simply replaces the pending code, which is what a player
	-- who lost the first one expects.
	eq.set_data(key, code, TTL)

	e.self:Message(MT.Yellow, "Deck pairing code: " .. pretty(code))
	e.self:Message(
		MT.Yellow,
		"Sign in at the deck with character name " .. e.self:GetCleanName() .. " and this code."
	)
	e.self:Message(MT.Yellow, "It lasts 5 minutes and works once. #adeck cancel revokes it.")
end

return airaid_deck;
