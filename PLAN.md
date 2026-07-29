# TotemPing — Plan

## Vision

A tiny quality-of-life addon for shamans in **WoW TBC Classic (2.5.6)** that quietly watches whether your party is benefiting from your totems and lets you (or them) know when they aren't. Non-noisy by default — grace windows and per-target cooldowns keep it from spamming as totems pulse and party members flicker in and out of range.

## Scope (MVP)

1. **Totem buff detection.** Track the buffs currently produced by the shaman's active totems (Strength of Earth, Grace of Air, Windfury, Mana Spring, Healing Stream, etc.) — infer from `TOTEM_UPDATE` + `GetTotemInfo(1..4)` rather than a hardcoded list, so the addon adapts to whatever totems the shaman actually dropped.
2. **Per-party-member scan.** Every N seconds (default 1s), for each party member, check whether each active-totem buff is present on them.
3. **Grace window.** A member is only flagged "out of range" if the buff is missing for more than `graceSeconds` (default 4s). Prevents false positives from totem pulse cycles and brief re-positioning.
4. **Per-target notify cooldown.** Once a member has been flagged for a given totem, don't re-notify for the same (member, totem) pair for `notifyCooldownSeconds` (default 30s).
5. **Notify sinks (configurable):**
   - Party chat (`/p`)
   - Whisper (`/w <member>`)
   - Self only (local print)
   - Off
6. **Auto vs manual mode.** Auto = notify as soon as a member trips the grace window. Manual = only notify when the user hits the manual-trigger keybind or clicks the toggle button.
7. **Master on/off toggle** with keybind support (via `Bindings.xml`).
8. **Manual-trigger keybind** to force a scan-and-notify pass at any moment.

## Non-goals for MVP

- Any UI beyond a minimal control frame + reused Blizzard party-frame overlay hooks. No custom draggable HUD in v1.
- Non-shaman classes. Class check at load; silent no-op if not shaman.
- Cross-realm / battleground weirdness. Party only (raid support = post-MVP).

## Technical Tasks

- [ ] Class gate: bail cleanly on non-shaman with a one-time message.
- [ ] Totem tracking: consume `PLAYER_TOTEM_UPDATE`, cache `(slot -> {name, buffName, expires})` from `GetTotemInfo`. Include a name→buff map for known TBC totems (Strength of Earth → "Strength of Earth", Grace of Air → "Grace of Air", Windfury Totem → "Windfury Totem", Mana Spring Totem → "Mana Spring", Healing Stream Totem → "Healing Stream", Wrath of Air → "Wrath of Air", etc.). Fall back to totem name as the buff name for less common ones.
- [ ] Party enumeration: iterate `party1..party4` (skip nonexistent), including the player themselves (they should benefit from their own totems).
- [ ] Buff scan: `UnitAura(unit, buffName, nil, "HELPFUL")` — check the caster arg equals `"player"` so we don't credit another shaman's identical buff.
- [ ] Range corroboration: `UnitInRange(unit)` as a coarse cross-check for the "why aren't they buffed" reason (out of range vs debuffed vs died).
- [ ] Grace/cooldown state machine: track `firstMissedAt[unit][totem]` and `lastNotifiedAt[unit][totem]`; only notify when `now - firstMissedAt >= graceSeconds` AND `now - lastNotifiedAt >= notifyCooldownSeconds`.
- [ ] Notify formatting: `"[TotemPing] <name> missing <buff> (out of range?)"` — one message per (member, totem) event. Batch multiple members' first misses into a single message on the same tick to avoid mid-fight spam.
- [ ] SavedVariables schema (`TotemPingDB`): `enabled`, `mode` ("auto"|"manual"), `sink` ("party"|"whisper"|"self"|"off"), `graceSeconds`, `notifyCooldownSeconds`, `scanIntervalSeconds`.
- [ ] Slash commands: `/tp`, `/tp on|off`, `/tp mode auto|manual`, `/tp sink party|whisper|self|off`, `/tp grace <n>`, `/tp cooldown <n>`, `/tp scan` (manual trigger), `/tp status`, `/tp debug`.
- [ ] `Bindings.xml` for two secure clickable buttons: `TOTEMPING_TOGGLE` (master on/off) and `TOTEMPING_SCAN` (manual trigger).
- [ ] Minimal control frame: single button showing enabled/disabled state; middle-clickable to cycle modes. Draggable, position saved.

## QA / Edge Cases

- Grouping with another shaman: don't credit their buffs as ours (caster == player).
- Solo (no party): scan skipped entirely.
- Warlock imps and other pets in party: skip non-player units.
- Party member zones out or is dead: don't notify.
- Totem expires or is destroyed mid-scan: remove from tracked set immediately.
- Combat lockdown: avoid protected calls; whisper/party chat aren't protected but keybinds via `SecureActionButton` are.
- Multi-totem overlap (e.g. two different air totems can't coexist — Grace of Air replaces Wrath of Air): treat active-totem list as source of truth.

## Post-MVP / Stretch

- **Per-unit range indicator overlay on party frames.** Small colored icon per party member: green (has buff + `UnitInRange` true), yellow (has buff but borderline), red (missing buff past grace). Requested by Omedus.
- **Ground-ring visualization around totems in the world.** Investigated: not feasible in TBC Classic. There's no supported API to get a unit's world (x,y,z) coordinates or screen position for a non-player unit like a totem, and `GetPlayerMapPosition` is 2D map-relative only. No existing addons do this because Blizzard has locked down the surface. Documenting the negative result here so we don't chase it again.
- **Raid support.** Extend `party1..party4` iteration to `raid1..raid40` with reasonable batching.
- **Buff-list customization.** Let the user add/remove buff names from the tracked set (e.g. ignore Tranquil Air).
- **Sound cue** on notify (short beep, low volume).

## Deliverables

- v0.1.0 scaffold (this).
- v0.2.0 first real feature = MVP scope above, shipped after `!ship` from deehoc.
- CurseForge project + auto-release wired via `.curseforge.json` once deehoc provides the project ID.
