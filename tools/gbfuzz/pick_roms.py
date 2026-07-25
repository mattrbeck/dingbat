#!/usr/bin/env python3
"""Rank the GB and GBC archives by popularity and extract the next batch.

Four public archive.org sources, two naming conventions between them (see
SOURCES). Two are enough to sweep from; the other two exist because no single
set is complete -- Pokemon Yellow, Double Dragon II/3, Mystical Ninja and the
Arcade Classic series are all missing from the first pair and present in the
second. A title is taken from whichever source has the most canonical dump.

A title matches a POPULAR entry when the part of the filename before the first
" (" normalises equal to it, so "Tetris (W) (V1.1)" matches "Tetris" but
"Tetris 2" never does. Among the matching dumps the canonical one wins (see
score): no betas/protos/hacks, USA preferred, latest revision.

Usage: pick_roms.py <workdir> <count> [--skip N] [--out selected_roms.json]
  workdir needs gb_zip_list.txt, gbc_zip_list.txt, GameBoy.zip
"""
import json, os, re, subprocess, sys, urllib.parse, zipfile

# name -> (list file, how to fetch one title). "item" downloads one file from an
# archive.org item directly; "nested" pulls a single entry out of a zip stored in
# an item, which archive.org serves without transferring the whole archive;
# "local" reads the outer zip already on disk. Listings for the nested sources
# come from `archive.org/download/<item>/<zip>/` (see fetch_lists.sh).
SOURCES = {
    'gb':   ('gb_zip_list.txt',   ('local',  'GameBoy.zip')),
    'gbc':  ('gbc_zip_list.txt',  ('item',
             'https://archive.org/download/theentireGAMEBOYCOLORcollection')),
    'gb2':  ('alt_gb_list.txt',   ('nested',
             'https://archive.org/download/gb_20251214/gb.zip')),
    'gbc2': ('alt_gbc_list.txt',  ('nested',
             'https://archive.org/download/GameBoyColor_201905/GameBoy Color.zip')),
}

# Ranked by sales and notability, GB and GBC interleaved. The tail leans on
# titles that are known to stress a GB emulator (mid-frame scroll tricks, HDMA
# colour effects, 3D engines, MBC oddities) rather than on sales alone.
POPULAR = [
    "Tetris",
    "Pokemon - Red Version",
    "Pokemon - Blue Version",
    "Pokemon - Yellow Version - Special Pikachu Edition",
    "Pokemon - Gold Version",
    "Pokemon - Silver Version",
    "Pokemon - Crystal Version",
    "Super Mario Land",
    "Super Mario Land 2 - 6 Golden Coins",
    "Legend of Zelda, The - Link's Awakening",
    "Legend of Zelda, The - Link's Awakening DX",
    "Super Mario Bros. Deluxe",
    "Dr. Mario",
    "Wario Land - Super Mario Land 3",
    "Kirby's Dream Land",
    "Kirby's Dream Land 2",
    "Legend of Zelda, The - Oracle of Ages",
    "Legend of Zelda, The - Oracle of Seasons",
    "Pokemon Pinball",
    "Pokemon Trading Card Game",
    "Metroid II - Return of Samus",
    "Donkey Kong",
    "Donkey Kong Country",
    "Donkey Kong Land",
    "Wario Land II",
    "Wario Land 3",
    "Tetris DX",
    "Mario Golf",
    "Mario Tennis",
    "Dragon Warrior Monsters",
    "Harvest Moon GB",
    "Harvest Moon 2 GBC",
    "Metal Gear Solid",
    "Final Fantasy Legend, The",
    "Final Fantasy Adventure",
    "Megaman - Dr. Wily's Revenge",
    "Megaman V",
    "Castlevania Adventure, The",
    "Castlevania II - Belmont's Revenge",
    "Castlevania Legends",
    "Kid Icarus - Of Myths and Monsters",
    "Gargoyle's Quest - Ghosts'n Goblins",
    "Yoshi",
    "Yoshi's Cookie",
    "Mario's Picross",
    "Game & Watch Gallery",
    "Game & Watch Gallery 2",
    "Game & Watch Gallery 3",
    "Pokemon Puzzle Challenge",
    "Shantae",
    # --- batch 2 ---
    "Resident Evil Gaiden",
    "Perfect Dark",
    "Conker's Pocket Tales",
    "Alone in the Dark - The New Nightmare",
    "Survival Kids",
    "Grand Theft Auto",
    "Toki Tori",
    "Magi Nation",
    "Lufia - The Legend Returns",
    "Azure Dreams",
    "Bionic Commando",
    "Batman",
    "Teenage Mutant Ninja Turtles - Fall of the Foot Clan",
    "Operation C",
    "Blaster Master Boy",
    "Bomberman GB",
    "Pocket Bomberman",
    "R-Type",
    "Gradius - The Interstellar Assault",
    "Balloon Kid",
    "Rayman",
    "Tomb Raider",
    "Micro Machines",
    "Bust-A-Move 2 - Arcade Edition",
    "Space Invaders",
    "Killer Instinct",
    "Mortal Kombat",
    "Street Fighter II",
    "Prehistorik Man",
    "Trip World",
    "Legend of the River King GB",
    "Revelations - The Demon Slayer",
    "Tetris 2",
    "Tetris Attack",
    "Tetris Blast",
    "Kirby's Pinball Land",
    "Kirby's Block Ball",
    "Kirby Tilt 'n' Tumble",
    "Mario's Picross 2",
    "Wave Race",
    "F-1 Race",
    "Golf",
    "Baseball",
    "Qix",
    "Boxxle",
    "SolarStriker",
    "Alleyway",
    "Star Wars",
    "Wacky Races",
    "V-Rally - Championship Edition",
    "Test Drive 6",
    "Croc",
    "Toy Story Racer",
    "Warlocked",
    "Dragon Warrior I & II",
    "Dragon Warrior III",
    "Dragon Warrior Monsters 2 - Cobi's Journey",
    "Pokemon Pinball",
    "Ghosts'n Goblins",
    "Altered Space",
    "Pinball Fantasies",
    "Motocross Maniacs",
    "Nemesis",
    "Snoopy Tennis",
    "Daffy Duck - The Marvin Missions",
    "Looney Tunes",
    "Aladdin",
    "Lion King, The",
    "Pocahontas",
    "Toy Story",
    "Tarzan",
    "Hercules",
    "Men in Black - The Series",
    "Rugrats Movie, The",
    "Spider-Man",
    "X-Men - Mutant Academy",
    "Worms Armageddon",
    "Turok - Battle of the Bionosaurs",
    "Bugs Bunny - Crazy Castle II",
    "Adventure Island",
    "Amazing Penguin",
    "Burger Time Deluxe",
    "Catrap",
    "Chessmaster, The",
    "Days of Thunder",
    # --- batches 3+ ---
    "Final Fantasy Legend II",
    "Final Fantasy Legend III",
    "Megaman II",
    "Megaman III",
    "Megaman IV",
    "Mega Man Xtreme",
    "Mega Man Xtreme 2",
    "Batman - Return of the Joker",
    "Batman - The Animated Series",
    "Legend of the River King 2",
    "Bust-A-Move 3 DX",
    "Bugs Bunny - Crazy Castle 3",
    "Pokemon - Gold Version",
    "Kirby's Star Stacker",
    "Donkey Kong Land 2",
    "Donkey Kong Land III",
    "Super Mario Bros. Deluxe",
    "Wario Land II",
    "Tetris Plus",
    "Dr. Mario 64",
    "Mickey's Racing Adventure",
    "Mickey's Speedway USA",
    "Bomberman Quest",
    "Bomberman Max - Blue Champion",
    "Bomberman Max - Red Challenger",
    "Wetrix GB",
    "Bionic Commando",
    "Gremlins 2 - The New Batch",
    "Duck Tales",
    "Duck Tales 2",
    "Chip 'n Dale Rescue Rangers",
    "Darkwing Duck",
    "Little Mermaid, The",
    "Aladdin",
    "Beauty and the Beast - A Board Game Adventure",
    "Hercules",
    "Mulan",
    "Tigger's Honey Hunt",
    "Dexter's Laboratory - Robot Rampage",
    "Powerpuff Girls, The - Bad Mojo Jojo",
    "Rugrats - Totally Angelica",
    "SpongeBob SquarePants - Legend of the Lost Spatula",
    "Pocket Monsters Stadium",
    "Puzzle Bobble GB",
    "Klax",
    "Pipe Dream",
    "Kwirk",
    "Loopz",
    "Palamedes",
    "Pop'n TwinBee",
    "Parodius",
    "Trax",
    "Amazing Spider-Man, The",
    "Spider-Man 2 - The Sinister Six",
    "X-Men - Mutant Wars",
    "Fighting Simulator - 2-in-1 Flying Warriors",
    "Double Dragon",
    "Double Dragon II",
    "Double Dragon 3 - The Arcade Game",
    "Final Fight",
    "Mystical Ninja Starring Goemon",
    "Rainbow Islands",
    "Snow Bros. Jr.",
    "Super Mario Land 2 - 6 Golden Coins",
    "Turok 2 - Seeds of Evil",
    "Turok 3 - Shadow of Oblivion",
    "Vigilante 8",
    "Rampage - World Tour",
    "Roadsters Trophy",
    "San Francisco Rush 2049",
    "NBA Jam 99",
    "Madden 2000",
    "International Superstar Soccer 99",
    "FIFA 2000",
    "Tony Hawk's Pro Skater",
    "Tony Hawk's Pro Skater 2",
    "Wacky Racers",
    "Blue's Clues - Blue's Alphabet Book",
    "Frogger",
    "Q-bert",
    "Pac-Man",
    "Ms. Pac-Man",
    "Galaga & Galaxian",
    "Centipede",
    "Asteroids",
    "Missile Command",
    "Joust",
    "Defender",
    "Arcade Classic No. 1 - Asteroids & Missile Command",
    "Arcade Classic No. 2 - Centipede & Millipede",
    "Arcade Classic No. 3 - Galaga & Galaxian",
    "Arcade Classic No. 4 - Defender & Joust",
    "Game Boy Camera",
    "Mary-Kate and Ashley - Get a Clue!",
    "Barbie - Ocean Discovery",
    "Harry Potter and the Sorcerer's Stone",
    "Lord of the Rings, The - The Fellowship of the Ring",
    "Shrek - Fairy Tale Freakdown",
    "Antz",
    "Bug's Life, A",
    "Chicken Run",
    "Dinosaur",
    "Emperor's New Groove, The",
    "Toy Story 2",
]

BAD = re.compile(r'\b(beta|proto|prototype|demo|sample|unl|pirate|hack|program|'
                 r'test program|debug)\b|\[b\d?\]|\[h\d?\]|\[t\d?\]|\[a\d?\]|\[p\d?\]',
                 re.I)


def norm(s):
    s = s.lower().replace('&', 'and')
    s = re.sub(r"[^a-z0-9]+", ' ', s)
    return ' '.join(s.split())


def base_title(zipname):
    """Filename up to the first ' (' — the No-Intro/GoodGB title proper."""
    stem = re.sub(r'\.zip$', '', zipname, flags=re.I)
    return stem.split(' (')[0]


def score(name):
    """Higher is more canonical. Betas and hacks are rejected outright."""
    if BAD.search(name):
        return None
    s = 0.0
    low = name.lower()
    if '(usa, europe)' in low or '(ue)' in low: s += 45
    elif '(usa' in low or '(u)' in low: s += 50
    elif '(world)' in low or '(w)' in low: s += 40
    elif '(europe' in low or '(e)' in low: s += 30
    elif '(japan' in low or '(j)' in low: s += 5
    # latest revision of a title is the one most people played
    m = re.search(r'\(rev (\d+)\)|\(v1\.(\d)\)', low)
    if m: s += 2 * int(m.group(1) or m.group(2))
    s -= len(name) * 0.01
    return s


def main():
    workdir = sys.argv[1]
    count = int(sys.argv[2])
    skip = 0
    out = 'selected_roms.json'
    args = sys.argv[3:]
    while args:
        a = args.pop(0)
        if a == '--skip': skip = int(args.pop(0))
        elif a == '--out': out = args.pop(0)

    sources = {}   # normalised title -> [(source, zipname), ...]
    for sysname, (listfile, _) in SOURCES.items():
        path = os.path.join(workdir, listfile)
        if not os.path.exists(path):
            print(f'  note: {listfile} missing, skipping source {sysname}',
                  file=sys.stderr)
            continue
        for line in open(path):
            z = line.strip()
            if not z:
                continue
            sources.setdefault(norm(base_title(z)), []).append((sysname, z))

    picked, missing = {}, []
    for want in POPULAR:
        cands = sources.get(norm(want))
        if not cands:
            missing.append(want)
            continue
        scored = [(score(z), sysname, z) for sysname, z in cands]
        scored = [c for c in scored if c[0] is not None]
        if not scored:
            missing.append(want)
            continue
        best = max(scored)
        if want in picked:
            continue
        picked[want] = (best[1], best[2])

    ordered = [(t, picked[t]) for t in POPULAR if t in picked]
    # de-duplicate while preserving rank (POPULAR lists a few titles twice)
    seen, uniq = set(), []
    for t, v in ordered:
        if v[1] in seen:
            continue
        seen.add(v[1])
        uniq.append((t, v))
    batch = uniq[skip:skip + count]

    os.makedirs(os.path.join(workdir, 'roms'), exist_ok=True)
    sel = {}
    for title, (sysname, zipname) in batch:
        try:
            rom = extract(workdir, sysname, zipname)
        except Exception as e:
            print(f'  EXTRACTFAIL {zipname}: {str(e)[:100]}', file=sys.stderr)
            continue
        sel[title] = rom
    json.dump(sel, open(os.path.join(workdir, out), 'w'), indent=1)
    print(f'{len(sel)} roms -> {out}  (matched {len(uniq)}/{len(POPULAR)} popular titles)')
    if missing:
        print('unmatched:', '; '.join(missing[:20]))


def extract(workdir, sysname, zipname):
    romdir = os.path.join(workdir, 'roms')
    kind, base = SOURCES[sysname][1]
    inner_path = os.path.join(workdir, 'zips', f'{sysname}__{zipname}')
    os.makedirs(os.path.dirname(inner_path), exist_ok=True)
    if kind == 'local':
        with zipfile.ZipFile(os.path.join(workdir, base)) as outer:
            with outer.open(zipname) as src, open(inner_path, 'wb') as dst:
                dst.write(src.read())
    elif not os.path.exists(inner_path):
        if kind == 'nested':
            item, _, outer = base.rpartition('/')
            url = f'{item}/{urllib.parse.quote(outer)}/{urllib.parse.quote(zipname)}'
        else:
            url = base + '/' + urllib.parse.quote(zipname)
        r = subprocess.run(['curl', '-sL', '--retry', '3', '--fail',
                            '-o', inner_path, url], timeout=600)
        if r.returncode != 0:
            raise RuntimeError('download failed')
    with zipfile.ZipFile(inner_path) as zf:
        roms = [n for n in zf.namelist() if n.lower().endswith(('.gb', '.gbc'))]
        if not roms:
            raise RuntimeError('no rom in zip')
        name = roms[0]
        target = os.path.join(romdir, os.path.basename(name))
        if not os.path.exists(target):
            with zf.open(name) as src, open(target, 'wb') as dst:
                dst.write(src.read())
    os.remove(inner_path)
    return os.path.basename(name)


if __name__ == '__main__':
    main()
