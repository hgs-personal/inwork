# Code Conventions and Architecture
- For standard variables, function names and methods use camelCase.
- For modules, singletons, classes, etc use PascalCase.\
- For lua / luau, USE TAB CHARACTERS NOT SPACES FOR INDENTATION
- For serial execution code (think high level system modules), generally include the following lifetime functions:
    * .init(), for the first pass startup where code cannot depend on other modules being ready 
    * 

## Strict Typing
- Where feasible and simple, use strict typing (including --!strict at the top of files to force strict linting). Especially preferred for utility and pure function only modules (math like).
- For simplicity, don't use strict typing in OOP-like code, due to luau's trouble with this. However, when possible, if code can be written to be struct like (functions just operate on tables) then full typing of the table type can be used. Trade-offs here are that dynamic dispatching is generally harder.

## Client / Server logic
- In general, a 2 or 3 module approach may be needed for one "logical" grouping of code that might relate to one system / object, due to the logical split between client, shared and server. For example, planes, at a minimum would use a pilot controller module on the client and a server plane object module. In some cases, it may be easier to include all shared utilities and client code in the same module, which would be most proper in Core, and then have a seperate module for server-only logic.
- When relating luau data to roblox engine instances, or using ID systems, prefer to centralize all of this into the existing infrastructure provided by Core/ObjectData

## General practices
- Prefer simplicty, even it leads to more manual verbosity.
- Avoid fallbacks as much as possible that would hide errors from calling code.

## Planning docs
- `docs/AGENTS.md` — how to work in this repo: orientation, manual Studio validation workflow, current known-broken state, model authoring requirements. Read first.
- `docs/ARCHITECTURE.md` — module map, layer boundaries, the plane system, the authority/replication model, and where new systems belong.
- `docs/DESIGN.md` — game design vision and open design questions. Proposal, not settled spec.
