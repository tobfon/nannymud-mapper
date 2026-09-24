# nannymud-mapper

Client-side automap for [NannyMUD](https://nannymud.lysator.liu.se/). A Mudlet package that
computes each area's layout in Lua from the server's NMP feed (NannyMUD Map Protocol, one `!NMP` line per move).

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

**The map window.** The first time the package loads it opens the map as a small window over
the top right corner of the text. Drag its inner or bottom edge to resize it; the size is
remembered. `mapwin` closes it and opens it again, `mapwin left` moves it to the other corner,
`mapwin lock` removes its frame.

Mudlet's own **Map** button still works if you would rather have the map docked. Mudlet may
refuse to show the map in one of the two while the other has been in use; `mapwin` says so
when it happens. To change over, close the one you have, restart Mudlet, then type `mapwin`
or click **Map**.

Known issue, seen on Mudlet 5.0.1 with two sessions side by side in MultiView: after switching
to another program and back, the text of the session you are not in can go black. Nothing is
lost; click into that session and it redraws. It has only been seen after locking the map window
from its right-click menu; `mapwin lock` does the same job and has not caused it.

**2. Switch the stream on, in game.** The server sends the events only to players who asked
for them, because without this package they are a line of text on every move:

```
nmp on           start streaming; remembered when you log in again
nmp              what it is doing, and whether this package has answered
nmp off          stop streaming
```

`help nmp` in game has the rest. The `nmp` command is being rolled out; if the game
answers "What?", you do not have it yet, and Elrohir can hand it to you. Not every area is
mapped: the administrators open them one at a time.

Then walk. Type `maphelp` for the everyday commands and `maplegend` for what the colours,
dots, letters and lines on the map mean. `maphelp advanced` has the rest: shaping the map by
hand, mazes, diagnostics and tuning.

## What you get

Rooms are placed on a real grid rather than strung out from where you happened to walk in.
The engine solves each area as a graph: it finds the cycles, keeps a corridor straight, holds
a 45° diagonal at 45° where it can, and when a loop cannot close truthfully it decides which
edge is least bad to bend rather than letting the map drift. Up and down exits dock as
separate floors. Areas too small to deserve a tab fold into the world map.

It relayouts as you explore, in the background, without freezing the client.

`mapmark bank` remembers the room you are in; from then on typing `bank` walks there. A bare
`mapmark` remembers "here" and `mapreturn` walks back: mark, go and sell, return. Marks are
kept in the map. Unexplored exits are drawn as short grey half-lines rather than Mudlet's
stubs, which it repaints every frame, so a big half-explored area stays fast. `mapview` is a
prototype second window that draws the map you are on in the style of `mapexport`, with a ring
for you and click-to-walk.

`mapexport` writes the map you are standing on as a picture: white, with pale terrain tints,
every room numbered, and a list of the rooms with where each way off the map leads. It is an
SVG, which any browser opens and a wiki can show. `mapexport a4` fits the same drawing on one
A4 sheet to print.

That is a picture, not a copy of your map. The map itself lives in the Mudlet profile, and
Mudlet moves it: Settings, the Mapper tab, has **Copy map to other profile(s)**, **Save
map...** and **Load map...** (loading replaces the map in that profile; nothing is merged).
Everything this package knows travels in that file. Reopen a profile after a map is loaded
into it. `maphelp share` says the same in the client.

## Using it with another MUD

The `!NMP` trigger is only an adapter. The integration point is one function:

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
