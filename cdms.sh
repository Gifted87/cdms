#!/bin/bash
# ------------------------------------------------------------------------------
# ACMS Portability Loader (The Cartridge Interface)
# ------------------------------------------------------------------------------
# Usage: ./acms.sh [NODE_NAME] [PORT]
# Example: ./acms.sh "primary_cortex" 4000
# ------------------------------------------------------------------------------

# 1. Parameter Resolution
NAME="${1:-cms}"
PORT="${2:-4000}"
export ACMS_NODE_NAME="$NAME"
export ACMS_PORT="$PORT"

# 2. Data Directory Resolution (The Context Slot)
# Each instance gets its own isolated 'Cognitive Branch' (folder)
if [ -z "$ACMS_DATA_DIR" ]; then
    export ACMS_DATA_DIR="$(pwd)/memory_cartridges/${NAME}"
    echo "[ACMS] Git-like mode: Using memory cartridge at: $ACMS_DATA_DIR"
else
    echo "[ACMS] Manual cartridge detected at: $ACMS_DATA_DIR"
fi

# Ensure the cartridge exists
mkdir -p "$ACMS_DATA_DIR"

# 3. Environment Setup
export REPLACE_OS_VARS=true
export MIX_ENV=dev

# 4. Identity & Isolation
# We bind ONLY to loopback to prevent accidental cluster meshes on public LANs
# The node name ensures isolation from other local Erlang nodes (e.g., LiveBook)
NODE_ID="${NAME}@127.0.0.1"

echo "[ACMS] Initializing Cognitive Core..."
echo "       Identity: $NODE_ID"
echo "       Port:     $PORT"

# 5. Boot Sequence
# We intentionally use mix phx.server for the Dev/Prototype phase.
# In production, this would be replaced by the release binary command.
elixir --name "$NODE_ID" --cookie "secure_cognitive_cookie" -S mix phx.server
