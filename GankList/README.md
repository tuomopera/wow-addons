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

| Command | What it does |
|---|---|
| `/gank` | open the window |
| `/gank "Name"` | add a player to the list |
| `/gank add [Name]` | add (or target a player and omit the name) |
| `/gank addlast` | add the player who most recently killed you |
| `/gank pending` | show suspects (killed you once, not yet listed) |
| `/gank forgive Name` | remove a player (made amends) |
| `/gank list` | print the list to chat |
| `/gank party` | announce the list to party/raid chat |
| `/gank partner add Name` | sync with a friend |
| `/gank partner remove Name` | stop syncing with them |
| `/gank partner` | show your sync partners |
| `/gank sync` | push your list to partners now |
| `/gank autoaccept on\|off` | auto-accept partners' forgive requests |
| `/gank check` | reload-safe diagnostic |
| `/gank help` | show all commands |

**Two-strike auto-tracking:** not every PvP death is a gank. The first player to
kill you is remembered as a *suspect* — kill you a second time and they're
promoted to the gank list automatically. If you know the first death was a gank,
`/gank addlast` lists them immediately; `/gank pending` shows current suspects.
Suspects are forgotten after 3 days. You also get a brief on-screen alert when a
listed ganker comes into range (nameplate / target / mouseover).

## Syncing

Add each other as partners on both PCs:

```
/gank partner add FriendName
```

New gankers then sync automatically (and on login). Sync uses addon whispers, so
it only works while you're **same faction** and able to whisper each other. Only
names in your partner list are accepted — strangers can't inject entries.

(On a single-realm server like Anniversary's Spineshatter, just the character name
is enough — no realm suffix needed. The addon still accepts a `Name-Realm` form if
you're ever on a connected realm.)

Your actual list lives in your local SavedVariables, never in this repo.
