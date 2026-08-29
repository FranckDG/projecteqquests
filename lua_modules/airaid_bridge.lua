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
-- micro. That is the honest trade against MQ, along with item transfers, which
-- need the client's cursor and are not reachable this way at all.

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

	return true
end

return bridge
