# Downloads

The browser version at [dingbat.gg](https://dingbat.gg) is the recommended way to play.
The [**Latest build**](../../../releases/tag/latest) release carries current desktop
binaries, rebuilt from `main` on every push:

| Platform | Download |
|---|---|
| Linux x64 | [`dingbat-linux-x64.tar.gz`](../../../releases/download/latest/dingbat-linux-x64.tar.gz) |
| macOS (Apple Silicon) | [`dingbat-macos.dmg`](../../../releases/download/latest/dingbat-macos.dmg) |
| Windows x64 | [`dingbat-windows-x64.exe`](../../../releases/download/latest/dingbat-windows-x64.exe) |

<!-- /releases/download/latest/<file> (the `latest` TAG), not
     /releases/latest/download/<file>: the rolling build is a prerelease, so the
     second form 404s until a v* tag is cut. -->

These are development builds; `SHA256SUMS.txt` on the release lists their checksums.
Tagged `v*` releases publish the same three files on the [Releases](../../../releases)
page. For one specific commit, open its run under
[Actions → Build](../../../actions/workflows/build.yml) and download from **Artifacts**.

The binaries are unsigned: on macOS use **System Settings → Privacy & Security → Open
Anyway**, on Windows **More info → Run anyway**, once.

Linux needs SDL2 at runtime (`apt install libsdl2-2.0-0` / `dnf install SDL2`) and glibc
2.34+ (Ubuntu 22.04+, Debian 12+, Fedora 35+). macOS and Windows link SDL2 statically.
