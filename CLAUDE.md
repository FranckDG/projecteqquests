# AI Raid — quests fork

Fork of `ProjectEQ/projecteqquests`. **All AI Raid work lives on the `airaid` branch**; `upstream` points at ProjectEQ so their updates can be merged in.

The main project context is in the sibling repo **`eq-ai-raid-server/CLAUDE.md`** — read that first.

## What we added

| File | Role |
|---|---|
| `lua_modules/airaid_era.lua` | The era ladder, zone side: records gate boss kills, announces tier progress, refreshes the zone when the controller unlocks something. |
| `lua_modules/commands/airaid_kill.lua` | `#akill` — a GM instakill that credits the killer. Access 80. |
| `global/global_npc.lua` | `event_death_complete` — new function, no upstream code touched. |
| `global/global_player.lua` | One-line calls added to `event_enter_zone` and `event_connect`, plus a new `event_zone`. |
| `lua_modules/command.lua` | One line registering `#akill`. |

Everything else is upstream. Only `global_player.lua` and `command.lua` have upstream functions modified, and both are single-line inserts, so merges should stay manageable.

## Why the logic is in a module

`require()` caches modules per Lua state, so every hook in a zone shares **one** generation cache. When `global_npc.lua` and `global_player.lua` each kept a `local` copy they took separate "first sync" passes, and the first mob death after entering a zone never announced.

## Why quest scripts only leave breadcrumbs

They cannot do the unlock. `eq.set_rule()` resolves to `RuleManager::SetRule(name, value)` with `db=nullptr, db_save=false` — in-memory and zone-local — and there is no SQL binding in the quest API. `eq.set_data()` into `data_buckets` is the only persistence available, so the controller in the server repo does the deciding.

## Deploying

`~/eqemu/akk-stack/server/quests` is a checkout of this fork on the `airaid` branch, and `~/server/lua_modules` is a symlink into it, so a `git pull` there is the deployment. Zones cache quest scripts, so restart the stack (or reload quests) afterwards.

## Gotcha

This checkout has **CRLF** line endings on Windows. `perl`/`sed` patterns using bare `\n` silently match nothing.
