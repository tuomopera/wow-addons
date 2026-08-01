# GankList

A WoW addon that remembers who ganked you while leveling, and syncs the grudge
list to one or two trusted friends. Built for **TBC Anniversary** (client 2.5.5),
works on other Classic flavors via fallbacks.

## Install

**Easiest:** [**Download GankList.zip**](https://github.com/tuomopera/wow-addons/releases/latest/download/GankList.zip)
and extract the `GankList` folder into your AddOns directory, so the path is:

```
World of Warcraft/_anniversary_/Interface/AddOns/GankList/GankList.toc
```

Make sure there's no double folder (`AddOns/GankList/GankList/...`).

**Or with git:**

```bash
cd ".../World of Warcraft/_anniversary_/Interface/AddOns"
git clone https://github.com/tuomopera/wow-addons.git tmp && mv tmp/GankList . && rm -rf tmp
```

Then **fully restart WoW** (addons are read at launch, not on `/reload`), and at
the character-select screen enable **GankList** under **AddOns**.

## Use

When a player kills you they're logged in the **Suspects** tab - a kill log you
review. Nobody is added to the **Wanted** list automatically; you promote the
real gankers yourself with `/gank add`.

| Command | What it does |
|---|---|
| `/gank` | open the window (Wanted + Suspects tabs) |
| `/gank add Name` | manually add a ganker (or target them and omit the name) |
| `/gank del Name` | remove a ganker (or target them and omit the name) |
| `/gank friend Name` | sync with a friend (no name = list them, `reset` = clear all) |
| `/gank unfriend Name` | stop syncing with a friend |
| `/gank ping` | test the sync link with your friends |
| `/gank sync` | push your list to friends now |
| `/gank party` | announce the list to party/raid chat |
| `/gank autoaccept` | toggle auto-accept of friends' forgives |
| `/gank check` | reload-safe diagnostic |
| `/gank help` | show all commands |

**Suspects** are everyone who has killed you (with a kill count), so you can spot
the repeat offenders and `/gank add` them to Wanted (or hit the **→ Wanted**
button on the row). Suspects self-clean after a week, or dismiss one with its X.

Wanted, Blacklist and Whitelist are all ordered newest addition first, and each
row shows just the name, when you added them, and the note why.

Once someone's on **Wanted**:

- You get a brief on-screen alert when they come into range (nameplate / target /
  mouseover), and the row notes **· seen `<date> <time>`** so you know how cold
  the trail is.
- When you land the killing blow on them, a **revenge** tally (`⚔ N`) ticks up
  next to their kill count - sweet, sweet payback.

## Looking For Group warnings

When the LFG browser is open, any group whose **leader or members** are on your
Wanted or Blacklist gets a 💀 skull next to their name - both in the result list
and in the group's member tooltip - so you don't invite a known jerk to a dungeon.
The skull also shows on player unit tooltips (party frames, mouseover).

## Syncing

Add each other as friends on both PCs:

```
/gank friend FriendName
```

New gankers sync automatically the moment you add them. If a friend was **offline**
when you added someone, they catch up silently the next time either of you logs in
(a quiet handshake swaps both lists - no chat spam, no buttons). `/gank sync` (or
the **Sync Partners** button) forces it now, and works **both ways**: it pushes
your list and asks the friend to push theirs back.

Removals stick. Forgiving someone leaves a 30-day tombstone, so your friend's copy
can't quietly resurrect them on the next sync - the usual reason two lists drift
apart. Re-adding the name clears it.

Out of sync? `/gank check` shows whether each friend is online (whispers to an
offline friend are dropped by the server) and how many messages are still queued.
Both sides need the same addon version.

Sync uses addon whispers, so it only works while you're **same faction** and able
to whisper each other. Only names in your friend list are accepted - strangers
can't inject entries.

(On a single-realm server like Anniversary's Spineshatter, just the character name
is enough - no realm suffix needed. The addon still accepts a `Name-Realm` form if
you're ever on a connected realm.)

Your actual list lives in your local SavedVariables, never in this repo.
