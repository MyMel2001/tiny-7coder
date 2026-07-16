#!/bin/sh
#
# goal.sh
#
# Goal-driven wrapper around tiny-7coder.
#
# Usage:
#   ./goal.sh "Your goal here"
#

set -eu

MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
WORKDIR="${RALPH_WORKDIR:-.ralph-tiny-7coder}"

mkdir -p "$WORKDIR"

GOAL_FILE="$WORKDIR/goal.txt"
STATE_FILE="$WORKDIR/state.txt"
LOG_FILE="$WORKDIR/run.log"
DONE_FILE="$WORKDIR/DONE"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 \"goal description\""
    exit 1
fi

GOAL="$*"

if [ ! -f "$GOAL_FILE" ]; then
    printf '%s\n' "$GOAL" > "$GOAL_FILE"
fi

if [ ! -f "$STATE_FILE" ]; then
    {
        echo "Ralph loop started: $(date)"
        echo ""
        echo "Goal:"
        cat "$GOAL_FILE"
        echo ""
    } > "$STATE_FILE"
fi

rm -f "$DONE_FILE"

iteration=1

while [ "$iteration" -le "$MAX_ITERATIONS" ]; do
    echo "======================================"
    echo "Ralph iteration $iteration / $MAX_ITERATIONS"
    echo "======================================"

    PROMPT=$(cat <<EOF
You are running inside a Ralph-style autonomous loop.

The user goal is:

$(cat "$GOAL_FILE")

Current state:

$(cat "$STATE_FILE")

Your job:
- Continue working toward the goal.
- Inspect the current system state.
- Make the next useful change.
- Use tiny-7coder tools normally.
- If the goal is fully complete, output exactly:
DONE

Do not claim completion unless the goal is actually satisfied.
EOF
)

    echo "[$(date)] iteration $iteration" >> "$LOG_FILE"

    RESPONSE=$(tiny-7coder "$PROMPT" 2>&1 || true)

    printf '%s\n' "$RESPONSE" >> "$LOG_FILE"

    if printf '%s\n' "$RESPONSE" | grep -qx "DONE"; then
        echo "Goal completed."
        touch "$DONE_FILE"
        exit 0
    fi

    {
        echo ""
        echo "----- iteration $iteration result -----"
        echo "$RESPONSE"
    } >> "$STATE_FILE"

    iteration=$((iteration + 1))
done

echo "Reached maximum iterations ($MAX_ITERATIONS)."
echo "State preserved in $WORKDIR"
exit 1
