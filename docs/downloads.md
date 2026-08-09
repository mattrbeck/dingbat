# Downloads

The browser version at [dingbat.gg](https://dingbat.gg) is the recommended way to play.
For the desktop app, the [**Latest build**](../../../releases/tag/latest) release always
carries current Linux (`.tar.gz`), macOS (`.dmg`) and Windows (`.exe`) binaries, rebuilt
from `main` on every push:

| Platform | Download |
|---|---|
| Linux x64 | [`dingbat-linux-x64.tar.gz`](../../../releases/download/latest/dingbat-linux-x64.tar.gz) |
| macOS (Apple Silicon) | [`dingbat-macos.dmg`](../../../releases/download/latest/dingbat-macos.dmg) |
| Windows x64 | [`dingbat-windows-x64.exe`](../../../releases/download/latest/dingbat-windows-x64.exe) |

<!-- These are /releases/download/latest/<file> (the `latest` TAG), not
     /releases/latest/download/<file> (the latest non-prerelease RELEASE).
     The rolling build is deliberately a prerelease, so the second form 404s
     until a v* tag is cut. The two URLs differ only in word order. -->


Those are development builds and change without notice; verify them against
`SHA256SUMS.txt` on the release if you care to. Tagged `v*` releases, when cut, publish
the same three files on the [Releases](../../../releases) page.

For a build of one specific commit, open its run under
[Actions → Build](../../../actions/workflows/build.yml) and download from that run's
**Artifacts** section.

Those binaries are **unsigned**, so the OS warns on first launch — on macOS, open
**System Settings → Privacy & Security** and click **Open Anyway**; on Windows, click
**More info → Run anyway**. Once only.

The Linux build needs SDL2 present at runtime (`apt install libsdl2-2.0-0`, or
`dnf install SDL2`); macOS and Windows link it statically and need nothing installed.
It is built against glibc 2.34, so it runs on Ubuntu 22.04+, Debian 12+ and Fedora 35+.
