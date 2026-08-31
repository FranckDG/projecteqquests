-- Ellianne Silvertouch, Enchantress. Hands back enchanted metal for raw metal
-- and a fee.
--
-- ---------------------------------------------------------------------------
-- WHY SHE EXISTS.
--
-- Enchant Silver and its siblings are not transmutes. In EQEmu they are
-- SE_SummonItem (effect 32) spells: self-targeted, consuming a component from
-- the CASTER's inventory and summoning the product to the CASTER. That shape is
-- exactly why an enchanter BOT cannot do this for you:
--
--   - The spells are in no bot's spell list at all - zero rows in
--     bot_spells_entries - so `^cast byid` fails Bot::CanUseBotSpell and the
--     bot is silently skipped, with no error anywhere.
--   - Even if they were listed, bot_cast.cpp retargets a self spell to the bot,
--     so the raw bar would have to come out of the BOT's inventory and the
--     enchanted bar would land on the bot. Bots have equipment slots 0-22 and no
--     general inventory to hold a stack of bars.
--
-- She is the small answer to that, instead of forking the server to give bots a
-- backpack.
--
-- ---------------------------------------------------------------------------
-- SHE WORKS IN STACKS, AND ALL OR NOTHING.
--
-- Every one of these bars stacks to 20 and jewelcraft eats them by the dozen, so
-- she counts CHARGES rather than items: hand her a stack of 20 and 20 come back.
--
-- If anything in the trade is not metal she can work, she returns the whole
-- trade rather than keeping the parts she likes. NPC::ReturnHandinItems is
-- all-or-nothing by construction - it hands back every item AND the money - and
-- that is the right behaviour anyway: losing an odd item to a fat-fingered
-- handin is a worse outcome than being told to try again.
local flags = require("airaid_flags")
local item_lib = require("items")

-- Raw metal -> what it becomes, the fee per bar, and the era that must be open.
-- Seven metals, so a table rather than machinery.
--
-- Eras come from where the raw bar can actually be bought: all of these are sold
-- in Classic zones except Velium, which is Velious. The fee is roughly a quarter
-- of the raw bar's vendor price, which leaves silver trivial and velium a real
-- decision.
local METALS = {
	[16902] = { product = 16896, fee = 1,  era = 0, name = 'clay' },
	[16500] = { product = 16504, fee = 1,  era = 0, name = 'silver' },
	[16501] = { product = 16505, fee = 1,  era = 0, name = 'electrum' },
	[16502] = { product = 16506, fee = 3,  era = 0, name = 'gold' },
	[10474] = { product = 10434, fee = 4,  era = 0, name = 'brellium' },
	[16503] = { product = 16507, fee = 25, era = 0, name = 'platinum' },
	[22098] = { product = 22099, fee = 63, era = 2, name = 'velium' },
}

-- Fixed order for the price list. pairs() over a table with numeric keys has no
-- order, and a price list that reshuffles every hail looks broken.
local MENU = { 16902, 16500, 16501, 16502, 10474, 16503, 22098 }

local COPPER_PER_PLATINUM = 1000

local function tell(e, text)
	e.other:Message(MT.Yellow, text)
end

local function refuse(e, reason)
	tell(e, reason)
	item_lib.return_items(e.self, e.other, e.trade)
end

-- ---------------------------------------------------------------------------

function event_say(e)
	if not e.other.valid or not e.message:findi("hail") then
		return
	end

	e.self:Say("Raw metal is a dull thing, " .. e.other:GetCleanName()
		.. ". Hand me bars and coin together and I will wake them up. I work by "
		.. "the stack - do not trouble yourself handing them over one at a time.")

	local era = flags.current_era()
	local offered = {}

	for _, item_id in ipairs(MENU) do
		local metal = METALS[item_id]

		if metal.era <= era then
			table.insert(offered, metal.name .. " " .. metal.fee .. "pp")
		end
	end

	tell(e, "Per bar: " .. table.concat(offered, ", ") .. ".")
end

function event_trade(e)
	if not e.other.valid then
		return
	end

	local era = flags.current_era()
	local paid = (e.trade.platinum or 0) * COPPER_PER_PLATINUM
		+ (e.trade.gold or 0) * 100
		+ (e.trade.silver or 0) * 10
		+ (e.trade.copper or 0)

	local owed = 0
	local work = {}

	for slot = 1, 4 do
		local inst = e.trade["item" .. slot]

		if inst ~= nil and inst.valid then
			local metal = METALS[inst:GetID()]

			if metal == nil then
				refuse(e, "I work metal, and that is not metal I know.")
				return
			end

			if metal.era > era then
				refuse(e, "I have never seen " .. metal.name
					.. ". Bring it to me when the world has.")
				return
			end

			-- Charges are the stack size for a stackable item. A single bar can
			-- report 0 or 1, so anything under 1 counts as one - the same
			-- max(charges, 1) the engine itself applies to handins.
			local count = inst:GetCharges()

			if count == nil or count < 1 then
				count = 1
			end

			table.insert(work, { metal = metal, count = count })
			owed = owed + (metal.fee * COPPER_PER_PLATINUM * count)
		end
	end

	if #work == 0 then
		refuse(e, "Bring me metal and coin, and I will do the rest.")
		return
	end

	if paid < owed then
		refuse(e, "That is " .. math.ceil(owed / COPPER_PER_PLATINUM)
			.. "pp of work and you have offered "
			.. math.floor(paid / COPPER_PER_PLATINUM) .. "pp. Come back with the rest.")
		return
	end

	-- Past here the trade is accepted. The raw bars are consumed simply by not
	-- being returned: EVENT_TRADE has already taken them out of the player's
	-- inventory, and anything still held when this handler ends is gone.
	local made = 0

	for _, job in ipairs(work) do
		e.other:SummonItem(job.metal.product, job.count)
		made = made + job.count
	end

	local change = paid - owed

	if change > 0 then
		e.other:AddMoneyToPP(
			change % 10,
			math.floor(change / 10) % 10,
			math.floor(change / 100) % 10,
			math.floor(change / COPPER_PER_PLATINUM)
		)
	end

	e.self:Say("There. " .. made .. " woken and singing.")
end
