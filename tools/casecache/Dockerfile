# Build stage for the casecache i386 LD_PRELOAD shim.
#
# Add to the main Dockerfile (or build standalone) and copy /casecache.so into the native
# gameserver image, then set LD_PRELOAD. Example wiring in the gameserver-main (native) stage:
#
#     COPY --from=casecache-builder /casecache.so /opt/insurgency-server/casecache.so
#     ENV LD_PRELOAD=/opt/insurgency-server/casecache.so
#
# (LD_PRELOAD via ENV also reaches the 64-bit server-runner/Xvfb wrappers, which log a harmless
#  "wrong ELF class" and ignore it; only the 32-bit srcds_linux loads the shim. To avoid that log
#  noise, set LD_PRELOAD on the srcds child only, from server-runner, instead of via ENV.)

FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db AS casecache-builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc-multilib libc6-dev-i386 \
    && rm -rf /var/lib/apt/lists/*
COPY casecache.c /casecache.c
RUN gcc -m32 -shared -fPIC -O2 -Wall -Wno-overflow -o /casecache.so /casecache.c -ldl -lpthread \
    && readelf -h /casecache.so | grep -qE 'Class:\s+ELF32' \
    && readelf -h /casecache.so | grep -qE 'Machine:\s+Intel 80386'
