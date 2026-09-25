# gg2_bomber voice lines

Taken unmodified from the `allahuakbar/` directory of
[thecannons/Insurgency-dy-sourcemod](https://github.com/thecannons/Insurgency-dy-sourcemod) (the DY
coop server's repo, 2019), where `bsuicide_bomb_redux_naong.sp` played them. That repo carries no
license and does not say where the recordings came from.

| File | Played |
| --- | --- |
| `allahu_akbar01-02.ogg`, `detonate01-02.ogg` | when a bomber lights its fuse or panics |
| `roam01-11.ogg` | periodically while an armed bomber hunts |

All are mono 44.1 kHz Vorbis, the same format as the game's own voice lines.

These ship at fixed paths (see the sounds step in `fastdl/tools/build.sh`), so a changed file never
reaches a client that already has the old one. To change one, add it under a new name and update
`gg2_bomber.sp`.
