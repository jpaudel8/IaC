#!/usr/bin/env bash
# stress-test.sh — drive enough HTTP load at the ALB to force a real scale-out.
#
# Usage:
#   ./stress-test.sh [url-or-dns] [duration_seconds] [workers] [requests_per_batch]
#
# All arguments optional. With no URL it reads the ALB name out of the CloudFormation
# stack, so there is no hardcoded hostname to go stale after a redeploy.
#
#   ./stress-test.sh                                   # 600s, 40 workers, auto-discover URL
#   ./stress-test.sh my-alb-123.us-east-1.elb.amazonaws.com
#   ./stress-test.sh http://my-alb-123.../ 300 60

set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK="${STACK:-my-web-server-main}"

URL_IN="${1:-}"
DURATION="${2:-600}"
WORKERS="${3:-40}"    # concurrent connections
BATCH="${4:-200}"     # requests per curl invocation, reusing one TCP connection

# ---------------------------------------------------------------- resolve target
if [ -z "$URL_IN" ]; then
  echo "No URL given — reading it from stack '$STACK'..."
  URL_IN=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerDNS'].OutputValue" \
    --output text 2>/dev/null)
  if [ -z "$URL_IN" ] || [ "$URL_IN" = "None" ]; then
    echo "ERROR: could not read the ALB from stack '$STACK'."
    echo "Pass it directly:  ./stress-test.sh <load-balancer-dns> [duration] [workers]"
    exit 1
  fi
fi

# Normalise once, idempotently. Strip any scheme the caller supplied and re-add exactly
# one — otherwise "http://$URL" on an already-qualified URL produces http://http://host,
# whose hostname is literally "http", so every request dies in DNS and the ALB sees
# zero traffic while the script cheerfully reports it is sending batches.
URL="${URL_IN#http://}"
URL="${URL#https://}"
URL="http://${URL%/}/"

# ---------------------------------------------------------------- preflight
echo "Target: $URL"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$URL" 2>/dev/null)
if [ "$CODE" != "200" ]; then
  echo "ERROR: preflight request returned '$CODE' (expected 200)."
  echo "Nothing is generated until this passes — fix the URL or the targets first."
  exit 1
fi
echo "Preflight OK (HTTP 200)"
echo

# ---------------------------------------------------------------- live watcher
ASG=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='AutoScalingGroupName'].OutputValue" \
  --output text 2>/dev/null || echo "")
TG=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" \
  --output text 2>/dev/null || echo "")

watch_scaling() {
  while :; do
    CAP=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$ASG" \
      --query "AutoScalingGroups[0].[DesiredCapacity,length(Instances)]" \
      --output text 2>/dev/null | tr '\t' '/')
    HEALTHY=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
      --output text 2>/dev/null)
    printf '  [%s]  desired/instances: %-8s healthy targets: %s\n' \
      "$(date +%T)" "${CAP:-?}" "${HEALTHY:-?}"
    sleep 20
  done
}

WATCH_PID=""
if [ -n "$ASG" ] && [ "$ASG" != "None" ] && [ -n "$TG" ] && [ "$TG" != "None" ]; then
  watch_scaling &
  WATCH_PID=$!
fi

# ---------------------------------------------------------------- load
WORKDIR=$(mktemp -d)
cleanup() {
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  kill $(jobs -p) 2>/dev/null
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# One curl process fetching the URL $BATCH times reuses a single keep-alive connection.
# Forking one curl per request instead — as the old script did — caps throughput at the
# fork rate of the machine, which on Git Bash for Windows is only a few dozen per second.
URLS=""
for _ in $(seq 1 "$BATCH"); do URLS="$URLS $URL"; done

END=$(( $(date +%s) + DURATION ))

worker() {
  local id=$1
  while [ "$(date +%s)" -lt "$END" ]; do
    curl -s --max-time 60 $URLS >/dev/null 2>&1
    echo x >> "$WORKDIR/w$id"
  done
}

echo "Load: $WORKERS workers x $BATCH keep-alive requests per batch, for ${DURATION}s"
echo "Scaling shows up in: EC2 console -> Auto Scaling Groups -> $ASG -> Activity"
echo

START=$(date +%s)
for i in $(seq 1 "$WORKERS"); do worker "$i" & done
wait $(jobs -p 2>/dev/null | grep -v "^$WATCH_PID$") 2>/dev/null

ELAPSED=$(( $(date +%s) - START ))
BATCHES=$(cat "$WORKDIR"/w* 2>/dev/null | wc -l)
TOTAL=$(( BATCHES * BATCH ))

echo
echo "Done in ${ELAPSED}s — ~${TOTAL} requests (~$(( TOTAL / (ELAPSED > 0 ? ELAPSED : 1) ))/s)"
echo "Scale-in is deliberately slow; the group drifts back to MinSize over ~10-15 min."
