# casecache — 32-bit (i386) LD_PRELOAD shim for the native-Linux Insurgency server.
# srcds_linux is i386, so the .so MUST be built -m32 (a 64-bit .so is silently ignored
# by the loader with "wrong ELF class": that warning from the 64-bit server-runner/Xvfb
# wrappers is expected; only the 32-bit srcds_linux loads it).
#
# Requires a 32-bit toolchain: `apt-get install gcc-multilib libc6-dev-i386`
# (or nix: `nix shell nixpkgs#pkgsi686Linux.gcc`).

CC      ?= gcc
CFLAGS  ?= -m32 -shared -fPIC -O2 -Wall -Wno-overflow
LDLIBS  ?= -ldl -lpthread
OUT     ?= casecache.so

$(OUT): casecache.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

.PHONY: clean verify
clean:
	rm -f $(OUT)

# Sanity-check that the built object is 32-bit (ELFCLASS32 / Intel 80386).
verify: $(OUT)
	@readelf -h $(OUT) | grep -E 'Class|Machine'
