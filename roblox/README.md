# Nuclear Mud Arena

A 20-player Red vs Blue arena shooter for Roblox, built to feel like Halo 1
with trucks in it: 22 weapons, tanks, planes, rideable torpedoes, a motion
tracker, Slayer and Capture the Flag, and nuclear diamond bullets that punch
through walls and detonate on the way through.

**Everything is free right now.** No weapon, vehicle or perk costs Robux.
Monetization is written and ready but switched off — see the bottom of this file.

## Opening it

1. Install **Roblox Studio** (free, from roblox.com/create).
2. Open `NuclearMudArena.rbxlx` — that is the whole game in one file.
3. Press **Play**.

That file is built from `src/`. If you only want to play with it, you never
need to touch anything else.

## The two game modes

Between rounds everyone votes, and each option pairs a map with a mode.

**Slayer** — shoot everything that moves. Every weapon is worth its own
points: 10 for a pistol round, 30 for a sniper, 35 for the anti-truck rifle,
5 for poop. Zombies, civilians and practice targets all score too. The team
with the most points at the final whistle wins.

**Capture the Flag** — Halo's rules. Take the enemy flag back to your own
stand. Dying drops it where you fell; a dropped flag goes home on its own
after 25 seconds, or instantly if a defender touches it. **You cannot score
unless your own flag is on its stand.** Carrying slows you down, so a runner
can be caught. A capture is worth 500 points, which dwarfs any kill.

The line at the top of the screen shows where both flags are at all times.
Hold **Tab** for the full scoreboard.

## The carnival

One corner of every map is a fairground, for when you want a break:

- **Dunk tank** — one player takes the seat, anyone else shoots the target
  beside it, and the sitter drops into the water.
- **Shooting gallery** — three rows of ducks sliding back and forth. Hit one
  and it tips over backwards.
- **High striker** — shoot the pad and the puck rides up the tower to ring
  the bell.

All of it scores points.

## Controls

| Input | Does |
| --- | --- |
| **WASD** | Move, drive, fly, steer the torpedo |
| **Mouse** | Look. You aim where the cursor points and your body turns to follow |
| **Left mouse** | Fire — hold it down. Every gun is automatic except a scoped sniper, which is one shot at a time |
| **Right mouse** | Step the scope up a magnification, then back to hipfire |
| **1 – 7** | Weapon slots. Press the same number again to cycle within a slot |
| **G** | **Throw a grenade** — without putting your gun away |
| **R** | Reload |
| **Q** | Melee — lethal from behind |
| **F** | **MEGA-DETONATE** a diamond bullet that is still in the air — 10x blast |
| **Left Shift** | **Turbo** — faster in a vehicle, sprint on foot |
| **E** | Get into a vehicle (walk up to it first) |
| **Space** | Bail out of anything you are riding — a parachute opens |
| **Tab** | **Scoreboard**, held down |

Slots: 1 sidearms, 2 automatics, 3 shotguns, 4 snipers, 5 the diamond gun,
6 explosives (grenades, sticky bombs, RPG), 7 scavenged gear (poop, the
hunter drone).

`G` is worth knowing about. It is Halo's grenade button: it throws where you
are aiming without changing what is in your hands, so you can throw one
mid-fight and still have your rifle. It works even if a weapon pickup has
taken the grenade out of your loadout.

### On a phone or tablet

Everything above has an on-screen button, because there is no number row, no
G and no Tab on glass:

| Button | Does |
| --- | --- |
| **FIRE** | Hold to shoot |
| **GUN ▶** | Step through every weapon you can carry |
| **NADE** | Throw a grenade |
| **MEGA** | Mega-detonate |
| **GAS** / **BRAKE** | Drive |
| **TURBO** | Turbo |
| **BAIL** | Get out of a vehicle, parachute open |
| **SCORE** | Scoreboard — tapped to toggle, not held |

Aiming also auto-locks onto the nearest target in front of you on a touch
device, which it does not do on a mouse.

## What is on screen

**The motion tracker**, bottom left, is Halo's. You are the centre and the
dial is oriented to where you are *looking*, not to north, so turning round
swings the contacts with you. Enemies are red and team-mates yellow — fixed
colours, not team colours, so the dial still reads when your own team is the
red one. A contact above you sits lighter and below you darker, and anything
too far above or below drops off the dial entirely.

Range is deliberately short. It is there so nobody walks up behind you, not
so you can stop looking.

**The camera reacts.** Each weapon has its own kick, from a buzz on the
minigun to a shove on the anti-truck rifle; explosions shake the view harder
the closer they are; taking a hit flinches; a long fall lands hard. None of
it moves your aim, only the camera.

**Health runs red from the edges** below a third, harder the closer you are
to dying.

## The maps

Ten of them, 1150 to 1500 studs across, and all built the same way: **the
street grid is laid first and everything else is fitted into the blocks it
leaves.** That order is the whole difference between a city and a field with
buildings dropped on it.

Each block gets a job:

- **Towers** take a whole block, because the vehicle ramp wraps the outside.
  You can drive a truck up one and off the roof.
- **Row blocks** hold two low buildings you enter on foot, with a gap between
  them you can run down but not drive through. This is how a map reaches
  thirty-odd buildings without shrinking the blocks until trucks cannot turn.
- **Plazas** are paved and open, with cover to fight around.
- **Mud yards** are the open ground. A city of nothing but buildings has no
  firefights in it, only corridors.

Jumps, ramps and pavement cover sit **on** the roads, pointed along them,
because a jump you cannot reach at speed is scenery. Vehicles and pickups
spawn at junctions, which is where you look for a vehicle in a city. Sky
bridges connect genuinely adjacent rooftops, so the roofs are a second level
you can cross rather than a set of islands.

One corner is the carnival, kept clear of buildings. Each team's way out of
its own base is kept clear too.

The map test checks the two things that make this work: that the configured
number of buildings actually got built, and that **nothing solid stands in a
road**. Both of those failed the first time they were written.

## The vehicles

**Walk up to any vehicle and press E to get in.** Every vehicle carries a
floating name readable from across the map, so you can see what is where. The
seat sits on the roof of the chassis, well above jumping height, so E is the
way aboard — there is nothing to climb.

A car spawns beside you every time you respawn: a truck or a Lamborghini,
chosen at random. Cars get faster as you collect keys, one key per
elimination.

These are always somewhere on the map, on marked pads at junctions, and come
back on the same pads a while after they are wrecked:

| Vehicle | How many | What it is |
| --- | --- | --- |
| **Turret truck** | two | Two seats. One drives, the other works the 50 cal on the back. |
| **Tank** | one | Slow, very heavy, shrugs off small arms, fires a cannon. |
| **Plane** | one | Arcade flight. Throttle with W/S, roll with A/D. |
| **Rideable torpedo** | four | You sit on it like a saddle and steer it into somebody. Space to bail, parachute opens. |

**Hold Left Shift for turbo** in any of them. Boost chevrons painted on the
road run you up to a jump; they push you forward along the ground rather than
launching you, so the jump beyond is what gets you the air.

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

## Testing

```sh
./test/run-all.sh
```

Six suites, all runnable from a terminal with no Roblox Studio anywhere near
them. They run the **real** game modules against stand-ins for the Roblox API
under the plain Luau interpreter.

| Suite | Answers |
| --- | --- |
| `run-sanitytest.py` | Are the numbers in Config sane? Every weapon scored, every sound real, every map buildable on paper. |
| `run-maptest.py` | Do all ten maps generate — with ground, spawns, the configured number of buildings, and **nothing standing in a road**? |
| `run-servertest.py` | Does opening the place produce a world? Runs the published and unpublished cases, plus medals, the kill feed, the scoreboard and the zombies. |
| `run-clienttest.py` | Does input get wired up even when the server is dead? Plus the camera kick, the motion tracker geometry and every touch button. |
| `run-drivetest.py` | Does a car actually move, reverse, boost and steer — and stay on the ground? |
| `run-shoottest.py` | Does pulling the trigger produce a shot? Plus the grenade key, melee, poop, drones, CTF and the carnival. |

Every one of them exists because something was broken and typechecking could
not see it. `luau-lsp analyze` proves the code is well formed; it has never
once proved the code *runs*. The suites are the part that does.

A thing worth knowing about the harness: when a test fails, suspect the
harness first. Roughly half the failures in these suites turned out to be
holes in the stand-ins — a `typeof` that called a Vector3 a table, a
`task.spawn` that dropped its arguments, a `UDim2` that returned an empty
table so no layout could ever be checked, a clock that never advanced. Each
of those was hiding real behaviour rather than reporting it.

What they cannot do is tell you whether any of it is *fun*, or prove that
Roblox's physics engine behaves the way its documentation says. Those last
miles still need a human pressing W.

## The two cases that matter most

```sh
python3 test/run-servertest.py                   > /tmp/a.luau && luau /tmp/a.luau
python3 test/run-servertest.py --block-datastore > /tmp/b.luau && luau /tmp/b.luau
```

Both must print `ARENA: true`. The second simulates an **unpublished** place,
where Roblox refuses DataStore access. That exact case once killed the server
script before it built the arena, and players fell through an empty sky with
no clue why. It is now a test.

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

The game has 31 sounds and they are all **engine built-ins** — `rbxasset://`
paths that ship with Roblox. Not one numeric asset ID appears anywhere.

That is deliberate. A numeric audio ID can be wrong, can be moderated, or can
simply fail to load, and in a place that has never been published a wrong one
is a runtime error rather than a silent miss. The built-ins cannot be wrong:
they are part of the engine. `src/shared/Sound.luau` is the only place that
plays anything, and `test/run-sanitytest.py` fails the build if a sound the
code asks for does not exist, or if any entry is not an `rbxasset://` path.

Swap in Toolbox audio later if you want — change the paths in
`Config.Sounds` and nothing else.
