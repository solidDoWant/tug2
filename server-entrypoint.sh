#!/bin/bash
set -euxo pipefail

# Start Xvfb in the background for Wine to use
# This provides a virtual X display to prevent Windows console API errors
export DISPLAY=:99
Xvfb "${DISPLAY}" -screen 0 1024x768x24 &
XVFB_PID=$!

# Wait a moment for Xvfb to initialize, or fail if it doesn't start fast enough
WAIT_START_TIME=$(date +%s)
MAX_WAIT_TIME="${MAX_WAIT_TIME:-3}"
while ! xdpyinfo -display :99 > /dev/null 2>&1; do
    EC=$?
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - WAIT_START_TIME))
    if [ "$ELAPSED_TIME" -ge "$MAX_WAIT_TIME" ]; then
        echo "X server failed to start within ${MAX_WAIT_TIME} seconds" >&2
        exit $EC
    fi
    sleep 0.1
done

# Remove old console.log if it exists
rm -f /opt/insurgency-server/insurgency/console.log

# Start tailing console.log to stdout in the background
# Use --retry to handle the file not existing yet
tail -F /opt/insurgency-server/insurgency/console.log 2>/dev/null &
TAIL_PID=$!

# Ensure background processes are killed when this script exits
trap "kill $TAIL_PID $XVFB_PID 2>/dev/null || true" EXIT

# Execute the server with all passed arguments, redirecting stdin from /dev/null
# This prevents Wine from trying to read console input which doesn't work in Docker
exec "$@"
