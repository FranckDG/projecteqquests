-- The Explorer's Compass. Summons a wayfinder who ports you to any destination
-- you have unlocked.
--
-- Resolved by ITEM ID rather than a scriptfileid: with items.scriptfileid = 0 and
-- no charmfile, quest_parser_collection.cpp falls through to the item id, so this
-- file must be named 900500.lua and live in global/items.
--
-- ---------------------------------------------------------------------------
-- RETURNING 1 IS LOAD-BEARING.
--
-- The client only offers a right-click on an item that has a click effect, so
-- the compass carries one (8691, "Shimmering Parchment" - inert: SE_Blank,
-- self-targeted, no duration). It is never cast: client_packet.cpp casts the
-- spell only `if (i == 0)`, where i is what this script returns, and interrupts
-- it otherwise. So the spell is there to make the item clickable and this return
-- is there to stop it going off.
--
-- event_item_click_cast, not event_item_click: the former is what OP_CastSpell
-- raises and the only one whose return value suppresses the cast.
local WAYFINDER = 2000202
local LIFETIME_MS = 60 * 1000

function event_item_click_cast(e)
	if not e.self.valid then
		return 1
	end

	-- Porting out of a fight is not what this is for, and the design says so.
	if e.self:IsEngaged() then
		e.self:Message(MT.Red, "Not while something is trying to kill you.")
		return 1
	end

	local wayfinder = eq.spawn2(
		WAYFINDER, 0, 0,
		e.self:GetX(), e.self:GetY(), e.self:GetZ(), e.self:GetHeading()
	)

	if wayfinder == nil or not wayfinder.valid then
		e.self:Message(MT.Red, "The needle spins and settles. Nothing comes.")
		return 1
	end

	-- Bind the wayfinder to whoever summoned it, so a passer-by cannot ride
	-- someone else's compass. The account id is what the destination list is
	-- keyed on, and the character id is only for the "not yours" message.
	wayfinder:SetEntityVariable("airaid_account", tostring(e.self:AccountID()))
	wayfinder:SetEntityVariable("airaid_summoner", e.self:GetCleanName())
	wayfinder:SetEntityVariable("airaid_lifetime", tostring(LIFETIME_MS))

	e.self:Message(MT.Yellow, "You unfold the compass. A wayfinder steps out of "
		.. "the air beside you.")

	return 1
end
