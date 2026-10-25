# Packaging Core as a shared library

**Status: WIP, not started.** Nothing in this document has been done. It records the
decisions and the work order for extracting `src/Core` so the next session does not have to
re-derive them. No source file, project file or git configuration has been changed for it.

## Why

`src/Core` is engine-level infrastructure with no plane-cargo knowledge in it: `NetTable`,
`ObjectData`, `Replicator`, `SafeDataModel`, `Test`, `Util`. Every future project wants the
same pieces, and today the only way to get them is to copy the folder and let the copies
diverge. The intent is one GitHub repo holding Core as a flat library, consumed by this game
— and later projects — as a git submodule mounted at `ReplicatedStorage.Core`, the same
pattern already used for `vendor/Fusion`.

## Decisions

- **Separate library repo, consumed as a submodule.** Considered and rejected: a monorepo of
  orphan branches with in-repo `git subtree`, and plain subtree from a separate repo. A
  submodule pins an exact commit, duplicates no files, and lets a Core edit be an ordinary
  commit in `vendor/Core` pushed straight to the library repo. The cost is the
  `--recurse-submodules` / `git submodule update --init` step, which this repo already pays
  for Fusion.
- **One flat library.** All of Core ships and mounts as a single unit. Per-module packaging
  is bookkeeping with no payoff at seven files.
- **History is preserved** with `git subtree split --prefix=src/Core`, so blame on NetTable
  and Util survives the move.
- **NetTable provisions its own remotes**, so the library is drop-in and no project has to
  hand-wire rojo for it.

## Couplings that have to be cut first

1. `Core/NetTable` resolves `ReplicatedStorage.Remotes.NetTable` at module load, which forces
   every consumer to ship a matching `Remotes/NetTable.model.json`.
2. `default.project.json` mounts `vendor/Fusion` *inside* Core, putting a third-party UI
   library in Core's namespace at `ReplicatedStorage.Core.Fusion`. This has to change
   regardless: a submodule mounted by `$path` onto a directory that carries its own
   `default.project.json` cannot have children injected from the parent project file.

## Work order

### 1. Commit the working tree

`git subtree split` reads committed history only. Anything uncommitted under `src/Core` will
not reach the library repo.

### 2. Decouple NetTable from `ReplicatedStorage.Remotes`

In `src/Core/NetTable.luau`:

- Drop the module-load lines that resolve `remotes` / `remotePacket` / `remoteSync`. Keep
  `remotePacket` and `remoteSync` as module-level `local`s with no value, next to the
  existing forward-declaration block.
- `Server.init()` creates a Core-owned folder in `ReplicatedStorage` (`CoreRemotes`), a
  `NetTable` folder under it, the `Packet` and `Sync` `RemoteEvent`s under that, and assigns
  the two locals.
- `Client.init()` `WaitForChild`s the same path and assigns the two locals.
- Confirm nothing touches either local before the matching `init()`. `Scope:activate()` and
  `Scope:processBroadcasts()` are the paths to check; scopes only come from `Server.scope()`,
  which runs after `Server.init()`.
- If a get-or-create instance helper is wanted, it goes in `CoreUtil.Inst` in
  `Core/Util/init.luau`, not a local copy — see the centralization rule in `CLAUDE.md`.
- Delete `src/Remotes/NetTable.model.json`. `src/Remotes/Plane.model.json` is game-specific
  and stays.

NetTable is still listed as unvalidated in `AGENTS.md`, so this change has no regression
surface — and equally cannot be proven by play-testing existing behaviour. Exercise it with a
throwaway table on both sides.

### 3. Move Fusion out of Core's namespace

Lift the `Fusion` node in `default.project.json` out of `Core` to a sibling under
`ReplicatedStorage`, then repoint the five requires of `@game/ReplicatedStorage/Core/Fusion`
(`Client/Gui/Core`, `Gui/PilotLayer`, `Gui/PilotLayer.story`, `Gui/Root`,
`Gui/YokeIndicator`) at `@game/ReplicatedStorage/Fusion`. One line each. Update the layer
table in `ARCHITECTURE.md`.

### 4. Split the history out

    git subtree split --prefix=src/Core -b core-lib
    git push git@github.com:<you>/rbx-core.git core-lib:main

### 5. Shape the library repo

The split puts Core's files at the repo root. Move them under `src/` in one commit and add a
`default.project.json` of `{ "name": "Core", "emitLegacyScripts": false, "tree": { "$path":
"src" } }`, so the mount picks up the inner project file and `README.md` and friends stay out
of the DataModel — the layout `vendor/Fusion` already uses. Carry over the `.gitignore` and
the tabs-for-luau `.vscode/settings.json`.

Core's internal requires are already relative (`require("./Util/Log")`,
`require("./ObjectData")`), so nothing inside needs rewriting.

The README states the contract:

- The library mounts at `ReplicatedStorage.Core`, because consumers require it by absolute
  DataModel path (`@game/ReplicatedStorage/Core/NetTable`).
- `NetTable.Server.init()` must run on the server before `NetTable.Client.init()` can resolve
  its remotes.
- `Replicator` follows the `init()` / `start()` two-pass convention.

Optionally a `test.project.json` that builds a place of Core plus a scratch script, so the
library can be exercised without a game around it.

### 6. Swap this repo onto the submodule

    git rm -r src/Core
    git submodule add https://github.com/<you>/rbx-core.git vendor/Core

Change the Core node in `default.project.json` to `"$path": "vendor/Core"`. No consumer
require changes — `@game/ReplicatedStorage/Core/...` still resolves. Tag the library
`v0.1.0`; bump later with `git submodule update --remote vendor/Core` plus a commit here.

### 7. Documentation to update at that point

- `ARCHITECTURE.md`: Core is an external submodule at `vendor/Core`; fix the layer table and
  the module map intro.
- `AGENTS.md`: cloning needs `--recurse-submodules`, and editing Core means committing inside
  `vendor/Core`, pushing to the library repo, then bumping the pointer here.
- `CLAUDE.md`: adding a Core/Util helper is a library change, not a game change.

## Acceptance criteria

Manual, in Studio, per `AGENTS.md`:

1. `rojo build` succeeds and the place has
   `ReplicatedStorage.Core.{NetTable,ObjectData,Replicator,SafeDataModel,Test,Util}` plus
   `ReplicatedStorage.Fusion` — Fusion specifically *not* under Core.
2. `rojo serve` and play-test: the usual lifecycle prints still appear. A silent log is an
   `init()` / `start()` ordering problem from the NetTable change, not a logic bug.
3. Both `Test.run` collections still pass at startup.
4. Two-player test with a throwaway NetTable pushed from the server: the remotes folder is
   created, a joining second client gets its snapshot, deltas follow.
5. `git clone --recurse-submodules` into a temp directory and `rojo build` there, with no
   manual steps beyond the clone.
