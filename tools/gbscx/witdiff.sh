#!/bin/bash
# Byte-compare two captured witness worlds, frame by frame, and count the
# differing pixels rather than just reporting "differs". World against world is
# the right comparison for a change that claims to be local: a witness that is
# byte-identical to the control needs no reference image and no tolerance rule
# to mean something.
#
#   tools/gbscx/witdiff.sh control borrow
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
A=$1
B=$2
for f in "$WORKTREE"/.shots/*."$A".ppm; do
  tag=$(basename "$f" ".$A.ppm")
  g="$WORKTREE/.shots/$tag.$B.ppm"
  [ -e "$g" ] || { echo "$tag  MISSING in $B"; continue; }
  python3 - "$f" "$g" "$tag" <<'EOF'
import sys
a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
if len(a) != len(b):
    print('%-12s SIZE MISMATCH' % sys.argv[3]); raise SystemExit
h = a.index(b'255\n') + 4
n = sum(1 for i in range(h, len(a), 3) if a[i:i+3] != b[i:i+3])
print('%-12s %s' % (sys.argv[3], 'byte-identical' if n == 0
                    else '%d pixels differ' % n))
EOF
done
