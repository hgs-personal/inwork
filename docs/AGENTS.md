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

**Unvalidated as of 2026-09-18**, both written but never run in Studio, since the client
does not start and a two-client play-test wasn't possible:

- `Core/NetTable`. Nothing uses it yet. Exercise it with a throwaway table on both sides
  before building on it.
- Crash detection (`Modules/Impact`), and the destruction path in `Server/Plane`. A crash
  destroys the plane and kills the pilot, so the thing to watch is teardown: no leftover
  heartbeat connections, no errors about destroyed instances, and a character that can
  walk and sit again afterwards. The thresholds in `Impact` and `crashImpactDv` in
  `ModelZData` have never been flown — the acceptance test is that no landing, however
  firm, ever trips one.
- **Plane models need `AirframeParts` tags before any of this runs.** `Impact` asserts on
  finding no part tagged `AirframeParts`, on both sides. Tag the fuselage, wings and tail;
  do not tag the gear or wheels, or landing hard will read as a crash.
- `Modules/PlaneSim`, and the `Server/Plane` wiring that feeds it. The server now applies
  thrust and aerodynamics to every unpiloted plane, which is new behaviour — previously
  nothing moved an unpiloted plane at all. Watch for a parked plane drifting or fighting
  its gear on spawn.
- **Plane models need authoring before any of this runs.** `PlaneSim` asserts on a
  `planeType` attribute and on a `Torque` constraint (with `RelativeTo = Attachment0`)
  under `Constraints`. Neither existed before, and both now fail loudly on the server.
- The torque rotation mode's coefficients in `ModelZData.flight` are a first pass and were
  never flown. If the plane rolls like a brick or spins up uncontrollably, scale
  `kAileron` / `kElevator` / `kRudder` and `kRotDamp` together rather than assuming the
  model is wrong. `ROTATION_MODE = "arcade"` in `PlaneSim` falls back to the old behaviour
  for comparison.

Delete each entry once it is confirmed working.

## Conventions that bite

Beyond CLAUDE.md, things specific to this project that are easy to get wrong:

- **Remotes are declared in `default.project.json`**, not created at runtime. A new
  remote means editing that file, and Studio must re-sync before either side sees it.
- **Never create a second Instance-to-table map.** Use `Core/ObjectData`. This is called
  out explicitly in CLAUDE.md.
- **Subscribe to tags in `init()`, never after `Replicator.start()`** — it asserts.
- **The flight model lives in `Modules/PlaneSim` — but `Client/Plane/Pilot` still has its
  own copy.** Changing lift, drag, thrust or arcade rotation means changing both, until
  `Pilot` is migrated onto the sim. See ARCHITECTURE.md, Flight model.
- **State goes on attributes; remotes carry requests only.** Before adding a remote, ask
  whether an attribute would do. Usually it would. State with no Instance to hang on —
  economy, settings, anything session- or player-scoped — goes in a `Core/NetTable`
  instead of a hand-rolled remote pair. See "NetTable or attributes" in ARCHITECTURE.md.
- **Registration is explicit.** New plane types, new GUI screens: an explicit `require`
  plus an index assignment or `register` call. No folder scanning. This is a stated
  preference, not an accident.
- **Avoid defensive fallbacks.** CLAUDE.md asks for errors to surface rather than be
  papered over. Prefer `assert` with a message naming the offending object over a silent
  `or default`. The existing code does this consistently — follow it.
- **Prefer verbosity over cleverness.** Simplicity is explicitly favoured over concision
  in this codebase.
- **Altitude is region-relative.** Never use `Position.Y` as altitude. Subtract the
  reference Y of the region the entity is currently in, and look it up rather than
  hardcoding it, since planes can change regions. There is only one region today
  (reference Y 0), but code should go through the lookup. See ARCHITECTURE.md, Regions.
- **World-placed entities carry a region ID**, starting with airports. It's bookkeeping
  while there is one region.
- **Follow the system, object, and remote conventions** in ARCHITECTURE.md ("Code
  structure conventions") for new code. Most existing code predates them. Bring a module
  in line only as part of a change that is already touching it, using the Migration list
  there, and update that list when you do.
- **Put utility code in `Core/Util`.** See "Utility code" below.
- **Ask the plane who can fly it.** Pilot authorization goes through `Plane:canPilot(player)`
  on the server. Don't compare against a plane's owner directly anywhere else, and don't
  assume the owner is a player. Crews and NPC planes are deferred. See ARCHITECTURE.md,
  Pilot authorization.
- **Multiple regions are deferred.** Don't implement stacked regions, sharding, or region
  transitions. The analysis is in ARCHITECTURE.md if the decision is revisited.

## Utility code

Generic helpers belong in one place, `Core/Util`, so they get found and reused instead of
rewritten in slightly different forms across modules.

Current contents: `Core/Util/init.luau` returns a `CoreUtil` table with domain namespaces.
Today there is one, `CoreUtil.Parts` (`weldPartsSimple`, `weldModelSimple`,
`makePartsEffectOnly`), used by `Modules/Propeller`.

A helper belongs in `Core/Util` when both of these are true:

- It has no gameplay knowledge. It doesn't know what a plane, cargo, airport, or contract
  is. Examples: vector and angle math, curves and deadzones, welding and part setup, table
  helpers, raycast parameter setup.
- Another system could plausibly use it. It doesn't need a second caller to exist yet.

It does not belong there if it encodes a game rule or game data. Shared gameplay logic,
including shared gameplay math such as the planned `Modules/Economy`, goes in `Modules`.
Core stays free of gameplay concepts (see ARCHITECTURE.md).

How to add to it:

- Search `Core/Util` first. If something close exists, extend or parameterize it instead
  of writing a near-duplicate.
- Put the helper in the matching domain namespace (`CoreUtil.Parts`), or add a new one
  (for example `CoreUtil.Math`).
- When a namespace grows large, move it into its own child module under `Core/Util/` and
  require it explicitly from `init.luau`. No folder scanning.
- Write it as a pure function where possible and type it fully. Utility code is where
  CLAUDE.md most wants `--!strict`. `Core/Util/init.luau` doesn't have it yet; add it the
  first time you touch the file and fix whatever it flags.
- Use tabs. `Core/Util/init.luau` is currently indented with spaces, as are the other Core
  modules, `EngineState`, and `Propeller`. Converting a whole file is its own change, so
  keep new code consistent with the file you're editing until then, and flag it.

Existing duplication: moving code that's already duplicated into `Core/Util` is worthwhile,
but it has to be balanced against keeping diffs focused, because every change is
validated by hand in Studio. If the duplicate is in a file you are already changing, and
migrating it is small, do it in the same change. Otherwise note it and leave it for a
separate change. A known case: `Plane:init` in `Server/Plane` builds its static welds by
hand, which is close to `CoreUtil.Parts.weldModelSimple`. They aren't identical, though:
`Plane:init` parents the welds to the root and unanchors each part, while the util parents
to the part and doesn't unanchor. Migrating would need the util extended first.

## Model authoring requirements

Plane models are authored in Studio, not generated, and code assumes a specific
structure. A plane model needs:

- a `PrimaryPart` (the physics root)
- a `PilotSeat` child, tagged `pilotSeat`
- a `Propellers` folder of propeller models, each with its own `PrimaryPart`
- a `Constraints` folder with `Thrust`, `GearCylinderRear`, and `AngularVelocity`
- parts named/tagged so `QueryDescendants("BasePart#WheelPoints")` finds the wheel points
- a `planeType` attribute matching a key in `PlaneData.index`
- the `plane` tag (currently applied in code by `Server.server.luau` for the single
  pre-placed `ModelZ`; that whole setup is a placeholder for the planned
  `Server/PlaneSpawner`, which will clone and tag owned aircraft)

If a change requires a model edit that you can't make, say so explicitly rather than
working around it in code.

## Scope discipline

This project is one person's game with a clear architectural point of view. The
conventions in CLAUDE.md are deliberate, including the ones that look unusual (explicit
registration, selective strict typing, verbosity over abstraction). Follow them rather
than improving on them. If a convention genuinely blocks the task, raise it — don't
quietly route around it.
