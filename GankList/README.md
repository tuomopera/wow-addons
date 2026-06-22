# GankList

A WoW addon that remembers who ganked you while leveling, and syncs the grudge
list to one or two trusted friends. Built for **TBC Anniversary** (client 2.5.5),
works on other Classic flavors via fallbacks.

## Install

Clone (or download) this folder into your AddOns directory so the path is:

```
World of Warcraft/_anniversary_/Interface/AddOns/GankList/GankList.toc
```

```bash
cd ".../World of Warcraft/_anniversary_/Interface/AddOns"
git clone git@github.com:tuomopera/wow-addons.git tmp && mv tmp/GankList . && rm -rf tmp
```

Or grab **Code → Download ZIP**, and copy the `GankList` folder out of it into
`AddOns`. Make sure there's no double folder (`AddOns/GankList/GankList/...`).

Then **fully restart WoW** (addons are read at launch, not on `/reload`), and at
the character-select screen enable **GankList** under **AddOns**.

## Use

Gankers can't be added by hand — the only way onto the list is by **killing
you**. You can only ever remove (forgive) someone afterward.

| Command | What it does |
|---|---|
| `/gank` | open the window |
| `/gank forgive Name` | remove a player (made amends) |
| `/gank pending` | show suspects (killed you once, not yet listed) |
| `/gank list` | print the list to chat |
| `/gank party` | announce the list to party/raid chat |
| `/gank friend add Name` | sync with a friend |
| `/gank friend remove Name` | stop syncing with them |
| `/gank friend reset` | clear all sync friends |
| `/gank friend` | show your sync friends |
| `/gank sync` | push your list to friends now |
| `/gank autoaccept on\|off` | auto-accept friends' forgive requests |
| `/gank check` | reload-safe diagnostic |
| `/gank help` | show all commands |

**What counts as a gank** (auto-added) vs. a fair death:

- **Outmatched** — the killer is 3+ levels above you (or shows as a skull `??`).
  You couldn't fight back, so a single kill is enough.
- **Camped** — the same player kills you *again within an hour* (e.g. catching you
  each time you respawn). Repeat targeting, not bad luck.

A lone kill by someone near your level is ambiguous, so it's only a **suspect**
(`/gank pending`) and is forgotten after an hour unless they come back. You also
get a brief on-screen alert when a listed ganker comes into range (nameplate /
target / mouseover).

## Syncing

Add each other as friends on both PCs:

```
/gank friend add FriendName
```

New gankers then sync automatically (and on login). Sync uses addon whispers, so
it only works while you're **same faction** and able to whisper each other. Only
names in your friend list are accepted — strangers can't inject entries.

(On a single-realm server like Anniversary's Spineshatter, just the character name
is enough — no realm suffix needed. The addon still accepts a `Name-Realm` form if
you're ever on a connected realm.)

Your actual list lives in your local SavedVariables, never in this repo.
