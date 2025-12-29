#!/bin/bash

# Test the unified query API endpoint with full debugging
echo "Testing /api/v1/query/unified endpoint..."
echo ""

response=$(curl -v -X POST http://localhost:4000/api/v1/query/unified \
  -H "Content-Type: application/json" \
  -d '{"query": "node_head.ex", "mode": "nominal"}' 2>&1)

echo "$response"
