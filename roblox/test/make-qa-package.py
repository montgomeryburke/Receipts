#!/usr/bin/env python3
"""
Build one self-contained file to hand to an outside model for QA.

A reviewer with no access to this repository cannot clone it, and pasting
eleven thousand lines by hand is not a plan. This writes a single file:
a brief that says what the game is and what to look for, then every line of
source with its path above it.

    python3 test/make-qa-package.py

Writes QA-PACKAGE.md next to the place file. Upload or paste that one file.
"""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))

# Order matters for a reader: config and the shared pieces first, then the
# server's rules, then the client. That is the order the game runs in.
GROUPS = [
    ("Shared — both sides use these", [
        "src/shared/Config.luau",
        "src/shared/Remotes.luau",
        "src/shared/Util.luau",
        "src/shared/Signal.luau",
        "src/shared/Sound.luau",
    ]),
    ("Server — the rules. A player cannot edit any of this.", [
        "src/server/init.server.luau",
        "src/server/modules/PlayerState.luau",
        "src/server/modules/TeamService.luau",
        "src/server/modules/MapService.luau",
        "src/server/modules/VehicleService.luau",
        "src/server/modules/WeaponService.luau",
        "src/server/modules/ProjectileService.luau",
        "src/server/modules/DamageService.luau",
        "src/server/modules/PickupService.luau",
        "src/server/modules/WildlifeService.luau",
        "src/server/modules/CarnivalService.luau",
        "src/server/modules/FlagService.luau",
        "src/server/modules/MatchService.luau",
        "src/server/modules/ScoreboardService.luau",
        "src/server/modules/EffectService.luau",
        "src/server/modules/GraphicsService.luau",
        "src/server/modules/MonetizationService.luau",
    ]),
    ("Client — the screen and the controls. Only ever asks the server.", [
        "src/client/init.client.luau",
        "src/client/modules/Hud.luau",
        "src/client/modules/Controls.luau",
        "src/client/modules/Feel.luau",
        "src/client/modules/Radar.luau",
    ]),
]

BRIEF = """# Nuclear Mud Arena — QA package

You are reviewing a Roblox game written in Luau. Everything below is the
complete source: 11,500 lines across 27 files. There is nothing else.

## What it is

A 20-player Red vs Blue arena shooter built to feel like Halo 1 with trucks
in it. Two modes (Slayer, Capture the Flag) voted on between rounds. Ten
procedurally generated city maps. 22 weapons, cars, two turret trucks, a
tank, a plane, four rideable torpedoes. Roaming zombies, civilians, practice
targets, a carnival with a dunk tank. Monetization is written but switched
off (`Config.FreeMode = true`), so every weapon and vehicle is free.

## How it is meant to be structured

- `src/shared/Config.luau` holds every tunable number. Adding a weapon is
  meant to be copying a row there and nothing else.
- The **server owns every decision that matters** — what was hit, who took
  damage, what a player owns. The client only ever asks. That is what stops
  a player editing their own copy and giving themselves infinite damage.
- The client has no authority at all and is expected to be hostile.

## What I most want checked

Please be specific and adversarial. For each finding give the file, roughly
where, what breaks, and the concrete inputs or sequence that break it.

1. **Exploits.** A player controls their client completely. Can they fire
   faster than the cooldown, shoot from a position they are not in, damage
   somebody through a wall, score points they did not earn, award themselves
   keys or purchases, or crash the server with a malformed remote argument?
   Every `OnServerEvent` handler is an attack surface. Check the argument
   validation on all of them.
2. **Race conditions and lifetime bugs.** Rounds are torn down and rebuilt on
   a loop while players join, leave, die and respawn. Look for state that
   outlives the round that created it, listeners connected per-round that are
   never disconnected, references to destroyed instances, and anything that
   assumes a character or a vehicle still exists after a yield.
3. **Things that will not scale to 20 players.** Per-frame work that is
   linear or worse in players, vehicles or map parts. Network traffic sent
   per-frame or per-player-per-frame.
4. **Correctness bugs you can reason about from the code.** Off-by-one,
   wrong sign, a guard that never fires, a branch that cannot be reached,
   arithmetic on a possibly-nil value, an early `return` that skips cleanup.
5. **Anywhere the code and its own comments disagree.** The comments claim
   specific reasoning. Where a comment is now wrong, that is a bug or a
   stale comment, and both are worth knowing.
6. **Roblox-API misuse.** Constraint properties that do nothing in the mode
   they are set in, network ownership assumptions, `WaitForChild` without a
   timeout on a path that can never resolve, DataStore calls that throw in an
   unpublished place.

## What I do NOT need

Style, formatting, naming, or suggestions to add a framework. It is
typechecked under `--!strict` with `luau-lsp analyze` and that passes clean,
so do not report things the typechecker would already catch.

## Known and deliberate

- Ammo is infinite on purpose (`Config.InfiniteAmmo = true`).
- No numeric audio asset IDs anywhere — every sound is an `rbxasset://`
  engine built-in, deliberately, because a wrong numeric ID is a runtime
  error in a place that has never been published.
- Vehicle wheels are anchored, non-colliding decoration rotated by hand.
  Welded colliding wheels fought the drive constraint.
- `LinearVelocity` has `ForceLimitsEnabled = false` on purpose: in Line mode
  it reads `MaxForce`, not `MaxAxesForce`, and getting that wrong is what
  made vehicles immobile for six iterations.

---
"""


def main():
    out = [BRIEF]

    try:
        head = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=ROOT, capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        if head:
            out.append(f"Reviewing commit `{head}`.\n\n---\n")
    except Exception:
        pass

    total = 0
    for heading, paths in GROUPS:
        out.append(f"\n# {heading}\n")
        for rel in paths:
            full = os.path.join(ROOT, rel)
            if not os.path.exists(full):
                out.append(f"\n## `{rel}`\n\n_missing_\n")
                continue
            with open(full) as handle:
                body = handle.read()
            total += body.count("\n")
            out.append(f"\n## `{rel}`\n\n```lua\n{body}\n```\n")

    out.append(f"\n---\n\nEnd of source: {total} lines.\n")

    target = os.path.join(ROOT, "QA-PACKAGE.md")
    with open(target, "w") as handle:
        handle.write("".join(out))
    print(f"wrote {target} ({os.path.getsize(target) // 1024} KB, {total} lines of source)")


if __name__ == "__main__":
    main()
