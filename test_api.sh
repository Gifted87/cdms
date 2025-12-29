#!/bin/bash

# Test the unified query API endpoint
echo "Testing /api/v1/query/unified endpoint..."
echo ""

response=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  -X POST http://localhost:4000/api/v1/query/unified \
  -H "Content-Type: application/json" \
  -d '{"query": "node_head.ex", "mode": "nominal"}')

http_status=$(echo "$response" | grep "HTTP_STATUS" | cut -d: -f2)
body=$(echo "$response" | sed '/HTTP_STATUS/d')

echo "HTTP Status: $http_status"
echo ""
echo "Response Body:"
echo "$body" | jq '.' 2>/dev/null || echo "$body"
