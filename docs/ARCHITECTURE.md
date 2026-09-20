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
flight), `Client/Plane/PlaneReplicator` (effects), `Modules/PlaneSim` (the flight model
itself, run by both sides) + `Modules/EngineState` + `Modules/PlaneData` +
`Modules/Propeller` (shared).

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

### NetTable (`Core/NetTable`)

Named, flat Luau tables replicated between the server and every client over remotes. Keys
are strings or numbers, values are scalars; nested tables assert. Dictionaries and arrays
both work, since an array is just number keys. One level only — that is the whole scope
for now.

The server owns every table. Clients hold mirrors, and may write only to a table the
server marked `clientWritable`.

```lua
-- server
local settings = NetTable.new("settings")
settings.clientWritable = true
settings:activate()             -- publishes it: registers the name and syncs to clients
settings:set("maxCargo", 12)
settings:setMany({ a = 1, b = 2 })   -- one replicated change
settings:remove("a")                 -- clears a key; leaves a hole in an array

-- array operations. new() is server only, but the operations work from either side
local queue = NetTable.new("queue")
queue:append("c")
queue:insert(1, "a")                 -- shifts everything up
queue:removeAt(2)                    -- shifts everything down
queue:length()

-- either side
local settings = NetTable.find("settings")   -- nil if it has not replicated yet
settings:get("maxCargo")
settings:snapshot()                          -- copy of the whole table
local disconnect = settings:onChanged(function(key, value) end)  -- value nil = removed

-- client startup, since a table arrives some time after the client starts
NetTable.onAdded(function(netTable) end)     -- also replays tables that already exist
NetTable.onRemoved(function(netTable) end)
```

It is a class (`new`/`activate`/`destroy`) and a system (`init`/`start`) in one module, on
both sides. The module-level lookup is `NetTable.find(name)`, not `get`, because
`netTable:get(key)` is the object method and the `__index` pattern gives the two one
table.

Four design points worth knowing before changing it:

- **A client's `set` does not touch its own copy.** It sends the write and waits for the
  change to arrive back through the normal sync. The contents have exactly one authority,
  and a rejected write can never leave a client disagreeing with the server. The cost is a
  round trip before the client sees its own write.
- **Clients ask for a snapshot at startup.** `NetTable.start()` on the client fires
  `Request`, because tables published before that client connected its handler would
  otherwise be missed. `applyChange` skips keys whose value is unchanged, so the snapshot
  racing a live sync fires no duplicate change events.
- **`clientWritable` is not replicated.** It is read only on the server; the field on a
  mirror is always false.
- **Array operations send the operation, not its consequences.** `removeAt(3)` on a
  200-entry array is one small packet, not 198 index writes. Locally it still expands into
  a changed event per shifted index, so a listener keyed on index stays correct and nothing
  is silently missed — the compaction is a wire optimization, not a change in local
  semantics. If a consumer ever needs the structural form (to move a UI row rather than
  rebuild the rows above it), that is a second listener channel, added then.

Remotes live under `Remotes/NetTable`: `Sync` (server → client), `Push` and `Request`
(client → server). Every change travels as a single Change table on a single remote, which
is what keeps writes and array operations ordered relative to each other:

```
{ kind = "write",    set = {...}?, removed = {...}? }
{ kind = "insert",   index = n, value = v }
{ kind = "removeAt", index = n }
{ kind = "append",   value = v }        -- client -> server only
```

A `Sync` with no change means the table was destroyed. `append` exists only on the push
path: a client's mirror may be shorter than the server's array, so the client sends no
index and the server resolves one against its own length, replicating the result as an
ordinary `insert`. A client-supplied `insert` or `removeAt` index *is* honoured, and is
rejected rather than clamped when it is past the end.

The `Push` handler follows the validate / resolve / authorize / act shape below, with
`clientWritable` as the whole authorization rule — there is no per-player ownership yet.
Adding it is the obvious next step if any table becomes economically meaningful.

### NetTable or attributes

Both replicate state, and the plane already uses attributes (see Replication channel).
They are not interchangeable:

- **Attributes** are per-Instance and stream with the Instance. State that belongs to a
  thing in the world stays on attributes: it gets free late-join, free continuity across a
  pilot swap, and it is visible in Studio.
- **NetTable** is for state with no Instance to hang on — session or player-scoped data
  such as economy, market prices, or settings — and for anything a client needs to write.
  Attributes only replicate server → client; a client writing one stays local.

## Code structure conventions

Conventions for systems, objects, and remotes. New code follows them. Most existing code
was written before them; the Migration subsection at the end lists where it differs.
Existing modules are brought in line when a change is already touching them, not in a
bulk refactor.

### Module shape

A **system** is session-lifetime work: it has `init()` and `start()` and exists as long as
the server or client does. Examples: `Replicator`, the GUI root, and later `Market`,
`PlayerProfile`, `PlaneSpawner`.

A **class** creates **objects**, one per thing in the world, each with
`new`/`activate`/`destroy`. Examples: `Plane`, `PlaneReplicator`, a pilot control, a
propeller.

One module can be both, and usually should be when the session-level work belongs to the
class's concept. `Server/Plane` is the plane class and also owns the plane remotes and the
lookup from model to plane. `PlaneReplicator` is the effects class and also subscribes the
tag receiver that creates the effects. Keeping these together means one module per
concept, with no separate manager module to keep in sync.

Class modules use the standard `Class.__index = Class` pattern, so module-level functions
and object methods share one table. The lifecycle names are chosen so they never collide:
systems use `init` and `start`, and objects use `activate` and `destroy`.

```lua
local Plane = {}
Plane.__index = Plane

-- class --

function Plane.new(model)
	local self = setmetatable({}, Plane)
	self.model = model
	return self
end

function Plane:activate()
end

function Plane:destroy()
end

-- system --

function Plane.init()
end

function Plane.start()
end

function Plane.get(model)
	return ObjectData.query(model, OBJECT_DATA_KEY)
end

return Plane
```

Because of the shared table, objects can reach the module-level functions through
`__index`. Object methods must therefore never reuse the names of module-level functions:
`init`, `start`, `new`, `get`, or any other static a module defines. A mistaken
`plane:start()` calls the system `start`, which asserts that it runs only once, so that
mistake throws rather than failing silently. Modules that are only systems (`Replicator`,
`Market`) work the same way, without the class half.

Modules are named for their concept (`Plane`, `Market`), with no role suffix. Whether a
module is a system, a class, or both is visible from the functions it defines.

### System lifecycle

Every system exposes both lifecycle functions, even when one is empty, so entry scripts
can treat all systems the same way.

- `init()` is the first pass. It sets up the system's own state and makes registrations
  with Core systems that accept them before startup, such as `Replicator.subscribeToTag`
  and GUI screen registration. It must not otherwise call into other systems, since they
  may not be initialized yet. It must not yield.
- `start()` is the second pass, run after every system's `init()`. It connects remotes and
  signals, starts loops, and may call any other system. It should not yield. If it needs
  to wait for something, it spawns a thread.

Each asserts that it runs once, and `start` asserts that `init` already ran. Systems have
no `destroy`; they live as long as the server or client does.

Entry scripts (`Server.server.luau`, `Client.client.luau`) contain nothing but the system
list and the two loops:

```lua
local PlaneReplicator = require("@game/ReplicatedStorage/Client/Plane/PlaneReplicator")
local Pilot = require("@game/ReplicatedStorage/Client/Plane/Pilot")
local Gui = require("@game/ReplicatedStorage/Client/Gui/Root")
local Replicator = require("@game/ReplicatedStorage/Core/Replicator")

-- start order. Replicator goes last: starting it creates objects for every instance that
-- is already tagged, and those objects may use any other system.
local systems = {
	PlaneReplicator,
	Pilot,
	Gui,
	Replicator,
}

for _, system in systems do
	system.init()
end

for _, system in systems do
	system.start()
end
```

The list is written out explicitly, with no folder scanning, and its order is the start
order. Any ordering dependency besides `Replicator` going last gets a comment on that
entry. Game logic in the entry scripts today (client seat tracking, the server's test
plane setup) moves into the system functions of the module it belongs to.

### Object lifecycle

Per-instance objects all have the same shape:

- `Class.new(...)` only constructs. It reads and asserts its inputs and sets fields. It does
  not connect signals, create or change Instances, or register with ObjectData.
- `object:activate()` brings the object to life. It connects signals, builds welds and other
  Instances, and begins per-frame updates. It is called once.
- `object:destroy()` undoes everything `activate` did: it disconnects connections and
  destroys the Instances `activate` created. It is called once, after `activate`.

Further rules:

- The constructor is always named `new`.
- Methods are defined on the class table (`function Plane:activate()`), never as closures
  created inside the constructor.
- Connections made in `activate` are appended to a `self.connections` array, and `destroy`
  disconnects everything in it. This keeps `destroy` from missing one.
- Exactly one owner creates, activates, and destroys a given object. The owner is either a
  system or `Replicator`, through a tag receiver whose `added` calls `new` then `activate` and
  returns the object, and whose `removed` calls `destroy`.
- The owner registers the object with ObjectData, not the object itself. Tag receivers get
  this from `Replicator` through `objectDataKey`. A system relates the object explicitly
  after calling `activate`. Because the owner chose the key, lookups by Instance (`get(model)`)
  live with the owner. Usually that is the class's own module (`Plane.get`).
- Per CLAUDE.md, class modules are not strictly typed.

### Remotes

**Declaration.** Remotes stay declared in `default.project.json`, grouped in one folder per
owning system: `Remotes/Plane/RequestEngine` rather than `Remotes/RequestEngine`. Each
remote is used in one direction only. The project file can't hold comments, so the owning
system lists its remotes in its header comment, with direction and argument types.

State reaches clients through attributes (see Replication channel below). Server-to-client
remotes are only for one-off events that aren't state.

**Server handlers.** The owning system connects its remotes in `start()`. Every handler
performs the same four steps, in this order, and returns at the first one that fails:

1. **Validate the arguments.** The client is untrusted, so check every argument: `typeof`,
   NaN and infinity for numbers, membership for enum strings such as `EngineState.Request`,
   and `typeof(x) == "Instance"` before calling any Instance method on it.
2. **Resolve the target object** through the owning system's ObjectData lookup.
3. **Authorize** the player against that object. For plane controls this is
   `player == plane.pilot`. For taking the pilot seat it is `plane:canPilot(player)` (see
   Pilot authorization).
4. **Act** by calling a method on the object with the validated arguments.

```lua
function Plane.start()
	-- ...
	remotes.SetThrottle.OnServerEvent:Connect(function(player, model, throttle)
		-- validate
		if typeof(model) ~= "Instance" or not Validate.isFiniteNumber(throttle) then
			return
		end
		-- resolve
		local plane = Plane.get(model)
		if not plane then
			return
		end
		-- authorize
		if player ~= plane.pilot then
			return
		end
		-- act
		plane:setThrottle(throttle)
	end)
end
```

(`Validate.isFiniteNumber` is illustrative; no validation helpers exist yet.)

Object methods called by handlers assume their input is already validated and authorized.
They enforce game rules, such as which engine transitions are legal, but they don't
recheck argument types or permissions.

Returning quietly from steps 1–3 is deliberate, and it is the exception to CLAUDE.md's rule
against fallbacks. That rule is about not hiding mistakes in our own code. Remote
arguments are external input, and a malformed request from a client must not throw on
the server.

Validation helpers are generic, so they go in `Core/Util` (for example a `CoreUtil.Validate`
namespace), following the utility code rule in AGENTS.md.

**Rate limits.** Clients throttle continuous input before sending it, as `Pilot` already
does with throttle (at most every 0.1s). Any remote that triggers expensive server work or
has an economic effect also gets a server-side rate limit, since the client-side limit
can't be trusted.

**Client side.** Client modules resolve the remotes they use with `WaitForChild` at module
load, as they do now.

### Migration

Where existing code differs from the conventions above, as of commit `ac4afa5`:

- **`Server/Plane`** has `Plane.initNetworking` instead of `Plane.init`/`Plane.start`, and
  the object registers itself with ObjectData inside its `init` method. Replace
  `initNetworking` with the system functions (handlers connect in `Plane.start`), rename
  the object's `init` method to `activate`, and move ObjectData registration to the code that
  creates the plane. The rename has to come first: a module-level `Plane.start` cannot be
  added while the object still has an `init` method, since the two would collide. Move the
  pilot check and the throttle type and NaN check out of `requestEngine` and `setThrottle`
  into the handlers. `destroy` now exists.
- **`Server.server.luau`** builds the test plane inline, and respawns it after a crash.
  Both move into `PlaneSpawner` when it exists.
- **`Client/Plane/PlaneReplicator`** has `init` (subscribing the tag receiver) but no
  `start`. Add an empty `start`. Its objects use `start` where `activate` is now expected;
  rename the method and the call in the tag receiver. Once the system `start` exists, the
  old object method would collide with it.
- **`Client/Plane/Pilot`** uses `newControl` instead of `new`, defines `start` and `destroy`
  as closures inside the constructor (these become `activate` and `destroy` methods), and
  connects `engineStateConn` in the constructor.
- **`Client.client.luau`** holds the seat-tracking session state. That moves into
  `Pilot.init`/`Pilot.start`, since seat tracking is what creates pilot controls. The entry
  script becomes just the system list.
- **`Client/Gui/Root`** has `start` only. Screen registration belongs in `init`. This should
  be settled as part of finishing the GUI refactor described in AGENTS.md.
- **`Modules/Propeller`** names its client constructor `replicator`, creates sound
  Instances in that constructor, and has an empty `destroy`, so those sounds are never
  cleaned up.
- **`default.project.json`** declares `RequestEngine` and `SetThrottle` directly under
  `Remotes`. They move to `Remotes/Plane/`.
- **`Core/Replicator`** already has `init` and `start` and needs no change.
- **`Client/Plane/Pilot`** duplicates the flight model that now lives in
  `Modules/PlaneSim`. It should become an input source: read WASD and the mouse, call
  `PlaneSim.setPrimaryFlightControls`, and delete its own `updateAerodynamics`,
  `updateOnGround` and `updateRotationArcadeMode`. Until then the two copies are tuned by
  hand in parallel. See Flight model.
- **`Modules/PlaneSim`** takes `multi` on `start` and `activate`, where the convention says
  `start()` takes no arguments. That is deliberate for now — it is the flag that separates
  the server's batch loop from a client driving one sim itself — but it means `PlaneSim`
  cannot go in a plain system list.

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
| `crashed` | Server | Pilot (stops flying), crash effects |
| `crashTime` | Server (`workspace:GetServerTimeNow()`) | Effects, for sequence sync |
| `crashImpact` | Server | Nothing yet; the hook a repair cost would price |

This gives free replication, free late-join state, and free continuity across a pilot
swap — `Pilot:loadState()` reads the attributes so a new pilot picks up where the last
one left off. Prefer extending this pattern over adding remotes.

### Engine state machine (`Modules/EngineState`)

`off → starting → running → stopping → off`, with `START_DURATION = 6s` and
`STOP_DURATION = 4s`. Transitions are server-side `task.delay` guarded by an
incrementing `engineSequenceId`, so an interrupting request supersedes a pending one
(a start can interrupt a spin-down and vice versa). Shared constants live in the module
so client effects and server timing never drift.

### Flight model (`Modules/PlaneSim`, `Client/Plane/Pilot`)

The flight model exists **twice** right now, and that is the single most important thing
to know before touching either copy.

`Modules/PlaneSim` is the shared, side-agnostic version, and is where changes belong.
`Client/Plane/Pilot` still carries its own older copy of the same equations, because the
pilot was deliberately left alone when `PlaneSim` was built. **Tuning one does not tune the
other.** Until `Pilot` is moved onto `PlaneSim`, any change to lift, drag, thrust or the
arcade rotation has to be made in both files or the server and the pilot will disagree
about how the same aircraft flies.

Migrating `Pilot` onto `PlaneSim` is the next step: it becomes an input source that reads
WASD and the mouse, calls `setPrimaryFlightControls`, and lets the sim do the physics. Its
own aerodynamics, ground state and rotation functions are then deleted.

#### `Modules/PlaneSim`

A struct plus free functions (`PlaneSim.heartbeat(self, dt)`), not an OOP object, so the
whole component is visible in the `PlaneSim` type at the top of the file. It owns no
Instances — it reads a model's constraints and writes forces to them.

`controlling` decides whether a sim writes anything. Both sides run the full model every
heartbeat, so the sensing fields (`v`, `vLoc`, `v2`, `liftWingNorm`, `onGround`) are
always current, but only the controlling side writes to a constraint. Because flight is
client-authoritative, the two sides deliberately disagree for a given plane:

| | server sim | pilot's client sim |
| --- | --- | --- |
| unpiloted | controlling | not controlling |
| piloted | not controlling | controlling |

That flag is what keeps the server from fighting a pilot's physics. `Server/Plane` flips it
in `setSimControlling`, from the same `PilotSeat.Occupant` handler that grants network
ownership. Nothing is written on the way out: the server clearing a constraint the pilot is
driving would replicate over the pilot's own value.

Inputs arrive through `setPrimaryFlightControls(self, throttle, yoke, rudder)` and
`setEngineState`. The sim never reads an attribute or a remote itself, so it has no opinion
about where state lives — `Server/Plane` pushes engine state in from `writeEngineState` and
throttle in from `setThrottle`. `yoke` is pitch/roll in -1..1 and `rudder` is ground steer
in -1..1, so a mouse, a gamepad or an autopilot can all drive it. The server passes zero for
both, since nothing there steers a plane yet.

Sims are batch updated: `PlaneSim.start(true)` connects one Heartbeat that walks every
registered sim, and `PlaneSim.activate(self, true)` registers one. A client flying a single
plane would pass `false` and drive `heartbeat` itself. `destroy` sets `kill`, and the batch
loop drops killed sims at the end of the cycle rather than mutating the array mid-walk.

**Rotation has two modes**, picked by the module-level `ROTATION_MODE` constant and
mutually exclusive: each writes only its own constraint and zeroes the other's authority,
so they can never fight. `"torque"` is the current default.

- `"arcade"` — what `Pilot` does today. The yoke asks an `AngularVelocity` constraint for a
  rotation rate and gets it, whatever the airspeed.
- `"torque"` — virtual ailerons, elevators and a rudder driving a `Torque` constraint.
  Surface deflection is tied linearly to its input (a yoke of 0.5 is half deflection for
  half the moment), which is the cartoony half. The realistic half is that every moment
  scales with dynamic pressure `q = 1/2 rho v²`, so control authority climbs with the
  square of airspeed: full deflection does almost nothing at taxi speed, and a plane that
  slows to nothing stops answering the controls.

  Three moments are summed, all proportional to `q`:

  | term | axis | source |
  | --- | --- | --- |
  | control | all three | `kElevator` × yoke Y, `kAileron` × yoke X, `kRudder` × rudder |
  | orientational drag | all three | `-kRotDamp` × the plane's current angular velocity |
  | weathervane | yaw | `-kWeathervane` × sideslip angle |

  The drag term is what makes rates settle instead of integrating, and what stops a pulse
  of elevator leaving the plane tumbling. Being proportional to `q` it fades with airspeed
  too, so a slow plane feels loose. The weathervane term is the only source of directional
  stability in the model — without it the plane will happily fly sideways.

  Total moment is clamped by `TORQUE_CLAMP` so a dive cannot produce an absurd one, and
  control moment is cut on the ground so the gear steers instead, matching arcade mode.

#### `Client/Plane/Pilot`

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

The plane model must supply: `PrimaryPart`, `PilotSeat`, a `Propellers` folder, a
`Constraints` folder containing `Thrust`, `GearCylinderRear`, `AngularVelocity` and
`Torque`, and a `planeType` attribute. The `Torque` constraint is new, and `PlaneSim`
additionally asserts that its `RelativeTo` is `Attachment0`, since the torque mode builds
its moment in the root's object space. `PlaneSim` asserts on `planeType` exactly as `PlaneReplicator`
already does, so an unauthored model now fails on the server too, not just on clients.

**Tuning constants have moved into `PlaneData`** for the shared sim:
`PlaneData.index[planeType].flight` holds `kWingArea`, `kDragZ` and `maxThrust`, plus the
torque mode's `kElevator`, `kAileron`, `kRudder`, `kRotDamp` and `kWeathervane`, read by
`PlaneSim.new`. **The rotation coefficients are a first pass and have not been tuned
against this airframe's mass or inertia** — they were picked to be in a plausible ratio to
each other. Expect to scale them once the plane flies. `Pilot` still has its own hardcoded `coeffWingArea`, `coeffDragZ` and
thrust magnitude, and they are currently the same numbers by hand. The remaining arcade
constants (`ARCADE_WINDVANE_K` and friends) are still module-level in both files, on the
assumption that arcade feel is global rather than per-aircraft; move them into `flight` if
that turns out to be wrong.

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
`require` + index assignment, never a folder scan. `ModelZData` is the only entry, and
holds `engines` (effects and sound config, read by `PlaneReplicator`) and `flight` (the
flight model tuning, read by `PlaneSim` — lift, drag, thrust, and the torque mode's
rotation coefficients).

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

## Persistence and aircraft ownership

Decided in DESIGN.md, not built yet.

Persistence is hybrid. Player progress (money, owned aircraft, reputation, ratings, any
contract in progress) is saved through DataStore. World state (market prices, parked
plane positions, weather) is per-server and in-memory only. `Server/PlayerProfile` is the
only module that reads or writes saved data, and `Server/Market` never touches a
DataStore.

Aircraft are owned and spawned on request. A server-side spawner clones the model for a
plane type at an airport, constructs the `Plane` object, and records the owner. The plane
despawns when its owner leaves. This affects existing code:

- `Server.server.luau` looks up one pre-placed `ModelZ` and starts it. That is a
  placeholder, and the spawner replaces it.
- `Plane:initPiloting` gives network ownership to whoever sits in the pilot seat. It
  needs the authorization check described below.
- `Plane` needs an owner field, set by the spawner at construction.

### Pilot authorization

Decided: only a plane's owner can fly it. NPC planes and crews are expected later and are
not being built. The design below keeps them from requiring changes at call sites.

**Owner is data on the server `Plane` object**, and it is not assumed to be a player:

```lua
-- in Server/Plane
type Owner =
    { kind: "player", userId: number }
  | { kind: "npc", npcId: string }
```

Store the `UserId` rather than the `Player` instance. It is what the saved profile uses,
it compares cheaply, and it doesn't hold an Instance reference. Only the `"player"` kind
is needed now. The union is there so that NPC ownership doesn't get implemented as a
special-case `nil` owner.

**Calling code asks the plane; it never inspects the owner.** One method holds the rule:

```lua
function Plane:canPilot(player: Player): boolean
```

Today it returns true when the owner is a player with a matching `UserId`, and false
otherwise (so no player can fly an NPC plane). Adding crews should mean changing only
this method's body, plus whatever supplies crew membership. Whether a crew becomes a new
owner kind or a separate permission list can be decided then, since both fit behind
`canPilot`.

Where the check is used:

- **Seat occupancy.** When the pilot seat's occupant changes, the server calls
  `canPilot`. If it returns false, the server unseats the character and does not grant
  network ownership. The server is the authority here. Client-side checks are only for UX.
- **Not the per-request remote handlers.** `requestEngine` and `setThrottle` already
  compare the sender against `self.pilot`, the player currently flying. That is the
  correct check for those, because the player was authorized when they took the seat.
  Don't add `canPilot` calls to them.

**The client should react to a granted pilot, not to sitting down.** Today
`Client.client.luau` starts `Pilot` control whenever the local character sits in any seat
tagged `pilotSeat`. With authorization, a non-owner would briefly start control before the
server unseats them. It would also mean the client would need to know the rule, which
breaks as soon as crews exist. Instead, the server should write the accepted pilot to a
plane attribute (for example `pilotUserId`), and the client should start control when that
attribute matches the local player. The rule then lives only on the server, and the
client doesn't change when crews are added. This also follows the existing convention
that attributes carry state.

**NPC planes need more than an owner kind.** Keep these in mind before building them:

- The flight model lives only on the client, in `Client/Plane/Pilot`. A plane flown by the
  server needs that aerodynamics code moved into a shared module, or its own simpler
  server-side controller.
- NPC planes keep server network ownership and never go through the seat path.
- "Despawn when the owner leaves" only applies to player owners. NPC planes need their own
  lifetime rule.

## Regions

The world is made of authored regions. There is one region for now, and nothing that
supports more than one is being built. Two conventions exist so that adding regions later
doesn't require rewriting systems that were built in the meantime.

**Entities placed in the world carry a region ID.** Airports are the first case. Anything
else authored per region (landmarks, fuel depots, gates) should do the same. With a single
region this is bookkeeping only, and nothing needs to branch on it.

**Altitude is relative to a per-region reference Y.** Altitude-based logic must not treat
`Position.Y` as altitude. It subtracts the reference Y of the region the entity is
currently in. That reference must be looked up rather than stored as a constant, because
a plane can change regions during a flight. No altitude-based logic exists yet
(`RHO_AIR_NORM` in `Pilot` is constant), so today this is a rule for the first system that
needs altitude: density falloff, a service ceiling, an altimeter on the HUD. That system
should add the lookup, with the single region's reference Y set to 0.

### Deferred: more than one region

Recorded so the analysis doesn't need redoing. Not to be implemented without a new
decision.

A single region is limited to roughly 50k studs from the origin. Two ways past that were
considered.

Stacked regions in one place, each at its own Y offset. This works because float precision
loss is per axis, so Y is spare budget. Costs:

- Each layer needs roughly 8–10k studs of Y for terrain, flight ceiling, and a buffer so
  layers can't see each other. That allows about 5 layers in positive Y.
- `workspace.FallenPartsDestroyHeight` defaults to −500 and destroys any part below it.
  Layers must stay above it, or it must be lowered.
- Soft altitude ceilings (engine power falling off with region-relative altitude) are
  needed to keep players out of the layer above.
- `Lighting` is global to the place. A different look per region means the client swaps
  lighting settings locally on transition.
- Keeping several regions loaded probably requires StreamingEnabled. The destination has
  to be streamed in before a player is moved there, and the pilot's own plane has to stay
  loaded.
- The transition is a CFrame shift of the assembly the pilot's client already owns. It
  happens on one server with no loading screen, and it can be tested in Studio.

Sharded regions as separate places, joined by TeleportService. Costs:

- TeleportService doesn't work in Studio play-test, so every transition change has to be
  published to test.
- The plane can't travel with the player. Fuel, cargo, damage, contract progress,
  velocity, heading, and altitude all have to be serialized and rebuilt at the other end,
  which needs an in-flight spawn path. Currently piloting only begins when a character
  sits in a seat.
- TeleportData passes through the client, so it can't be trusted with handoff state. That
  state belongs in MemoryStoreService, keyed by player.
- The profile save when leaving one server races the profile load when joining the next,
  so session locking is required.
- Players arrive in any server of the destination region, so groups get split up, and
  markets become separate per server.

For either approach, transitions could be continuous along region edges or limited to
choke points. Edge crossings require the whole border to be authored consistently on both
sides, plus hysteresis so players don't bounce back and forth across the line. Choke points
require a position volume plus a heading and speed window. They limit authoring and
pre-streaming to a few known places, and the server check is small.

The recommendation at the time was stacking with choke points, since it keeps a single
server, a shared market, and testing in Studio.

## Where new systems go (proposal)

| System | Placement |
| --- | --- |
| Cargo types, commodity definitions | `Modules/CargoData` — static, both sides read it |
| Airport definitions (region ID, position, market, tier) | `Modules/AirportData` |
| Market pricing math | `Modules/Economy` — pure functions, `--!strict`, shared so the client can preview prices |
| Market state + transactions | `Server/Market` — authoritative, owns current prices, in-memory only |
| Player wallet / progression state | `Server/PlayerProfile` — the only writer |
| Spawning and despawning owned aircraft | `Server/PlaneSpawner` — replaces the hardcoded `ModelZ` in `Server.server.luau` |
| Persistence (DataStore) | `Server/Persistence` — wrapped, called only by PlayerProfile |
| Contracts / missions | `Server/Contracts`, with shared shape in `Modules/ContractData` |
| Airport world objects | Tag + `Replicator` receiver, same pattern as planes |
| Cargo loading UI, market UI, wallet HUD | `Client/Gui/*Layer`, registered with `Root` |
| Cargo mass affecting flight | `Modules/PlaneData` mass fields + `Pilot` reading loaded mass |

Two rules worth restating from CLAUDE.md, because they bind hardest here: pure math
modules (`Economy`) should be `--!strict` and struct-like; and every Instance↔table
association goes through `ObjectData`.
