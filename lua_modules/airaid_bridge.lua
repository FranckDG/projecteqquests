-- airaid_bridge - server-side command queue drain. SPIKE, see #abridge.
--
-- The deck needs to make a bot command run as the player without MacroQuest.
-- Dispatch is solved (client:SendGMCommand("#bot X") -> bot_command_dispatch, see
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
-- micro. That is the honest trade against MQ, along with item transfers, which
-- need the client's cursor and are not reachable this way at all.

local bridge = {}

local TIMER = "airaid_bridge"
local INTERVAL_MS = 1000
local BUCKET_CMD = "airaid:cmd:"
local BUCKET_ACK = "airaid:ack:"

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

	-- The ack is what the deck polls to learn the command was consumed. It says
	-- "dispatched", not "succeeded" - the deck re-reads authoritative state from
	-- the database after a mutation, which is what actually confirms an effect.
	eq.set_data(
		BUCKET_ACK .. char_id,
		string.format("%d|%s|%s", os.time(), ok and "ok" or "rejected", pending),
		"5m"
	)

	return true
end

return bridge
