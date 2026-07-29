# TotemPing

A tiny quality-of-life addon for **shamans** in **WoW TBC Classic (2.5.6)**.

**Concept:** quietly watch whether your party is benefiting from your totem buffs; when someone drops out of range for more than a grace window, notify them (party chat, whisper, or self-only). Configurable auto vs manual mode, master on/off toggle, and a keybind to force a scan.

## Install

1. Copy the `TotemPing` folder into `World of Warcraft\_classic_\Interface\AddOns\`.
2. Restart the client or `/reload`.

## Commands

- `/tp` or `/totemping` — status + help.
- `/tp on` / `/tp off` — master toggle.
- `/tp mode auto|manual` — auto notifies on grace expiry; manual only notifies on `/tp scan` or the `TOTEMPING_SCAN` keybind.
- `/tp sink party|whisper|self|off` — where notifies go.
- `/tp grace <seconds>` — how long a buff must be missing before flagging (default 4; 0 disables).
- `/tp cooldown <seconds>` — per-target re-notify cooldown (default 30).
- `/tp interval <seconds>` — scan tick interval (default 1).
- `/tp scan` — force an immediate scan + notify pass.
- `/tp status` — dump config, active totems, current miss set.
- `/tp debug` — verbose logging toggle.

## Keybinds

Bind under the `TotemPing` category in the WoW keybindings panel:

- `TOTEMPING_TOGGLE` — master on/off.
- `TOTEMPING_SCAN` — force a scan + notify pass.

## How it works

TotemPing consumes `PLAYER_TOTEM_UPDATE` and reads `GetTotemInfo(1..4)` to learn which totem buffs are currently active. On each scan tick it walks `player` + `party1..party4` and looks for those buffs (`UnitAura` with `caster == "player"` so it doesn't credit another shaman's identical buff). A missing buff is only flagged once it's been missing for `graceSeconds`, and each `(unit, buff)` pair won't re-notify until `notifyCooldownSeconds` have passed.

Non-shamans get a one-time load message and no timers ever run.

## Requested by

deehoc via Discord DM to the OpenClaw bot. Original concept from Omedus.

## Repo

<https://github.com/lemillermicrosoft/TotemPing>
