# Planning Docs

Reference material for future sessions working on this game. Read in this order:

1. **[AGENTS.md](AGENTS.md)** — how to work in this repo. Orientation, validation
   workflow, current known-broken state. Read this first, every session.
2. **[ARCHITECTURE.md](ARCHITECTURE.md)** — what exists, how the layers fit together,
   and where new systems should go.
3. **[DESIGN.md](DESIGN.md)** — what the game is trying to be. Product context for
   decisions that aren't purely technical.

`CLAUDE.md` at the repo root holds the hard coding conventions (naming, typing,
client/server split). It is the authority on *style*; these docs are the authority on
*structure* and *intent*. If they conflict, CLAUDE.md wins and the conflict should be
fixed here.

## Status of these docs

| Doc | Confidence | Notes |
| --- | --- | --- |
| AGENTS.md | High | Derived from the code as it stands. |
| ARCHITECTURE.md | High for "what exists", proposal for "where things go" | The forward-looking sections are marked. |
| DESIGN.md | Proposal | Drafted from a rough brief. Open questions are called out inline and need Henry's ruling before they harden. |

Keep them current: when a session lands a system that changes the module map or settles
an open design question, update the relevant doc in the same change.
