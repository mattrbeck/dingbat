#!/usr/bin/env python3
"""Rank the GB and GBC archives by popularity and extract the next batch.

Two sources, two naming conventions:
  GB  -- GoodGB nested zips inside one big archive zip, "Title (UE) (V1.1).zip"
  GBC -- one archive.org file per title, No-Intro "Title (USA, Europe) (...).zip"

A title matches a POPULAR entry when the part of the filename before the first
" (" normalises equal to it, so "Tetris (W) (V1.1)" matches "Tetris" but
"Tetris 2" never does. Among the matching dumps the canonical one wins (see
score): no betas/protos/hacks, USA preferred, latest revision.

Usage: pick_roms.py <workdir> <count> [--skip N] [--out selected_roms.json]
  workdir needs gb_zip_list.txt, gbc_zip_list.txt, GameBoy.zip
"""
import json, os, re, subprocess, sys, urllib.parse, zipfile

GBC_BASE = 'https://archive.org/download/theentireGAMEBOYCOLORcollection'

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
    "Final Fantasy Legend",
    "Final Fantasy Adventure",
    "Mega Man - Dr. Wily's Revenge",
    "Mega Man V",
    "Castlevania - The Adventure",
    "Castlevania II - Belmont's Revenge",
    "Castlevania Legends",
    "Kid Icarus - Of Myths and Monsters",
    "Gargoyle's Quest",
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
    "Batman - The Video Game",
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
    "Bust-A-Move",
    "Space Invaders",
    "Killer Instinct",
    "Mortal Kombat",
    "Street Fighter II",
    "Prehistorik Man",
    "Trip World",
    "Legend of the River King",
    "Revelations - The Demon Slayer",
    "Tetris 2",
    "Tetris Attack",
    "Tetris Blast",
    "Kirby's Pinball Land",
    "Kirby's Block Ball",
    "Kirby Tilt 'n' Tumble",
    "Mario Picross 2",
    "Wave Race",
    "F-1 Race",
    "Golf",
    "Baseball",
    "Qix",
    "Boxxle",
    "Solar Striker",
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
    "Altered Space - A 3-D Alien Adventure",
    "Pinball Fantasies",
    "Motocross Maniacs",
    "Nemesis",
    "Snoopy Tennis",
    "Daffy Duck",
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
    "Bugs Bunny Crazy Castle",
    "Adventure Island",
    "Amazing Penguin",
    "Burger Time Deluxe",
    "Catrap",
    "Chessmaster, The",
    "Days of Thunder",
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

    sources = {}   # normalised title -> (system, zipname)
    for sysname, listfile in (('gb', 'gb_zip_list.txt'), ('gbc', 'gbc_zip_list.txt')):
        for line in open(os.path.join(workdir, listfile)):
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
    if sysname == 'gb':
        # nested: GameBoy.zip -> <title>.zip -> <title>.gb
        with zipfile.ZipFile(os.path.join(workdir, 'GameBoy.zip')) as outer:
            inner_path = os.path.join(workdir, 'zips', zipname)
            os.makedirs(os.path.dirname(inner_path), exist_ok=True)
            with outer.open(zipname) as src, open(inner_path, 'wb') as dst:
                dst.write(src.read())
    else:
        inner_path = os.path.join(workdir, 'zips', zipname)
        os.makedirs(os.path.dirname(inner_path), exist_ok=True)
        if not os.path.exists(inner_path):
            url = GBC_BASE + '/' + urllib.parse.quote(zipname)
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
