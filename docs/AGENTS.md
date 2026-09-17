# Working in this repo

For agents and sessions picking this project up cold.

## Orient in five minutes

Read, in order:

1. `CLAUDE.md` — the binding style rules. Non-negotiable.
2. `docs/ARCHITECTURE.md` — the module map and the authority model.
3. `default.project.json` — the DataModel mapping. Short, and explains every require path.
4. The system you're touching. The plane is the reference implementation of every
   convention in this project; if you need a pattern, copy it from there.

Then check `git status`. This repo is early and often has work in flight.

## Current known-broken state

> Accurate as of 2026-09-16, commit `ac4afa5`. **Verify before trusting it** — if the
> GUI layer now runs, delete this section.

The GUI system is mid-refactor and the client will not start. A previous
`src/Client/Gui/init.luau` and `src/Client/Gui/PilotHud.luau` were deleted and are being
replaced by `Root.luau` / `PilotLayer.luau` / `Types.luau`, which are untracked and
incomplete. Concretely:

- `Client.client.luau` requires `Client/Gui` and calls `Gui.start(player)`. That module
  no longer exists; `Root.luau` is the replacement and exposes `Root.start()` with no
  arguments.
- `Pilot.luau` requires `Client/Gui/PilotHud` and calls `PilotHud.show/hide/setThrottle/setYoke`.
  Those setters now live on `PilotLayer`.
- `Root.luau` references `primaryGui`, `makeScreenGui`, and `getLayer`, none of which are
  defined, and has no `register` function despite `Root`'s own comments and
  `PilotLayer` depending on one. `buildScreenGui` builds an empty children table and is
  never called.
- `Root.start()` does `local player = game:GetService("Players")` and then treats that
  service as the player — it is passed into `ScreenContext.player` and
  `WaitForChild("PlayerGui")` is called on it.
- `Types.luau` declares a `TopGui` / `TopGuiModule` shape that doesn't match the `Screen`
  shape in `Root.luau`. One of the two is stale.

Finishing this refactor is the natural first task for a session touching the client.
Pick one of the two shapes (`Screen` with `build()`, or `TopGuiModule` with `new()`),
delete the other, and update both call sites.

## Validating changes

There is no test suite and no CI. Validation is manual, in Roblox Studio:

1. Sync with Rojo (`rojo serve`, connect from the Studio plugin).
2. Play-test in Studio. For anything touching replication or authority, use
   **Test → Players → 2 Players** — client-authoritative flight and attribute
   replication both behave differently with a real second client.
3. Watch the Output window. The codebase prints liberally at lifecycle boundaries
   (`[PlaneReplicator] new for plane:`, "Starting pilot control", and so on). A silent
   log where you expected one of these usually means an `init()`/`start()` ordering
   problem, not a logic bug.

Because this loop is manual and slow, **be conservative**: prefer changes you can reason
about statically, keep diffs focused, and don't refactor adjacent code opportunistically
while fixing something else. Type-check pressure is the cheap substitute for tests here —
use `--!strict` wherever CLAUDE.md allows it.

Note that `sourcemap.json` is committed; regenerate it (`rojo sourcemap`) if you add or
move files and want editor navigation to keep working.

## Conventions that bite

Beyond CLAUDE.md, things specific to this project that are easy to get wrong:

- **Remotes are declared in `default.project.json`**, not created at runtime. A new
  remote means editing that file, and Studio must re-sync before either side sees it.
- **Never create a second Instance-to-table map.** Use `Core/ObjectData`. This is called
  out explicitly in CLAUDE.md.
- **Subscribe to tags in `init()`, never after `Replicator.start()`** — it asserts.
- **State goes on attributes; remotes carry requests only.** Before adding a remote, ask
  whether an attribute would do. Usually it would.
- **Registration is explicit.** New plane types, new GUI screens: an explicit `require`
  plus an index assignment or `register` call. No folder scanning. This is a stated
  preference, not an accident.
- **Avoid defensive fallbacks.** CLAUDE.md asks for errors to surface rather than be
  papered over. Prefer `assert` with a message naming the offending object over a silent
  `or default`. The existing code does this consistently — follow it.
- **Prefer verbosity over cleverness.** Simplicity is explicitly favoured over concision
  in this codebase.

## Model authoring requirements

Plane models are authored in Studio, not generated, and code assumes a specific
structure. A plane model needs:

- a `PrimaryPart` (the physics root)
- a `PilotSeat` child, tagged `pilotSeat`
- a `Propellers` folder of propeller models, each with its own `PrimaryPart`
- a `Constraints` folder with `Thrust`, `GearCylinderRear`, and `AngularVelocity`
- parts named/tagged so `QueryDescendants("BasePart#WheelPoints")` finds the wheel points
- a `planeType` attribute matching a key in `PlaneData.index`
- the `plane` tag (currently applied in code by `Server.server.luau` for `ModelZ`; this
  is a temporary shim and should move to Studio authoring)

If a change requires a model edit that you can't make, say so explicitly rather than
working around it in code.

## Scope discipline

This project is one person's game with a clear architectural point of view. The
conventions in CLAUDE.md are deliberate, including the ones that look unusual (explicit
registration, selective strict typing, verbosity over abstraction). Follow them rather
than improving on them. If a convention genuinely blocks the task, raise it — don't
quietly route around it.
