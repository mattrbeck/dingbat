"""Find ROMs by SHA-1. Scripts name the file they were recorded on (`@file`),
which is tried first; otherwise every .gba under the library directories is
hashed once and cached by (path, size, mtime)."""
import hashlib
import json
import os

DEFAULT_DIRS = [d for d in os.environ.get('PLAYTEST_LIBRARY', '').split(':') if d] or [
    os.path.expanduser('~/Documents/emu/gba'),
    os.path.expanduser('~/Documents/emu/gba/archive/roms'),
]


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


class Library:
    def __init__(self, cache_path, dirs=None):
        self.dirs = dirs or DEFAULT_DIRS
        self.cache_path = cache_path
        try:
            self.cache = json.load(open(cache_path))
        except (OSError, ValueError):
            self.cache = {}

    def _hash(self, path):
        st = os.stat(path)
        key = f'{path}|{st.st_size}|{int(st.st_mtime)}'
        if key not in self.cache:
            self.cache[key] = sha1_of(path)
        return self.cache[key]

    def save(self):
        os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
        with open(self.cache_path, 'w') as f:
            json.dump(self.cache, f)

    def find(self, sha1, filename=None):
        if filename:
            for d in self.dirs:
                p = os.path.join(d, filename)
                if os.path.exists(p) and self._hash(p) == sha1:
                    self.save()
                    return p
        for key, h in self.cache.items():
            if h == sha1:
                p = key.split('|')[0]
                if os.path.exists(p):
                    return p
        for d in self.dirs:
            if not os.path.isdir(d):
                continue
            for name in sorted(os.listdir(d)):
                if name.lower().endswith('.gba'):
                    p = os.path.join(d, name)
                    if self._hash(p) == sha1:
                        self.save()
                        return p
        self.save()
        return None
