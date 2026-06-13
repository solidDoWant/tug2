# casecache — workshop case-insensitive-descent shim

`LD_PRELOAD` shim for the **native-Linux** Insurgency dedicated server (`srcds_linux`).

## The problem it solves

With `-workshop`, the engine mounts every subscribed workshop item as a separate **loose-file
search path** (~161 of them). On Linux, whenever an exact-case file open misses, the engine
(`dedicated_srv.so`) falls back to a **recursive, case-insensitive directory walk**
(`__wrap_fopen → pathmatch → Descend → readdir`) — and it does this **from the filesystem root**
for every absolute path. During a map load the engine precaches thousands of assets, each probed
against all ~161 search paths, so the walk runs millions of times:

* **~15 million filesystem syscalls per map change** (measured: 5.5M `getdents64`, 3.4M `access`,
  3.1M `openat`, 2.7M `statx`).
* Map changes take **2–13 minutes**, and the end-of-round mapcycle validation
  (`CINSRules::GetNextLevelName → IsMapValid` over the whole mapcycle) runs this on the **main
  thread** until the engine watchdog `abort()`s → the intermittent **crashes**.

This does not happen on the Windows/Wine build because Windows filesystems are natively
case-insensitive, so there is no descent shim in the engine.

## How it works

At first use the shim builds a **single, immutable, case-folded hash index** of the entire game
tree under `/opt/insurgency-server` (plus the listings of `/` and `/opt`, which the root-anchored
descent always walks). After the build it is **read-only**, so every interposed call is a
**lock-free** hash probe:

* `open`/`openat`/`fopen`/`stat`/`lstat`/`access` (+ `*64`/`__xstat` variants) resolve
  case-insensitively in O(1). Existing files resolve immediately (the engine's exact attempt
  succeeds, so it never enters its descent); genuine misses return `ENOENT` **with no syscall**.
* `opendir`/`readdir` serve directory listings from the index, so the descent the engine still
  performs on a miss is memory-speed (no `getdents`).

Result: **~15M syscalls → ~500K**, the descent is no longer CPU-bound, and the watchdog crashes
are eliminated.

## Correctness / safety

* **Writable subtrees are never indexed** and always pass through to libc unchanged
  (`download`, `logs`, `cfg`, `addons/sourcemod/{data,logs}`, `console.log`).
* **Authoritative `ENOENT` only when an indexed ancestor proves absence** — if any directory was
  not indexed (e.g. a build gap), the call falls through to a real libc call. A failed/empty
  build therefore degrades to a **pure passthrough**, never to false `ENOENT`.
* **Files the srcds process creates at runtime** are tracked in a small dirty-set so later reads
  of them fall through to libc.
* **Kill switch:** set `CASECACHE_DISABLE=1` to make the shim a pure passthrough without a
  rebuild.
* On startup it logs one line to stderr: `[casecache] active: indexed <N> nodes under …` (or
  nothing in the disabled case) — use it to confirm the shim is live.

### Assumption

The game tree under `/opt/insurgency-server` is **static at runtime** — workshop content is baked
into the image at build time (no runtime volume). The index is built once. If runtime workshop
**updates** are ever enabled (the engine rewriting `steamapps/workshop/content`), the index can go
stale and return false `ENOENT` for newly written files; disable runtime updates or rebuild the
image in that case.

## Building

`srcds_linux` is **i386**, so the shim must be built `-m32`:

```sh
make            # needs gcc-multilib + libc6-dev-i386
make verify     # confirms ELFCLASS32 / Intel 80386
```

A 64-bit `.so` is silently ignored by the loader (`wrong ELF class: ELFCLASS32`); that warning,
emitted by the 64-bit `server-runner`/Xvfb wrapper processes, is expected — only the 32-bit
`srcds_linux` loads the shim. Confirm with `grep casecache /proc/<srcds-pid>/maps`.

## Deploying

Build the shim (see `Dockerfile` here for the image build stage), copy it into the image, and set
`LD_PRELOAD` for the server. Only applies to the **native** (`srcds_linux`) build — it is a no-op
of no value on the Wine build.
