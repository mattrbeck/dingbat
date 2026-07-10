# Cross-compiles dingbat for Windows (x86_64) using mingw-w64.
# Runs as a linux/amd64 image (emulated on Apple Silicon via Rosetta).
#
# Build the image:
#   docker build --platform linux/amd64 -t dingbat-win-cross docker/windows-cross
# Build dingbat.exe (from the repo root):
#   docker run --rm --platform linux/amd64 \
#     -v "$PWD":/src -v dingbat-nimble:/root/.nimble -w /src \
#     dingbat-win-cross ./docker/windows-cross/build.sh
FROM nimlang/nim:2.2.6-ubuntu-regular

RUN apt-get update && apt-get install -y --no-install-recommends \
        mingw-w64 curl ca-certificates unzip \
    && rm -rf /var/lib/apt/lists/*

# SDL2 development files for the mingw sysroot. Headers/libs go into the
# cross-gcc's default search path; nim.cfg references the SDL2 include dir
# and links libSDL2.a statically.
ARG SDL2_VERSION=2.32.8
RUN curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-devel-${SDL2_VERSION}-mingw.tar.gz" \
        | tar xz -C /tmp \
    && cp -r /tmp/SDL2-${SDL2_VERSION}/x86_64-w64-mingw32/include/* /usr/x86_64-w64-mingw32/include/ \
    && cp -r /tmp/SDL2-${SDL2_VERSION}/x86_64-w64-mingw32/lib/* /usr/x86_64-w64-mingw32/lib/ \
    && rm -rf /tmp/SDL2-${SDL2_VERSION}

WORKDIR /src
