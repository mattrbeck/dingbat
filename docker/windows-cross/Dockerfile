# Cross-compiles dingbat for Windows (x86_64) using mingw-w64.
# Runs as a linux/amd64 image (emulated on Apple Silicon via Rosetta).
#
# Build the image (from the repo root: it copies .github/scripts/build-sdl3.sh):
#   docker build --platform linux/amd64 -t dingbat-win-cross \
#     -f docker/windows-cross/Dockerfile .github/scripts
# Build dingbat.exe (from the repo root):
#   docker run --rm --platform linux/amd64 \
#     -v "$PWD":/src -v dingbat-nimble:/root/.nimble -w /src \
#     dingbat-win-cross ./docker/windows-cross/build.sh
FROM nimlang/nim:2.2.6-ubuntu-regular

# Acquire::Retries rides out transient mirror 5xx.
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
        mingw-w64 cmake make curl ca-certificates unzip \
    && rm -rf /var/lib/apt/lists/*

# SDL 3 for the mingw sysroot, built static from source (its mingw devel
# package has only the DLL): headers and libSDL3.a go into the cross-gcc's
# default search path, and nim.cfg links libSDL3.a statically. CI's Windows
# job (build-artifacts.yml) runs the same script on the runner without
# Docker.
COPY build-sdl3.sh retry.sh /tmp/sdl3/
RUN /tmp/sdl3/build-sdl3.sh /usr/x86_64-w64-mingw32 --mingw && rm -rf /tmp/sdl3

WORKDIR /src
