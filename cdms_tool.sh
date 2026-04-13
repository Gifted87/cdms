#!/bin/bash

# CDMS Unified CLI Bridge
# Enables agents and users to "use the tools" from any shell environment.

API_URL="http://localhost:4000/api/v1"

# --- Usage ---
usage() {
    echo "CDMS Unified CLI Tool"
    echo "Usage: ./cdms_tool.sh [COMMAND] [ARGS...]"
    echo ""
    echo "Commands:"
    echo "  query \"<text>\" [mode]     Semantic search (mode: auto|semantic|nominal)"
    echo "  node <id>                Fetch node anatomy and relationships"
    echo "  history <id> <timestamp>  Temporal state reconstruction (ISO-8601)"
    echo "  mutations <since>         Recent mutation monitoring (e.g., 60m, 2h)"
    echo "  health                   Check system status"
    exit 1
}

if [ $# -lt 1 ]; then usage; fi

COMMAND=$1
shift

# --- Commands Implementation ---

case $COMMAND in
    health)
        curl -s "$API_URL/health/embedder" | jq .
        ;;

    query)
        QUERY=$1
        MODE=${2:-auto}
        if [ -z "$QUERY" ]; then usage; fi
        
        curl -s -X POST "$API_URL/query/unified" \
            -H "Content-Type: application/json" \
            -d "{\"query\": \"$QUERY\", \"reasoning_mode\": \"$MODE\"}" | jq .
        ;;

    node)
        NODE_ID=$1
        if [ -z "$NODE_ID" ]; then usage; fi
        
        curl -s -X GET "$API_URL/nodes/$NODE_ID" | jq .
        ;;

    history)
        NODE_ID=$1
        AS_OF=$2
        if [ -z "$NODE_ID" ] || [ -z "$AS_OF" ]; then usage; fi
        
        curl -s -X GET "$API_URL/nodes/$NODE_ID/history?as_of=$AS_OF" | jq .
        ;;

    mutations)
        SINCE=${1:-60m}
        curl -s -X GET "$API_URL/mutations?since=$SINCE" | jq .
        ;;

    *)
        usage
        ;;
esac
