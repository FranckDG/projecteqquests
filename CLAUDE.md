# AI Raid — quests fork

Fork of `ProjectEQ/projecteqquests`. **All AI Raid work lives on the `airaid` branch**; `upstream` points at ProjectEQ so their updates can be merged in.

The main project context is in the sibling repo **`eq-ai-raid-server/CLAUDE.md`** — read that first.

## What we added

| File | Role |
|---|---|
| `lua_modules/airaid_era.lua` | The era ladder, zone side: records gate boss kills, announces tier progress, refreshes the zone when the controller unlocks something. |
| `lua_modules/commands/airaid_kill.lua` | `#akill` — a GM instakill that credits the killer. Access 80. |
| `lua_modules/airaid_bridge.lua` | The deck's write path: drains a queued bot command per connected client and dispatches it with `client:SendGMCommand`. Read `eq-ai-raid-deck/docs/bridge-decision.md` before touching it — two details break it silently. |
| `lua_modules/commands/airaid_bridge.lua` | `#abridge` — dispatch a `^` command as yourself, or inspect the queue. Access 0. |
| `global/global_npc.lua` | `event_death_complete` — new function, no upstream code touched. |
| `global/global_player.lua` | One-line calls added to `event_enter_zone` and `event_connect`, plus a new `event_zone` and `event_timer`. |
| `lua_modules/command.lua` | One line each registering `#akill` and `#abridge`. |

Everything else is upstream. Only `global_player.lua` and `command.lua` have upstream functions modified, and both are single-line inserts, so merges should stay manageable.

## Why the logic is in a module

`require()` caches modules per Lua state, so every hook in a zone shares **one** generation cache. When `global_npc.lua` and `global_player.lua` each kept a `local` copy they took separate "first sync" passes, and the first mob death after entering a zone never announced.

## Why quest scripts only leave breadcrumbs

They cannot do the unlock. `eq.set_rule()` resolves to `RuleManager::SetRule(name, value)` with `db=nullptr, db_save=false` — in-memory and zone-local — and there is no SQL binding in the quest API. `eq.set_data()` into `data_buckets` is the only persistence available, so the controller in the server repo does the deciding.

## Deploying

`~/eqemu/akk-stack/server/quests` is a checkout of this fork on the `airaid` branch, and `~/server/lua_modules` is a symlink into it, so a `git pull` there is the deployment. Zones cache quest scripts, so restart the stack (or reload quests) afterwards.

## Gotcha

This checkout has **CRLF** line endings on Windows. `perl`/`sed` patterns using bare `\n` silently match nothing.

## Validate Lua by LOADING it, not with `luac -p`

`luac -p` only checks syntax. A file can be perfectly valid and still fail the moment it executes — which is exactly what happened when a splice-based edit deleted `local M = {}` from `airaid_era.lua`. The module failed at load with *"attempt to index global 'M'"*, and because both global scripts `require` it, one missing line silently killed **every** Lua hook in the zone: `#akill`, PEQ's own `#hotzone` (`event_command` lives in `global_player.lua`), the era refresh, and gate boss kill recording.

After any edit, load it and check the exports:

```bash
docker compose exec eqemu-server bash -lc 'cd ~/server/lua_modules && lua -e "
  eq = setmetatable({}, {__index=function() return function() return \"\" end end})
  MT = setmetatable({}, {__index=function() return 0 end})
  local m = assert(loadfile(\"airaid_era.lua\"))()
  print(type(m.record_kill), type(m.refresh))
"'
```

Two things make this failure mode nasty: there are **no zone logs on this install**, so the Lua error is invisible, and the symptom appears far from the cause — a broken module looks like "the command framework is broken".

Note `bit` is missing from standalone `lua` but present in EQEmu's embedded interpreter, so `dragons_of_norrath.lua` fails to load in a bare test. Stub `bit` if you need to test something that pulls it in.

## Exploration quests

A second, independent ladder: explore dungeons, kill their named bosses, earn
per-class charms by level band. Shares only `event_death_complete` with the era
ladder. The design record is `eq-ai-raid-server/docs/exploration-quests.md`.

| File | Role |
|---|---|
| `lua_modules/airaid_pools.lua` | **GENERATED.** Which dungeons and bosses belong to which band, plus Compass destinations. Regenerate with `node tools/gen-pools.mjs` in the server repo — never hand-edit, and never hand-write an npc id into it. |
| `lua_modules/airaid_charms.lua` | **GENERATED.** Charm and augment item ids, and the class → archetype lookup. From `node tools/gen-charms.mjs`. |
| `lua_modules/airaid_flags.lua` | Visit/kill flags, band progress, claim and payment bookkeeping. |
| `ecommons/Wyn_Farsight.lua` | The Cartographer: reports progress, pays it, hands over charms, titles and the Compass. |
| `ecommons/Sergeant_Brask.lua` | The Quartermaster: sells earned charms and sigils, unlimited. |
| `global/items/900500.lua` | The Explorer's Compass. Summons the wayfinder. |
| `global/a_wayfinder.lua` | Offers unlocked destinations and ports. |

Tests live in the server repo: `./tools/run-lua-tests.sh` loads and drives all of
it against stubbed bindings.

### Three things that fail silently here

- **A quest clicky needs a click effect it never casts.** No spell means the
  client never sends `OP_CastSpell`, so the script never runs. The Compass
  carries an inert spell and returns `1`, which is what suppresses the cast.
  Returning `nil` casts it instead — no error, just a stray cast bar.
- **`clicktype 3` is Expendable** and consumes the item. Clickies that should
  last want `1`.
- **Compass destinations must not be `zone_points.x/y/z`.** That is the inbound
  trigger; landing there zones you straight into the dungeon. Use
  `target_x/y/z` of the route *out*.

## Item scripts: `e.self` is the ITEM

For item events `lua_parser.cpp` pushes the `Lua_ItemInst` as **`self`** and the
`Client` as **`owner`** — the opposite way round from NPC and player scripts,
where `self` is the NPC or the client. Treating `e.self` as the player fails
with *"attempt to call method 'IsEngaged' (a nil value)"* the moment anyone
clicks the item, and the script dies before doing anything.

An item script is found by `items.scriptfileid` → `script_<id>`, else by
`CharmFile`, else by the **item id** — so with `scriptfileid = 0` the file is
`global/items/<itemid>.lua`.

## Handins: claim what you keep, or the engine gives it back

`Items:AlwaysReturnHandins` is true, and `trading.cpp:651` calls
`ReturnHandinItems()` for anything `EVENT_TRADE` did not claim. So a handler
that summons a product without claiming the components hands the components back
as well — the player keeps both.

```lua
eq.handin({ [16500] = 20, platinum = 20 })   -- what the NPC KEEPS
```

**Money must match exactly.** `NPC::CheckHandin` compares with `==`, not `>=`.
Claiming 20pp of a 25pp payment fails the whole handin — and by then `eq.handin`
has stepped past the engine's catch-all return, so the items are consumed with
nothing given back. Claim every coin handed over and refund the change yourself.

On a failed claim, return the items **explicitly**; do not rely on the catch-all.

## Zone once after deploying

The bridge's drain loop starts its timer in `event_enter_zone` and
`event_connect`. A client already sitting in a zone when the scripts land has no
timer — so no heartbeat, and the deck reports the character as not logged in
even though they are online and can see their bots.
