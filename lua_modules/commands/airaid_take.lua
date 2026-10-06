-- #atake - move one item from YOUR OWN carried inventory onto your cursor.
--
--   #atake <slot>   put the item in that slot on your cursor
--   #atake list     print what you are carrying, with the slot number of each
--   #atake          this help
--
-- WHY THIS EXISTS. The deck moves items between bots with two queued commands:
-- `^inventoryremove` pulls from a bot to your cursor, `^inventorygive` hands your
-- cursor to another bot. Both halves source from a BOT - ActionableBots::PopulateSBL
-- is how `^inventoryremove` resolves its target - so the one thing the chain could
-- not do was start from your own bags. The Armory shows your character beside the
-- bots and the "take" buttons on your own rows had nothing to call. This is that
-- missing half.
--
-- Access 0. It moves your item from one of your slots to another of your slots.
-- There is no target but yourself and nothing here reaches another character.

--[[
	WHAT THIS DELIBERATELY WILL NOT DO, and why.

	Worn equipment (slots 0-22) is refused. Client::DeleteItemInInventory does NOT
	call CalcBonuses - PutItemInInventory does, DeleteItemInInventory does not - and
	Lua has no CalcBonuses binding to make up for it (see lua_client.cpp; only
	SendWearChange is exposed, and that is appearance, not stats). So unequipping
	this way would leave you wearing the AC, hit points and resists of an item that
	is no longer on you until something else forces a recalculation. Dragging it off
	in the inventory window goes through Handle_OP_MoveItem, which recalculates
	properly. Not worth a silent stat lie to save that drag.

	The bank is refused for a duller reason: the Armory does not show it, so a slot
	number from there is a typo rather than an intention.

	ORDER MATTERS. Push first, delete second. The reverse - or the tempting
	Inventory:PopItem() - hands ownership of the live instance to Lua, so any
	failure after that point DESTROYS the item. This way the worst case is the
	in-memory cursor and the slot briefly holding the same thing if SaveCursor
	fails, which the next load resolves in the slot's favour. A duplicate you can
	see beats an item that silently stopped existing.

	Do not reach for Slot.General2BagBegin and friends to range-check bag slots.
	Those constants are built on a stride of 10 (lua_general.cpp:7085+) and this
	server's bag stride is invbag::SLOT_COUNT = 200, so General5BagBegin names a
	slot inside bag 1. GeneralBagsBegin/GeneralBagsEnd are derived from SLOT_COUNT
	and are correct; Inventory:CalcSlotId(slot, idx) does the arithmetic for you.
]]

local function is_general(slot)
	return slot >= Slot.GeneralBegin and slot <= Slot.GeneralEnd
end

local function is_general_bag(slot)
	return slot >= Slot.GeneralBagsBegin and slot <= Slot.GeneralBagsEnd
end

local function usage(e)
	e.self:Message(MT.Yellow, "#atake - move an item from your inventory to your cursor")
	e.self:Message(MT.Yellow, "  #atake <slot>   put that slot's item on your cursor")
	e.self:Message(MT.Yellow, "  #atake list     list what you carry, with slot numbers")
	e.self:Message(
		MT.Yellow,
		"Slots " .. Slot.GeneralBegin .. "-" .. Slot.GeneralEnd ..
		" are your ten inventory slots; " .. Slot.GeneralBagsBegin .. "+ is inside a bag."
	)
end

-- The ten carried slots and the contents of any bag in them. Slot numbers are the
-- point of this: nothing in the game window shows them, and every command that
-- touches an item asks for one.
local function show_inventory(e)
	local inv = e.self:GetInventory()
	local found = 0

	for slot = Slot.GeneralBegin, Slot.GeneralEnd do
		local inst = inv:GetItem(slot)

		if inst.valid then
			found = found + 1
			e.self:Message(MT.Yellow, slot .. "  " .. inst:GetItemLink())

			local bag_slots = inst:GetItem():BagSlots()

			for idx = 0, bag_slots - 1 do
				local carried = inv:GetItem(slot, idx)

				if carried.valid then
					found = found + 1
					e.self:Message(
						MT.White,
						"   " .. inv:CalcSlotId(slot, idx) .. "  " .. carried:GetItemLink()
					)
				end
			end
		end
	end

	if found == 0 then
		e.self:Message(MT.Yellow, "You are carrying nothing.")
	end
end

local function airaid_take(e)
	-- e.args is a TABLE of words, not the raw argument string.
	local args = e.args or {}
	local arg = args[1]

	if arg == nil then
		usage(e)
		return
	end

	if arg:lower() == "list" then
		show_inventory(e)
		return
	end

	local slot = tonumber(arg)

	if slot == nil or slot ~= math.floor(slot) then
		e.self:Message(MT.Red, "'" .. arg .. "' is not a slot number.")
		usage(e)
		return
	end

	if slot == Slot.Cursor then
		e.self:Message(MT.Red, "Slot " .. slot .. " IS your cursor.")
		return
	end

	if slot >= Slot.PossessionsBegin and slot < Slot.GeneralBegin then
		e.self:Message(
			MT.Red,
			"Slot " .. slot .. " is worn equipment. #atake will not unequip: the server " ..
			"would keep that item's stats on you until something recalculated them. " ..
			"Drag it off in your inventory window instead."
		)
		return
	end

	if not (is_general(slot) or is_general_bag(slot)) then
		e.self:Message(
			MT.Red,
			"Slot " .. slot .. " is not somewhere #atake reaches - it handles what you " ..
			"carry, not the bank or a trade window."
		)
		usage(e)
		return
	end

	-- The cursor is a FIFO, so pushing onto a full one loses nothing - but the item
	-- lands BEHIND what is already in hand, and the ^inventorygive that usually
	-- follows reads the front. That hands over the wrong item, with no error, and
	-- leaves this one stranded. airaid_bridge.lua's publish_cursor has the full
	-- account; this is the same hazard reached from the other end.
	local cursor = e.self:GetInventory():GetItem(Slot.Cursor)

	if cursor.valid then
		e.self:Message(
			MT.Red,
			"Your cursor is holding " .. cursor:GetName() .. ". Put it down first."
		)
		return
	end

	local inst = e.self:GetInventory():GetItem(slot)

	if not inst.valid then
		e.self:Message(MT.Yellow, "Slot " .. slot .. " is empty.")
		return
	end

	-- Read everything needed for the message NOW. The delete below frees the
	-- instance this wrapper points at, and touching it afterwards is a dangling
	-- read into freed memory.
	local link = inst:GetItemLink()
	local stacked = inst:IsStackable() and inst:GetCharges() > 1
	local charges = inst:GetCharges()

	if not e.self:PushItemOnCursor(inst) then
		e.self:Message(
			MT.Red,
			"Could not put " .. link .. " on your cursor. Nothing was moved."
		)
		return
	end

	-- Quantity 0 means the whole instance, charges and all: InventoryProfile::
	-- DeleteItem only splits a stack when quantity > 0, and falls through to a
	-- full delete otherwise. A bag goes with its contents, in memory and in the
	-- database both - DeleteInventorySlot clears the child rows for any slot that
	-- SupportsContainers, so nothing is left behind to reappear on the next load.
	e.self:DeleteItemInInventory(slot, 0, true)

	e.self:Message(
		MT.Yellow,
		"Moved " .. link .. (stacked and (" x" .. charges) or "") ..
		" from slot " .. slot .. " to your cursor."
	)
end

return airaid_take;
