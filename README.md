# nannymud-mapper

Client-side automap for [NannyMUD](https://nannymud.lysator.liu.se/). A Mudlet package that
computes each area's layout in Lua from the server's `!MAP` event feed.

The server sends one line per move — room id, where you came from, the direction, the exits.
It does no rendering and stores no coordinates. Everything you see is solved on the client:
which rooms form an area, where each one goes, and which edges have to bend.

## Install

Two steps, and the first one alone does nothing.

**1. The Mudlet package.** Download `ElrohirMapper.mpackage` from
[Releases](https://github.com/tobfon/nannymud-mapper/releases) and drag it onto the Mudlet
window.

Or, in one line — note this is 111 characters and your client will wrap it, so join it back
together before pasting:

```
lua installPackage("https://github.com/tobfon/nannymud-mapper/releases/latest/download/ElrohirMapper.mpackage")
```

**Updating.** Type `mapupdate`. It downloads the newest release and swaps it in; if the download
fails nothing is changed. Your map lives in the profile, not in the package, and is kept. The
game tells you when a newer version is out. By hand: Mudlet refuses to install over a package
that is already there ("package ElrohirMapper is already installed"), so remove `ElrohirMapper`
under Toolbox → Package Manager first, then install the new one.

**Open the map.** Click the **Map** button in Mudlet's top bar. The package cannot do this
for you. The map is recorded either way, but you only see it with that window open.

**2. Switch the stream on, in game.** The server sends the events only to players who asked
for them, because without this package they are a line of text on every move:

```
maplink on       start streaming; remembered when you log in again
maplink          what it is doing, and whether this package has answered
maplink off      stop streaming
```

`help maplink` in game has the rest. The `maplink` command is being rolled out; if the game
answers "What?", you do not have it yet, and Elrohir can hand it to you. Not every area is
mapped: the administrators open them one at a time.

Then walk. Type `maphelp` for the commands, `maphelp advanced` for the diagnostic ones.

## What you get

Rooms are placed on a real grid rather than strung out from where you happened to walk in.
The engine solves each area as a graph: it finds the cycles, keeps a corridor straight, holds
a 45° diagonal at 45° where it can, and when a loop cannot close truthfully it decides which
edge is least bad to bend rather than letting the map drift. Up and down exits dock as
separate floors. Areas too small to deserve a tab fold into the world map.

It relayouts as you explore, in the background, without freezing the client.

## Using it with another MUD

The `!MAP` trigger is only an adapter. The integration point is one function:

```lua
elro.onRoom(id, fromId, dir, name, area, exits, terr)
```

| argument | |
|---|---|
| `id` | integer, stable and unique per room. The whole map is keyed on it |
| `fromId` | the room moved from, or `0` for none (login, teleport) |
| `dir` | the direction moved, e.g. `"east"`; `"none"` if there is no meaningful one |
| `name` | the room's short description |
| `area` | the server's own area name — drives which rooms share a tab |
| `exits` | comma-separated, e.g. `"east,west,up"` |
| `terr` | comma-separated terrain tokens, most specific first; may be `""` |

Call that on every move and the rest works. Nothing else in the client knows where the data
came from, so wiring up GMCP, MSDP or another out-of-band line is a trigger and a mapping of
field names. `analysis/test_onroom.lua` drives it exactly this way.

Two requirements on `id`: it must be stable across sessions, and it must never be **reused**
for a different room — the client treats a repeated id as the same place.

## Development

Lua lives in `lua/`, loaded in the order given by `lua/modules.lua`. `mapreload` re-reads them
without reinstalling the package, so an edit is one command away from being live.

```
sh tools/run-gate.sh full     # tests + the layout regression canary
sh tools/build-package.sh     # -> ElrohirMapper.mpackage (refuses if the gate is red)
```

`DESIGN.md` is the architecture. The layout engine's own notes are in the header comments of
`lua/eqw.lua` and `lua/walk.lua`.

## License

MIT — see [LICENSE](LICENSE).
