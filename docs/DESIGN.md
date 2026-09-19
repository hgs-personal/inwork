# Game Design

> **Status: mostly proposal.** Drafted from a rough brief ("plane flying / trading RPG")
> and from what the code already commits to. Unmarked sections are starting positions
> meant to be edited or rejected. **[DECIDED]** marks rulings Henry has made.
> **[OPEN]** marks questions that need a ruling before the systems they gate get built.
> **[DEFERRED]** marks things considered and explicitly not being built now.

## Pitch

You are a bush pilot running cargo for a living. You buy goods where they're cheap, fly
them somewhere they're worth more, and land in one piece. The flying is the game; the
trading is what gives every flight a stake.

## What the code already commits to

These aren't open questions — the implementation has made these choices, and the design
should lean into them rather than fight them:

- **Flying is skill-based and physical, not a travel menu.** There is a real lift curve,
  angle of attack, stall behaviour, and ground-handling hysteresis. Flights are something
  the player *does*, not something they wait through.
- **Starting the engine takes six seconds and it can fail to be running.** Ritual and
  procedure are part of the fantasy. Pre-flight has texture.
- **Plane state lives on the model, not the pilot.** Engine state and throttle survive a
  pilot getting out and back in. (Only a plane's owner can fly it, per the decision
  below.)
- **Multiplayer is shared-world.** Planes replicate to everyone; effects run for every
  client on every plane. Other pilots are visible, not abstract.
- **Cockpit-first framing.** The HUD is a throttle bar and a yoke reticle — the interface
  of flying the aircraft, not a menu over it.

## Core loop

```
    ┌─ At an airport ──────────────────────────────┐
    │  check market prices / available contracts    │
    │  buy cargo or accept a contract               │
    │  load it (mass and balance affect the plane)  │
    │  fuel up                                      │
    └───────────────────┬──────────────────────────┘
                        ↓
    ┌─ Preflight ──────────────────────────────────┐
    │  start engine, taxi, take off                 │
    └───────────────────┬──────────────────────────┘
                        ↓
    ┌─ Enroute ────────────────────────────────────┐
    │  navigate, manage fuel, handle weather        │
    │  the interesting part: terrain, weight, range │
    └───────────────────┬──────────────────────────┘
                        ↓
    ┌─ Arrival ────────────────────────────────────┐
    │  approach and land — landing quality matters  │
    │  sell cargo / complete contract → money       │
    └───────────────────┬──────────────────────────┘
                        ↓
              money → better planes, better routes
```

The loop should be completable in **5–15 minutes** for an early route. That's long
enough for a flight to feel like a trip and short enough that a failed one doesn't cost
a session.

## The trading layer (proposal)

### Commodities

Keep the list small and legible — roughly 8–12 goods, each with a clear identity:

| Good | Character |
| --- | --- |
| Mail / parcels | Light, low value, always available. The reliable floor. |
| Fuel drums | Heavy, low margin, needed by remote airports. |
| Food / produce | **Perishable** — value decays with flight time. |
| Machine parts | Heavy, good margin, demanded by industrial fields. |
| Medical supplies | High value, time-critical, reputation-heavy. |
| Livestock | Heavy, shifts in flight, penalised by rough handling. |
| Electronics | Light, high value, damaged by hard landings. |
| Ore / aggregate | Very heavy, thin margin, short hauls only. |

Each good gets: unit mass, unit volume, base value, perishability, and fragility. That
tuple is what makes a good interesting — mass fights your range, fragility fights your
landing, perishability fights your route choice.

The design goal is that **no plane can carry everything profitably**. Cargo choice should
be a real decision constrained by the aircraft you own.

### Pricing

Each airport has a local price per good, derived from a static profile (what it produces,
what it needs) plus drift over time, plus response to player trade. Selling ten loads of
ore into the same field should visibly depress the price there.

Suggested shape, in `Modules/Economy` as pure functions so the client can preview a
price without asking the server:

```
price = basePrice * demandMultiplier(airportProfile, good) * drift(t) * saturation(recentVolume)
```

**[OPEN] Is the economy shared across all players on a server, or per-player?** Shared
is more alive and makes other pilots matter, but one player can tank a market for
everyone. Per-player is simpler and fairer but makes the world feel inert. Either way,
market prices reset when a server starts (see Persistence below). Recommendation: shared
per-server, with airport profiles static.

### Money and costs

Income is margin on cargo plus contract payouts. Costs should be constant enough that
idle flying isn't free:

- **Fuel** — the primary sink. Purchased per airport at varying prices, burned as a
  function of throttle and time.
- **Maintenance** — accrues with hours flown and with abuse (hard landings, overspeed,
  running the engine at full throttle continuously). Skipping it raises failure chance.
- **Landing fees** — small, higher at big airports. Mostly flavour and a reason to prefer
  rough strips.

## Persistence and ownership [DECIDED]

Progress saves; the world resets. Money, owned aircraft, reputation, ratings, and any
contract in progress persist across sessions. Market prices, where planes were parked,
and weather are per-server and start fresh with each server.

Aircraft are owned. A player's profile lists the planes they own, and they ask for one to
be spawned at an airport. It despawns when they leave. There is no pool of shared world
planes.

Only the owner can fly a plane. Two extensions are expected later and the architecture
leaves room for both without building either:

- NPC planes, owned and flown by the game rather than a player.
- Crews, where any member of a plane's crew may fly it.

## Progression (proposal)

Three parallel tracks so progress never fully stalls:

1. **Aircraft** — the main one. The first plane is a small prop (`ModelZ` /
   `SmallPropPlane` as built). Later aircraft trade along real axes: capacity, range,
   speed, short-field performance, handling. A bigger plane should **not** be strictly
   better — a heavy twin that can't use the mountain strips is a real trade-off. Target
   roughly 5–7 aircraft across the whole progression.
2. **Reputation, per airport or per region** — earned by completing contracts on time and
   intact. Unlocks better contracts and better prices locally. Gives the player a reason
   to have a home base and to care about specific places.
3. **Pilot ratings** — gates access rather than granting stats. An instrument rating to
   fly in weather, a float rating for water landings, a heavy rating for the larger
   aircraft. Bought with money and/or earned through flight hours.

**[OPEN] How RPG-forward should this be?** Two directions:
- *Sim-leaning*: progression is entirely aircraft and access. No numeric pilot stats; the
  player's own skill is the stat. Cleaner, fits the physical flight model.
- *RPG-leaning*: pilot skills with numeric effects (fuel efficiency, better prices,
  reduced wear), NPC characters, dialogue, a story spine.

Recommendation: sim-leaning core with a light RPG shell — named NPC operators who give
contracts and remember you, reputation, but no numeric stats that beat the simulation.
This is the version most compatible with the flight model already built.

## The world

### Regions [DECIDED]

The world is made of hand-authored regions. For now there is exactly one.

### Size budget

Roblox parts become unreliable beyond roughly 50k studs from the origin on any axis. At
1 stud ≈ 0.28 m that is about 14 km of reach. Planes are expected to top out around
200–300 studs/s (roughly 110–165 kt, a realistic light-aircraft range). The longest
possible straight leg across a region is therefore about 5–7 minutes, and with 6–10
airports in a region, typical spacing gives legs of 1–4 minutes.

| Leg distance | @150 studs/s | @250 studs/s | @300 studs/s |
| --- | --- | --- | --- |
| 10k studs | 1.1 min | 0.7 min | 0.6 min |
| 25k studs | 2.8 min | 1.7 min | 1.4 min |
| 50k studs | 5.6 min | 3.3 min | 2.8 min |
| 100k studs | 11 min | 6.7 min | 5.6 min |

Terrain may have tighter coordinate bounds than parts. Verify that in Studio before laying
out a region, because it could halve these figures.

**[OPEN] Reconciling flight time with the budget.** The target was 5–20 minute flights,
which a single region can't provide as single legs. Proposal:

- Make a contract a sequence of legs (pick up at A, drop at B, pick up at B, drop at C),
  so the 5–20 minute unit is the run rather than the leg. This also puts more takeoffs
  and landings into a session, and those are the skill-heavy parts of flying.
- Start players in a slow aircraft (~140 studs/s) to stretch legs. Faster aircraft then
  shrink the map, which makes speed a meaningful progression axis.
- Use terrain to lengthen real routes beyond straight-line distance: ridges to climb,
  valleys to follow, approaches that need a circuit.

### Multiple regions [DEFERRED]

Two ways of getting more world than one region allows were considered and are not being
built:

- Stacking regions at different Y offsets inside one place.
- Sharding regions into separate places connected by TeleportService.

Moving between regions would happen either at any point along a region's edge, or at
choke points that require a particular position, heading, and speed. Cross-region legs
would be how 10–20 minute single flights come back, as a later progression unlock. The
technical costs of each option are recorded in ARCHITECTURE.md under Regions. The
architecture keeps two small conventions so this stays possible later.

### Airports

Airports should vary along runway length, surface, approach difficulty (terrain, water,
crosswind), and market profile. A short gravel strip on a ridge that pays well *because*
it's hard to reach is the archetype to aim at.

**[OPEN] Weather and time of day.** Strong candidates for making identical routes feel
different, and a natural gate for the instrument rating. Also significant scope. Suggest
deferring, but designing airport approaches as though weather will exist.

## Failure and risk

Risk is what makes trading decisions matter. Without it, cargo choice is just arithmetic.

- **Running out of fuel** — the honest one. Forces route planning and creates real
  tension on marginal legs.
- **Hard landings** — damage fragile cargo, cost maintenance. Landing quality should be
  measured (vertical speed at touchdown, runway remaining) and reported. This gives
  skilled flying a direct economic payoff, which is the core of the whole design.
- **Overloading** — takeoff roll grows, climb rate falls, stall speed rises. Should be
  survivable-but-frightening rather than an error message; the plane simply doesn't want
  to fly.
- **Engine failure** — from skipped maintenance. Rare, dramatic, survivable by a
  competent pilot (it's a glider now — find a field).

**[OPEN] What happens on a crash?** Losing the cargo and paying repair is the
conventional answer. Losing the aircraft is harsher and makes late-game flights tense but
risks being session-ending. Recommendation: lose cargo and pay a repair bill scaled to
damage; never lose the aircraft outright.

## Multiplayer

The shared world is already a fact of the implementation. Suggested posture: **coexistence
over competition.** Other pilots are scenery, company, and occasionally rivals for a
market — not enemies. No PvP.

Worth considering later, in rough order of appeal:

- Multi-crew: a second seat, a passenger or co-pilot, since planes already support
  multiple occupants and seat-based control.
- Cooperative contracts too large for one aircraft.
- A shared, visible market that other players' trading moves.

## Open questions, collected

Ranked by how much downstream work they gate:

1. **Leg length and contract structure.** Single-leg or multi-leg contracts, and the
   starting aircraft's speed. Gates the contract data shape and airport layout.
2. **Shared vs. per-player economy.** Gates the market implementation.
3. **RPG depth.** Sim-leaning or stat-leaning.
4. **Crash consequences.** Gates the damage system.
5. **Weather and time of day.** In scope or deferred?

Settled so far: hybrid persistence, owned aircraft spawned on request, only the owner can
fly a plane, and a world of authored regions with a single region for now. Multiple
regions, crews, and NPC planes are deferred.

## Design principles

Tie-breakers for decisions this document doesn't cover:

1. **The flying is the game.** If a feature makes flights shorter, more automatic, or
   less physical, it's probably wrong — even if it's convenient.
2. **Skill should pay.** A better pilot earns more: smoother landings, more efficient
   fuel use, tighter approaches into hard strips. Never let a stat substitute for that.
3. **Trade-offs over upgrades.** New aircraft and new routes should open different play,
   not strictly better play.
4. **The world should feel used.** Planes parked with engines running, prices that
   remember what was sold, airports that remember who you are.
5. **Legibility beats realism.** Real enough to be satisfying, readable enough that a
   player understands why they stalled.
