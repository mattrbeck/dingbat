# zlib 1.3.2, the inflate half

The files here are copied unmodified from the zlib 1.3.2 release
(`zlib-1.3.2.tar.gz`, SHA-256
`bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16`,
https://github.com/madler/zlib/releases/tag/v1.3.2): what `inflate()` needs
and nothing else. `LICENSE` is zlib's own.

    inflate.c inflate.h inftrees.c inftrees.h inffast.c inffast.h inffixed.h
    adler32.c zutil.c zutil.h zlib.h zconf.h

`src/dingbat/common/inflate_bound.nim` compiles them into every build (web,
iOS, desktop) with `-DZ_SOLO -DZ_PREFIX -DNO_GZIP`, through the wrapper
`src/dingbat/common/inflate_zlib.c`. Packing is still zippy's.

To update: replace the files from a newer release, change the version and
hash above, and run `tests/inflate_bound_test.nim` and `tools/fuzz.sh inflate`.
