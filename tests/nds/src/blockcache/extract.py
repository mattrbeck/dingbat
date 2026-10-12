# python3 -I extract.py OBJ NAME: the .text of an ELF32 object as a Nim
# array of bytes, plus its symbols' offsets as constants
import struct, sys
d = open(sys.argv[1], 'rb').read()
name = sys.argv[2]
shoff, = struct.unpack_from('<I', d, 0x20)
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x2E)
secs = []
for i in range(shnum):
    secs.append(struct.unpack_from('<IIIIIIIIII', d, shoff + i * shentsize))
strtab = secs[shstrndx]
def sname(off, tab):
    s = tab[4] + off
    return d[s:d.index(b'\0', s)].decode()
text = symtab = None
for i, s in enumerate(secs):
    n = sname(s[0], strtab)
    if n == '.text': text, text_i = s, i
    if n == '.symtab': symtab = s
body = d[text[4]:text[4] + text[5]]
print('const %s* = [' % name)
for i in range(0, len(body), 16):
    print('  ' + ', '.join('0x%02X\'u8' % b for b in body[i:i + 16]) + ',')
print(']')
strs = secs[symtab[6]]
for i in range(symtab[5] // 16):
    st_name, st_value, st_size, st_info, st_other, st_shndx = struct.unpack_from('<IIIBBH', d, symtab[4] + i * 16)
    n = sname(st_name, strs)
    if st_shndx == text_i and n and not n.startswith('$') and n[0] != '.':
        print('const %s_%s* = 0x%X\'u32' % (name, n, st_value & ~1))
