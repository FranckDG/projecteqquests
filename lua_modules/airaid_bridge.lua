-- airaid_bridge - server-side command queue drain.
--
-- VALIDATED end to end 2026-08-29: a command sent from a process outside the game
-- executed as the player, no MacroQuest involved. Full write-up, including the
-- limits against MQ, is in eq-ai-raid-deck/docs/bridge-decision.md.
--
-- Dispatch is client:SendGMCommand("#bot X") -> bot_command_dispatch (see
-- commands/airaid_bridge.lua). This is the other half: getting a command from a
-- web request into the zone process, which nothing outside the game can call
-- into.
--
-- The channel is a data bucket, and the reason it works is specific and easy to
-- get wrong. Zone caches buckets in g_data_bucket_cache, so a row written
-- straight to the `data_buckets` table by an outside process is normally NOT seen
-- - the zone serves its cached copy. But common/data_bucket.cpp:
--
--     bool DataBucket::CanCache(const DataBucketKey &key) {
--         if (key.character_id > 0 || key.account_id > 0 ||
--             key.bot_id > 0 || key.zone_id > 0) { return true; }
--         return false;
--     }
--
-- Only *scoped* buckets are cacheable. A global bucket is read from the database
-- every single time. So the character id goes in the key NAME ("airaid:cmd:5"),
-- never in the scoping column - which is also how airaid_era already keys
-- "airaid:kill:<npc_type_id>", so this repo has been relying on the same property
-- for a while.
--
-- Cost of that choice: one SELECT per player per tick. At a 1s interval and a
-- handful of players that is nothing next to what a zone already does per tick,
-- and it is only paid while a player is connected.
--
-- Latency is the poll interval: fine for managing a roster, too slow for combat
-- micro. That is the honest trade against MQ.
--
-- Item transfers ARE reachable this way, contrary to what this comment used to
-- say. The cursor is not client state - it is InventoryProfile::m_cursor, which
-- the zone owns - and ^inventoryremove writes it while ^inventorygive reads it.
-- See eq-ai-raid-deck/docs/bridge-decision.md.

local bridge = {}

local TIMER = "airaid_bridge"
local INTERVAL_MS = 1000
local BUCKET_CMD = "airaid:cmd:"
local BUCKET_ACK = "airaid:ack:"
local BUCKET_HB = "airaid:hb:"

-- Heartbeat cadence and lifetime.
--
-- Nothing outside the game can see who is connected: the deck could only queue a
-- command and wait to find out, which meant a twelve second pause before it could
-- say "is this character logged in?". This loop already runs once a second per
-- connected client, so it is the one place that knows.
--
-- Written every 10s rather than every tick, because a write per client per second
-- is real database traffic for a fact that changes on the scale of minutes. The
-- 30s lifetime is three missed writes, so a zone crash or a hard disconnect shows
-- as offline quickly without a clean logout being needed to clear it.
local HB_EVERY_SECONDS = 10
local HB_TTL = "30s"

--- char_id -> os.time() of its last heartbeat write. Per zone Lua state, which is
--- the same scope as the timers driving it.
local last_heartbeat = {}

local BUCKET_SPAWNED = "airaid:spawned:"
local BUCKET_CURSOR = "airaid:cursor:"

--- RoF2 invslot::slotCursor. Counted from the enum in common/patches/rof2_limits.h:
--- slotCharm=0 ... slotAmmo=22, slotGeneral1..10=23..32, slotCursor=33.
local SLOT_CURSOR = 33

--- Publish what the player is holding: item id, or "0" for an empty hand.
---
--- The deck has to refuse an item transfer unless the cursor is empty, and the
--- reason is nastier than a failed command. The cursor is a FIFO — ItemInstQueue
--- push() appends to the back while GetItem(slotCursor) reads peek_front() — so
--- with something already in hand, ^inventoryremove queues the bot's item BEHIND
--- it and the following ^inventorygive hands over the item you were already
--- holding. Wrong item, no error, and the bot's item left on your cursor.
---
--- Nothing outside the game can see the cursor, so it has to be published here.
local function publish_cursor(client, char_id)
	eq.set_data(BUCKET_CURSOR .. char_id, tostring(client:GetItemIDAt(SLOT_CURSOR)), HB_TTL)
end

--- Publish which of this character's bots are currently in the world.
---
--- `bot_data` records what EXISTS, never what is spawned — the zone holds that and
--- the only command that reports it, ^botreport, answers into the player's chat
--- where nothing server-side can read it. GetBotListByCharacterID is the entity
--- list's own answer, so this is the real thing rather than an inference.
---
--- Written as bot ids because the deck already keys its roster by bot_id, and a
--- name would need escaping the moment someone uses a comma.
local function publish_spawned(char_id)
	local ids = {}
	local list = eq.get_entity_list():GetBotListByCharacterID(char_id)
	for bot in list.entries do
		ids[#ids + 1] = tostring(bot:GetBotID())
	end
	-- Same lifetime as the heartbeat: if the client stops reporting, its spawn
	-- list must go stale with it rather than linger as a claim about the world.
	eq.set_data(BUCKET_SPAWNED .. char_id, table.concat(ids, ","), HB_TTL)
end

--- Start the drain loop for one client. Idempotent - set_timer replaces.
function bridge.start(client)
	if client == nil or client.null then
		return
	end
	eq.set_timer(TIMER, INTERVAL_MS, client)
end

--- Handle EVENT_TIMER. Returns true if this was our timer, so the caller can
--- tell whether it still needs to consider other handlers.
function bridge.on_timer(e)
	if e.timer ~= TIMER then
		return false
	end

	local char_id = e.self:CharacterID()

	-- Before anything else, and outside the pending check: presence has to be
	-- reported whether or not there is work, since "nobody has sent me a command"
	-- is exactly when the deck most wants to know you are reachable.
	local now = os.time()
	if (last_heartbeat[char_id] or 0) + HB_EVERY_SECONDS <= now then
		last_heartbeat[char_id] = now
		eq.set_data(BUCKET_HB .. char_id, tostring(now), HB_TTL)
		publish_spawned(char_id)
		publish_cursor(e.self, char_id)
	end

	local key = BUCKET_CMD .. char_id
	local pending = eq.get_data(key)

	if pending == nil or pending == "" then
		return true
	end

	-- Clear BEFORE dispatching, not after. A command that crashes or zones the
	-- player must not be left in the bucket to run again on the next tick - at
	-- best it repeats, at worst it repeats forever. Losing a command is
	-- recoverable; a loop that re-fires one is not.
	eq.delete_data(key)

	-- The queue carries the command without its leading ^, e.g. "follow byname
	-- Kleric". Anything the player could not type themselves must not become
	-- typeable here, so the prefix is added on this side and "#bot" is the only
	-- entry point used: it dispatches through the bot command parser, which
	-- enforces ownership and every other rule on its own.
	local ok = e.self:SendGMCommand("#bot " .. pending)

	-- The ack says the queue was drained. It says nothing else, and measurement
	-- proved that: queueing "definitelynotacommand" also acks "ok", because
	-- SendGMCommand reports whether *#bot* dispatched, and #bot dispatches fine
	-- before handing an unknown name to the bot parser, which then complains in
	-- the player's chat where we cannot see it.
	--
	-- So "ok" means delivered, never executed and never succeeded. Anything that
	-- needs to know an effect happened must re-read authoritative state from the
	-- database - which is what §4 already prescribes, and why this is a smaller
	-- loss than it looks. Validating the command name before queueing is the
	-- deck's job, and it now has the catalog to do it with.
	eq.set_data(
		BUCKET_ACK .. char_id,
		string.format("%d|%s|%s", os.time(), ok and "ok" or "rejected", pending),
		"5m"
	)

	-- Republish immediately rather than waiting up to 10s for the next heartbeat.
	-- ^botspawn and ^botcamp change the spawn set; ^inventoryremove and
	-- ^inventorygive change the cursor, and a transfer is a two-command sequence
	-- that cannot take its second step until the deck can see the first landed.
	publish_spawned(char_id)
	publish_cursor(e.self, char_id)

	return true
end

return bridge
