# Nuclear Mud Arena

A 20-player Red vs Blue vehicle-combat game for Roblox: guns, trucks, tanks,
planes, a rideable torpedo, and nuclear diamond bullets that punch through
walls and detonate on the way.

**Everything is free right now.** No weapon, vehicle or perk costs Robux.
Monetization is written and ready but switched off — see the bottom of this file.

## Opening it

1. Install **Roblox Studio** (free, from roblox.com/create).
2. Open `NuclearMudArena.rbxlx` — that is the whole game in one file.
3. Press **Play**.

That file is built from `src/`. If you only want to play with it, you never
need to touch anything else.

## Controls

| Input | Does |
| --- | --- |
| **WASD** | Drive / fly / steer the torpedo |
| **Left mouse** | Fire (hold for automatic guns) |
| **Right mouse** | Zoom, on guns with a scope |
| **R** | Reload |
| **F** | **MEGA-DETONATE** a diamond bullet that is still in the air — 10x blast |
| **1 – 6** | Weapon slots. Press the same number again to cycle within a slot |

Slots: 1 sidearms, 2 automatics, 3 shotguns, 4 snipers, 5 the diamond gun,
6 explosives (grenades, sticky bombs, RPG).

## The vehicles

Cars spawn next to you and get faster as you collect keys — one key per
elimination. The big vehicles sit on marked pads around the map and come back
a while after they are wrecked:

- **Turret truck** — two seats. One player drives, the other works the 50 cal
  on the back.
- **Tank** — slow, very heavy, shrugs off small arms, fires a cannon.
- **Plane** — arcade flight. Throttle with W/S, roll with A/D.
- **Torpedo** — you sit on it like a saddle and steer it into somebody.

## How the code is laid out

```
src/shared/     Config, Remotes, Util, Signal   (both sides use these)
src/server/     The rules. Nothing here can be edited by a player.
src/client/     The screen and the controls. Asks the server for everything.
```

**`src/shared/Config.luau` is the file to edit.** Every gun, vehicle, map and
timing number lives there. Adding a gun is copying a row in `Config.Weapons`
and renaming it — no new code anywhere else.

The server owns every decision that matters: what got hit, who took damage,
what you own. The client only ever *asks*. That is what stops somebody editing
their own copy of the game and giving themselves infinite damage.

## Rebuilding the place file after editing `src/`

You need [Rojo](https://rojo.space):

```sh
rojo build default.project.json -o NuclearMudArena.rbxlx
```

Or `rojo serve` and connect from the Rojo plugin in Studio to sync live while
you edit.

## Turning monetization on later

When the game is good enough to charge for:

1. Create your Game Passes and Developer Products on the Creator Dashboard.
2. Paste their IDs into `Config.GamePasses` and `Config.Products`.
3. Set `Config.FreeMode = false`.

`MonetizationService` is already written to Roblox's rules — one `ProcessReceipt`
handler, receipts recorded before they are confirmed, and a purchase never
granted twice. Nothing else needs changing.

## A note on sound

No audio IDs are baked in anywhere. A wrong Roblox audio ID throws a real error
at runtime, so guessing them would break the game. Every effect is visual; drop
Toolbox sounds in where you want them.
