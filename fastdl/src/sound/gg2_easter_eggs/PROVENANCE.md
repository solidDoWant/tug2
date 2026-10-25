# gg2_easter_eggs sounds

## `sniper_*.ogg`

Dota 2 Sniper voice lines (© Valve), downloaded 2026-10-25 from the
[Dota 2 Wiki's Sniper/Responses page](https://dota2.fandom.com/wiki/Sniper/Responses), which hosts
them as 64 kbps mono 44.1 kHz MP3s named `Vo_sniper_snip_<line>.mp3`. Each was converted with
`ffmpeg -ac 1 -ar 44100 -c:a libvorbis -q:a 5` to match the game's own voice lines, then renamed
`sniper_<line>.ogg` (the `ability_` prefix dropped from the `assass_*` ones).

| File | Line |
| --- | --- |
| `sniper_assass_01` | Picked 'em off. |
| `sniper_assass_02` | Easy as shooting gnats. |
| `sniper_assass_03` | Boom, headshot! |
| `sniper_assass_04` | You got peeped! |
| `sniper_assass_12` | Did ya see that? |
| `sniper_attack_07` | Easy shot. |
| `sniper_kill_01` | Shot to Hell! |
| `sniper_kill_02` | Takes one to shoot one. |
| `sniper_kill_03` | Bullseye! |
| `sniper_kill_05` | What a dum-dum! |
| `sniper_kill_06` | You make a great bullet catcher. |
| `sniper_kill_07` | Your life's a flash in the pan. |
| `sniper_kill_08` | Now that's what I call stoppin' power. |
| `sniper_kill_09` | That was your warning shot. |
| `sniper_kill_10` | Kill shot! |
| `sniper_kill_11` | Ha ha ha ha! |
| `sniper_kill_13` | Parting shot - boom! |
| `sniper_lasthit_04` | On target! |
| `sniper_tf2_01` | Thanks for standing still, ganker! |
| `sniper_tf2_03` | Thanks for standing still. |
| `sniper_tf2_04` | Say goodbye to your head! |
| `sniper_tf2_07` | I'm polite and efficient. |
| `sniper_win_03` | He shoots, he scores! |

These ship at fixed paths (see the sounds step in `fastdl/tools/build.sh`), so a changed file never
reaches a client that already has the old one. To change one, add it under a new name and update
`gg2_easter_eggs.sp`.
