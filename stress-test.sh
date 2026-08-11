#!/bin/bash
# stress_test.sh — generate HTTP load against the load balancer to trigger autoscaling
#
# Usage:
#   ./stress_test.sh <load-balancer-dns> [duration_seconds] [concurrent_requests]

URL="$1"
DURATION="${2:-300}"
CONCURRENCY="${3:-50}"

if [ -z "$URL" ]; then
  echo "Usage: ./stress_test.sh <load-balancer-dns> [duration_seconds] [concurrent_requests]"
  exit 1
fi

END=$((SECONDS + DURATION))
echo "Sending traffic to http://$URL for ${DURATION}s, ${CONCURRENCY} requests per batch..."
echo "Watch scaling happen in: EC2 console -> Auto Scaling Groups -> Activity tab"
echo ""

while [ $SECONDS -lt $END ]; do
  for i in $(seq 1 "$CONCURRENCY"); do
    curl -s -o /dev/null "http://$URL" &
  done
  wait
  echo "$(date +%T) — sent a batch of ${CONCURRENCY} requests"
done

echo ""
echo "Done. New instances take a few minutes to appear and register as healthy."