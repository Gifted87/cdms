#!/bin/bash
# ------------------------------------------------------------------------------
# CDMS Global CLI Launcher
# ------------------------------------------------------------------------------
# Usage: cdms [--port 4000] [--mode generative|deterministic] [--name my_node]
# ------------------------------------------------------------------------------

# Resolve the directory of the CDMS codebase to run Mix from
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_DIR="$( cd "$( dirname "$SCRIPT_PATH" )" &> /dev/null && pwd )"
TARGET_DIR="$PWD"

# Native .env loader
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# Parsing Arguments
PORT=4000
MODE="generative"
NAME="cms_$(basename "$TARGET_DIR" | tr -cd '[:alnum:]_')"

while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --name)
      NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown parameter: $1"
      exit 1
      ;;
  esac
done

export ACMS_NODE_NAME="$NAME"
export ACMS_PORT="$PORT"
export CDMS_TARGET_DIR="$TARGET_DIR"
export CDMS_MODE="$MODE"

# 2. Data Directory Resolution (The memory model)
# We store the mnesia and vectors in a .cdms_model hidden directory inside the target.
export ACMS_DATA_DIR="$TARGET_DIR/.cdms_model"
echo "[ACMS] Modeling directory: $TARGET_DIR"
echo "[ACMS] Model state path: $ACMS_DATA_DIR"
mkdir -p "$ACMS_DATA_DIR"

# 3. Environment Setup
export REPLACE_OS_VARS=true
export MIX_ENV=dev

# 4. Identity & Isolation
# Append a random hex to avoid name collisions if running multiple in same dir
RAND_SUFFIX=$(openssl rand -hex 2)
NODE_ID="${NAME}_${RAND_SUFFIX}@127.0.0.1"

echo "[ACMS] Initializing Cognitive Core..."
echo "       Identity: $NODE_ID"
echo "       Port:     $PORT"
echo "       Mode:     $MODE"

# 5. Boot Sequence
cd "$SCRIPT_DIR" || exit 1
iex --name "$NODE_ID" --cookie "secure_cognitive_cookie" -S mix