-- Orvin Inkbind, the Scrivener. Trades research pages between the schools.
--
-- ---------------------------------------------------------------------------
-- WHAT HE IS FOR.
--
-- Research words drop without regard to who is holding the bag. A necromancer
-- clearing Mistmoore fills up with enchanter and magician pages that no recipe
-- of his will ever take, and the words he does need are elsewhere. There is no
-- vendor for most of them and no way to convert one into another.
--
-- He takes a page for any school and hands back one of the SAME LEVEL for
-- yours, one for one, stack for stack.
--
-- ---------------------------------------------------------------------------
-- HE CANNOT READ A PAGE'S SCHOOL OFF THE ITEM, AND NEITHER CAN ANYONE.
--
-- `items` has no class column for a component and no expansion column at all,
-- and the words are not named after the school that uses them. Both facts come
-- out of the recipe graph instead - component -> recipe -> spell ->
-- spells_new.classes11..14 - which is why airaid_research.lua is GENERATED and
-- must be regenerated rather than patched:
--
--     node tools/gen-research-trader.mjs
--
-- The generator's header carries the measurements behind the three filters on
-- what he is willing to hand out, and refuses to emit a table that cannot
-- answer every level it might be handed.
--
-- ---------------------------------------------------------------------------
-- THE HANDIN IS A PARTIAL CLAIM, AND THAT NEEDS THE EXPLICIT RETURN.
--
-- `eq.handin(claim)` consumes exactly what is listed and leaves everything else
-- sitting in the NPC's hand-in bucket. Nothing gives those leftovers back on
-- its own: `trading.cpp` only calls `ReturnHandinItems()` when EVENT_TRADE did
-- NOT start a hand-in (`if (!handin_npc->HandinStarted())`), and `eq.handin`
-- starts one. So a script that claims a subset and stops there has silently
-- eaten the rest.
--
-- Every path here therefore ends in `item_lib.return_items`, which is a thin
-- wrapper over `npc:ReturnHandinItems(client)`. Called with nothing left in the
-- bucket it is a no-op, so it is safe to call on the success path too - and on
-- the success path it is the only thing handing back the pages he would not
-- take.
--
-- COIN IS REFUSED RATHER THAN CLAIMED. `NPC::CheckHandin` compares money with
-- == , not >= , so a claim that does not name every coin on the table fails the
-- whole hand-in - and by then the items are gone. He has no fee, so the
-- simplest correct thing is to refuse any trade carrying money before claiming
-- anything at all.
--
-- ---------------------------------------------------------------------------
-- STACKS, AND WHY THEY CANNOT OVERFLOW THE BAGS.
--
-- He works in stacks, because hand-me-one-at-a-time is no use for pages that
-- drop twenty at a time. The hazard is that stack sizes are NOT uniform: among
-- research components they run 1, 20, 25, 50, 100 and 200, so a hundred pages
-- that stack to a hundred, traded for pages that stack to twenty, would need
-- five inventory slots to land in - and `eq.handin` has already eaten the
-- originals by then.
--
-- Each swap is therefore capped at the stack size of what he is handing BACK.
-- That makes the slot arithmetic safe by construction rather than by checking:
-- every page handed over vacated one inventory slot, and every page handed back
-- occupies at most one. Whatever is over the cap is simply not claimed, so the
-- engine returns it - to the cursor, with its remaining count, which is what
-- `ReturnHandinItems` does with a partly claimed stack.
--
-- The free-slot check before the claim is belt and braces for the one case the
-- arithmetic does not cover: a trade made from the cursor, which vacated no
-- inventory slot at all. `Client::SummonItem` falls back to the cursor when it
-- can find no slot, so nothing is ever destroyed either way - but having the
-- pages consumed and the replacements stuck behind a full bag is a bad trade
-- for the player, and it is cheap to refuse instead.
local research = require("airaid_research")
local flags = require("airaid_flags")
local item_lib = require("items")

-- The trade window has four slots.
local TRADE_SLOTS = 4

local function tell(e, text)
	e.other:Message(MT.Yellow, text)
end

-- Hand the whole trade back. Safe before any claim and after a partial one.
local function refuse(e, reason)
	tell(e, reason)
	item_lib.return_items(e.self, e.other, e.trade)
end

-- What to hand back for one page.
--
-- Everything within `research.tolerance` levels is a candidate, weighted by
--
--     weight * (tolerance + 1 - distance)
--
-- so an exact level match is six times as likely as one five levels out, and
-- among equals a commonly dropped page beats a rare one. That second half is
-- the only thing stopping a free one-for-one swap being used to churn a pile of
-- commons into whichever rare page a player wanted; `weight` is how many npc
-- types drop it, which spans 1 to 2306.
--
-- Pages out of era are excluded, as is the page just handed over - being given
-- back the thing you were trying to get rid of reads as a bug.
local function offer(tag, level, era, exclude_id, rng)
	local pool = research.pool[tag]

	if pool == nil then
		return nil
	end

	local span = research.tolerance
	local candidates = {}
	local total = 0

	for _, entry in ipairs(pool) do
		local distance = entry.level - level

		if distance < 0 then
			distance = -distance
		end

		if distance <= span and entry.era <= era and entry.id ~= exclude_id then
			local weight = entry.weight * (span + 1 - distance)

			total = total + weight
			table.insert(candidates, { entry = entry, weight = weight })
		end
	end

	if total == 0 then
		return nil
	end

	local roll = rng(total)

	for _, candidate in ipairs(candidates) do
		roll = roll - candidate.weight

		if roll <= 0 then
			return candidate.entry
		end
	end

	-- Unreachable while the weights sum to `total`, but a rounding surprise
	-- should hand over a page rather than nothing.
	return candidates[#candidates].entry
end

function event_say(e)
	if not e.other.valid or not e.message:findi("hail") then
		return
	end

	e.self:Say("Pages, " .. e.other:GetCleanName()
		.. ". Everyone who swings a sword at a scribe comes away with the wrong "
		.. "ones. Hand me words meant for another school and I will give you the "
		.. "same weight of words meant for yours, at the level you found them.")

	local tag = research.class_tag[e.other:GetClass()]

	if tag == nil then
		tell(e, "Not that you have any use for them. Still, you may hand them to "
			.. "someone who does.")
		return
	end

	tell(e, "I trade page for page and stack for stack, and I take no coin. "
		.. "Words already meant for a " .. research.class_name[tag]
		.. " I will hand straight back - you are better served keeping those.")
end

function event_trade(e)
	if not e.other.valid then
		return
	end

	local tag = research.class_tag[e.other:GetClass()]

	if tag == nil then
		refuse(e, "I deal in research, and research is for those who study it. "
			.. "These are no use to you and none to me.")
		return
	end

	-- Refused rather than claimed: see the note on CheckHandin above.
	local coin = (e.trade.platinum or 0) + (e.trade.gold or 0)
		+ (e.trade.silver or 0) + (e.trade.copper or 0)

	if coin > 0 then
		refuse(e, "Page for page. Keep your coin.")
		return
	end

	local era = flags.current_era()
	local rng = math.random

	-- Claims name every coin on the table, and there are none.
	local claim = { platinum = 0, gold = 0, silver = 0, copper = 0 }
	local gives = {}
	local notes = {}
	local pages = 0

	for slot = 1, TRADE_SLOTS do
		local inst = e.trade["item" .. slot]

		if inst ~= nil and inst.valid then
			local item_id = inst:GetID()

			-- Charges are the stack size, and the engine counts a hand-in the
			-- same way: max(charges, 1) for a stackable item.
			local count = inst:GetCharges()

			if count == nil or count < 1 then
				count = 1
			end

			local universal = research.universal[item_id]
			local page = research.component[item_id]

			if universal ~= nil then
				table.insert(notes, universal .. " answers to every school already")
			elseif page == nil then
				table.insert(notes, "I do not know that one as a page of research")
			elseif page.classes[tag] then
				table.insert(notes, page.name .. " is already a "
					.. research.class_name[tag] .. "'s page")
			else
				local pick = offer(tag, page.level, era, item_id, rng)

				if pick == nil then
					table.insert(notes, "I have nothing of ours near level "
						.. page.level .. " in this age")
				else
					-- Capped at what he hands back, not at what he was given.
					local take = count

					if take > pick.stack then
						take = pick.stack
						table.insert(notes, "I can take " .. pick.stack .. " of "
							.. page.name .. " at a time, no more")
					end

					claim[item_id] = (claim[item_id] or 0) + take
					table.insert(gives, { id = pick.id, count = take, name = pick.name })
					pages = pages + take
				end
			end
		end
	end

	if #gives == 0 then
		refuse(e, #notes > 0 and (table.concat(notes, "; ") .. ".")
			or "Hand me pages of research and I will trade them.")
		return
	end

	-- Before anything is consumed. INVALID_INDEX is -1; try_cursor is false on
	-- purpose, because the cursor is where a refusal would already be putting
	-- things back.
	local free = e.other:GetInventory():FindFreeSlot(false, false, 1, false)

	if free == nil or free < 0 then
		refuse(e, "Your bags are full. I will not take pages I cannot pay you for.")
		return
	end

	if not eq.handin(claim) then
		-- Should be unreachable: the claim is built from what was handed over
		-- and names the coin exactly.
		refuse(e, "A page slipped out of my hands. Take them back and try again.")
		return
	end

	local said = {}

	for _, give in ipairs(gives) do
		e.other:SummonItem(give.id, give.count)
		table.insert(said, give.count .. "x " .. give.name)
	end

	e.self:Say(pages .. " for " .. pages .. ". " .. table.concat(said, ", ") .. ".")

	-- The pages he would not take are still in the hand-in bucket, and this is
	-- the only thing that gives them back.
	if #notes > 0 then
		tell(e, "Back to you: " .. table.concat(notes, "; ") .. ".")
	end

	item_lib.return_items(e.self, e.other, e.trade)
end
