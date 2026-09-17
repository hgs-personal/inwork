# Architecture

Roblox / Rojo project. Luau source under `src/`, mapped into the DataModel by
`default.project.json`. Fusion v0.3-beta is a git submodule at `vendor/Fusion`.

## Layout and DataModel mapping

| Source | DataModel location | Visibility |
| --- | --- | --- |
| `src/Core` | `ReplicatedStorage.Core` | Shared infrastructure |
| `vendor/Fusion` | `ReplicatedStorage.Core.Fusion` | Shared |
| `src/Modules` | `ReplicatedStorage.Modules` | Shared gameplay logic + data |
| `src/Client` | `ReplicatedStorage.Client` | Client only (by convention) |
| `src/Server` | `ServerScriptService.Server` | Server only (enforced) |
| — | `ReplicatedStorage.Remotes` | Declared statically in the project file |

Requires use string paths: `@game/ReplicatedStorage/...` for cross-tree, `./Sibling`
and `@self/Child` within a folder. Remotes are declared in `default.project.json`
rather than created at runtime, so both sides can `WaitForChild` them without a
creation race. Adding a remote means editing that file.

### The four layers

- **Core** — mechanism with no gameplay opinion. Registries, dispatch, generic helpers.
  Nothing in Core should know what a plane is.
- **Modules** — shared gameplay logic and static data. Runs identically on both sides,
  or holds data both sides read (`PlaneData`, `EngineState`).
- **Client** — input, prediction, effects, GUI. Anything the player sees or drives.
- **Server** — authority, validation, persistence. The only place trust lives.

Per CLAUDE.md, one logical system typically spans 2–3 modules across these layers. The
plane is the worked example: `Server/Plane` (authority), `Client/Plane/Pilot` (input +
flight), `Client/Plane/PlaneReplicator` (effects), `Modules/EngineState` +
`Modules/PlaneData` + `Modules/Propeller` (shared).

## Core infrastructure

### ObjectData (`Core/ObjectData`)

The bridge between Roblox Instances and Luau tables. A map from an Instance to a table
of named relationships:

```
ObjectData.add(instance)                  -- register
ObjectData.relate(instance, key, data)    -- attach a system's object under a key
ObjectData.query(instance, key)           -- retrieve, or nil
ObjectData.unrelate(instance, key)
ObjectData.clear(instance)
```

Per CLAUDE.md this is the *only* sanctioned way to associate Luau state with an
Instance, and the intended home for any future ID system. Do not add a parallel
`planesByModel = {}` table in a new system — relate it here under a new key.

Keys in use today: `"plane"` (server Plane object), `"PlaneReplicator"` (client effects
object). Keys are per-system strings; keep them distinct.

Note the lifetime rule in `Replicator.onRemoved`: when a receiver's key is unrelated and
nothing else remains related, the Instance is dropped from the table entirely. Systems
that relate data outside of Replicator are responsible for their own cleanup.

### Replicator (`Core/Replicator`)

Tag-driven object lifecycle, wrapping `CollectionService`. A system registers a
*receiver* for a tag before startup:

```lua
Replicator.subscribeToTag("plane", {
    added = function(instance) return MyThing.new(instance) end,
    removed = function(instance) ... end,
    objectDataKey = "MyThing",   -- optional; auto-relates added()'s return value
})
```

`Replicator.start()` connects added/removed signals **and replays every already-tagged
instance**, so ordering between tagging and startup doesn't matter. Subscribing after
`start()` asserts. This is the mechanism for "run this code for every X in the world",
and it is how streaming in/out is meant to be handled — objects can be rebuilt on
re-entry, which is why `Pilot:getEffects()` looks its effects object up each time
rather than caching it.

### Lifecycle convention

CLAUDE.md specifies `.init()` for first-pass startup that cannot depend on other modules
being ready, followed by a second pass once everything is constructed. In practice the
client entry point runs:

```
Replicator.init()          -- no-op today; reserved
PlaneReplicator.init()     -- subscribes its tag receiver
Replicator.start()         -- connects + replays
Gui.start(player)
-- then character/seat wiring
```

New systems with world objects follow the same shape: `init()` subscribes and registers,
`start()` activates. Keep all subscription in `init()` so a single `start()` can flush
everything.

## Plane system

### Authority model

This is the most important thing to understand before touching plane code.

- **Flight is client-authoritative.** When a player sits in the `PilotSeat`, the server
  calls `root:SetNetworkOwner(player)`. All aerodynamics, thrust, and rotation are
  computed on that client in `Pilot` and applied through physics constraints. The server
  does not simulate flight and does not currently validate it.
- **Engine state is server-authoritative.** The client can only *request* start/stop over
  the `RequestEngine` remote. The server owns the state machine and the timed transitions.
- **Throttle is client-driven, server-stored.** The pilot sets it locally for immediate
  feel, and pushes it to the server at most every 0.1s (`THROTTLE_SEND_INTERVAL`) for
  replication to other clients.

Implication for future work: anything with economic consequence (fuel burn, cargo
integrity, payout, damage) must **not** be derived from client-reported flight state
without server-side sanity checks. See the Trust boundary section below.

### Replication channel

State reaches other clients through **Instance attributes on the plane model**, not
remotes. Remotes carry *requests*, attributes carry *state*.

| Attribute | Written by | Read by |
| --- | --- | --- |
| `engineState` | Server | Pilot, PlaneReplicator |
| `engineStateTime` | Server (`workspace:GetServerTimeNow()`) | Effects, for sequence sync |
| `throttle` | Server | PlaneReplicator |
| `planeType` | Authoring / server | PlaneReplicator → `PlaneData.index` lookup |

This gives free replication, free late-join state, and free continuity across a pilot
swap — `Pilot:loadState()` reads the attributes so a new pilot picks up where the last
one left off. Prefer extending this pattern over adding remotes.

### Engine state machine (`Modules/EngineState`)

`off → starting → running → stopping → off`, with `START_DURATION = 6s` and
`STOP_DURATION = 4s`. Transitions are server-side `task.delay` guarded by an
incrementing `engineSequenceId`, so an interrupting request supersedes a pending one
(a start can interrupt a spin-down and vice versa). Shared constants live in the module
so client effects and server timing never drift.

### Flight model (`Client/Plane/Pilot`)

Per-Heartbeat. Reads WASD (W/S throttle, A/D ground steer) and mouse position.

- **Aerodynamics** — angle of attack from local velocity, a sinusoidal lift curve peaking
  around `AOA_MAX_LIFT_W = 20°` with a `5°` offset, plus quadratic drag on the local Z
  axis. Returns a force vector applied to a `Thrust` force constraint.
- **Thrust** — `-20000 * throttle` on local Z, gated on `engineState == RUNNING`.
- **Rotation** — currently `ARCADE_ROTATION_MODE = true`: mouse offset from screen
  center drives an `AngularVelocity` constraint directly, with a cubic deadzone and a
  velocity-derived "wind vane" yaw term. Torque is zeroed while on the ground. A
  realistic control-surface mode is the implied alternative; the flag exists for it.
- **Ground state** — hysteresis over wheel-point raycasts plus lift and vertical-velocity
  thresholds. Wheel points come from `QueryDescendants("BasePart#WheelPoints")`.

The plane model must supply: `PrimaryPart`, `PilotSeat`, a `Propellers` folder, and a
`Constraints` folder containing `Thrust`, `GearCylinderRear`, and `AngularVelocity`.

**Tuning constants are scattered through `Pilot`** (`coeffWingArea`, `coeffDragZ`, the
thrust magnitude, `ARCADE_WINDVANE_K`). These are per-plane-type values sitting in
per-pilot code. Moving them into `PlaneData` is the obvious next refactor and a
prerequisite for a second aircraft.

### Effects (`Client/Plane/PlaneReplicator`, `Modules/Propeller`)

Runs on every client for every tagged plane, piloted or not. Strictly read-only with
respect to plane state — it never writes attributes. The local pilot calls
`setLocalThrottle()` to bypass network delay on their own aircraft, and
`clearLocalThrottle()` on teardown hands the display back to the replicated attribute.
Propeller RPM and layered engine sound (start / mid / high with RPM-ratio crossfade) are
driven from `PlaneData.index[planeType].engines`.

`Propeller.modelBuildUp` (server) creates the welds and `Motor6D`;
`Propeller.replicator` (client) spins it and plays sound. Same module, both sides,
different entry points — the CLAUDE.md "shared where possible" pattern.

### Static data (`Modules/PlaneData`)

`PlaneData.index[typeName]` → a data table, registered by explicit require in
`init.luau`. Per Henry's stated preference, new plane types are added by an explicit
`require` + index assignment, never a folder scan. `ModelZData` is the only entry and
currently holds engine/sound config only.

## GUI (`Client/Gui`)

Fusion v0.3-beta, declarative. Intended shape: `Root` holds a registry of *screens*,
each a `{ name, order?, layer?, build(scope, ctx) -> Instance }`. `Root.start()` creates
one session-lifetime Fusion scope, builds every registered screen exactly once, and
parents it into either a primary `ScreenGui` or a named layer. Modules register by
explicit require, matching the PlaneData convention.

Gameplay code drives the HUD imperatively through exported setters on the screen module
(`PilotLayer.setThrottle`, `setYoke`, `show`, `hide`), which write into module-level
Fusion values. This keeps `Pilot` free of any handle on the build scope.

> **Current state: this layer does not run.** See AGENTS.md. `Root` is a partial
> rewrite of a deleted `init.luau`, and its callers still require the old modules.

## Trust boundary (forward-looking)

Nothing here exists yet; this is the intended shape for the trading layer.

Because flight is client-authoritative, the economy cannot read client physics. The
server-side rule should be: **the client reports position and events; the server decides
what they are worth.**

Practical version for a cargo run:

- Server records the contract, origin, destination, cargo, and departure time on pickup.
- Server validates arrival itself — the plane's replicated position near the destination
  airport, on the ground, below a speed threshold — rather than trusting a client
  "landed" event.
- Fuel burn is computed server-side from the replicated `throttle` attribute and elapsed
  time, not from a client-reported total.
- Sanity-check the run: elapsed time against the route's minimum feasible duration at the
  plane's top speed. A run that is impossibly fast is rejected rather than paid out.

This is cheap to do now and expensive to retrofit after payouts exist.

## Where new systems go (proposal)

| System | Placement |
| --- | --- |
| Cargo types, commodity definitions | `Modules/CargoData` — static, both sides read it |
| Airport definitions (position, market, tier) | `Modules/AirportData` |
| Market pricing math | `Modules/Economy` — pure functions, `--!strict`, shared so the client can preview prices |
| Market state + transactions | `Server/Market` — authoritative, owns current prices |
| Player wallet / progression state | `Server/PlayerProfile` — the only writer |
| Persistence (DataStore) | `Server/Persistence` — wrapped, called only by PlayerProfile |
| Contracts / missions | `Server/Contracts`, with shared shape in `Modules/ContractData` |
| Airport world objects | Tag + `Replicator` receiver, same pattern as planes |
| Cargo loading UI, market UI, wallet HUD | `Client/Gui/*Layer`, registered with `Root` |
| Cargo mass affecting flight | `Modules/PlaneData` mass fields + `Pilot` reading loaded mass |

Two rules worth restating from CLAUDE.md, because they bind hardest here: pure math
modules (`Economy`) should be `--!strict` and struct-like; and every Instance↔table
association goes through `ObjectData`.
