#!/usr/bin/env bash

set -eo pipefail

# === CONFIGURATION ===
PROJECT_DIR="$(realpath .)"
T7C_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

cd "$T7C_DIR"

ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key=$(echo "${BASH_REMATCH[1]}" | xargs)
            val="${BASH_REMATCH[2]}"

            val="${val%\"}"
            val="${val#\"}"
            val="${val%\'}"
            val="${val#\'}"

            export "$key=$val"
        fi
    done < "$ENV_FILE"
else
    echo "Warning: $ENV_FILE file not found." >&2
fi

API_URL="${OPENAI_API_BASE:-https://api.openai.com/v1}/chat/completions"
MODEL="${OPENAI_MODEL_NAME:-gpt-4o-mini}"
API_KEY="${OPENAI_API_KEY:-}"

if [ -z "$API_KEY" ]; then
    echo "Error: OPENAI_API_KEY environment variable is not set." >&2
    exit 1
fi

cd "$PROJECT_DIR"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/7cl-harness.XXXXXX")

FIFO_IN="$TMP_DIR/bash_in"
FIFO_OUT="$TMP_DIR/bash_out"

cleanup() {
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkfifo "$FIFO_IN"
mkfifo "$FIFO_OUT"

bash --noprofile --norc -i \
    < "$FIFO_IN" \
    > "$FIFO_OUT" \
    2>&1 &

exec 3>"$FIFO_IN"
exec 4<"$FIFO_OUT"

execute_bg_command() {
    local cmd="$1"
    local sentinel="CMD_DONE_${RANDOM}_${RANDOM}"

    echo "$cmd" >&3
    echo "echo $sentinel" >&3

    while IFS= read -r line <&4; do
        if [[ "$line" == *"$sentinel"* ]]; then
            break
        fi
        echo "$line"
    done
}

TOOLS_JSON=$(cat <<EOF
[
  {
    "type": "function",
    "function": {
      "name": "execute_bash",
      "description": "Execute a command in a persistent Bash session.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "Command to execute"
          }
        },
        "required": ["command"]
      }
    }
  }
]
EOF
)

MESSAGES=$(cat <<EOF
[
  {
    "role": "system",
    "content": "You are a stateful terminal assistant. You have access to execute_bash. Use it to interact with the user's computer. Run commands when needed and continue until the task is complete."
  }
]
EOF
)

echo "=== OpenAI-Compatible Bash Harness Activated ==="
echo "Endpoint: $API_URL"
echo "Model: $MODEL"
echo "Operating System: $(uname -s)"
echo "Type your request below."
echo "------------------------------------------------------------------"

while true; do
    echo "User > "

    if ! read -r USER_INPUT; then
        echo
        echo "Exiting."
        break
    fi

    MESSAGES=$(echo "$MESSAGES" |
        jq --arg msg "$USER_INPUT" \
        '. + [{"role":"user","content":$msg}]'
    )

    while true; do
        echo "Thinking..."

        REQUEST_BODY=$(jq -n \
            --arg model "$MODEL" \
            --argjson tools "$TOOLS_JSON" \
            --argjson messages "$MESSAGES" \
            '{
                model:$model,
                tools:$tools,
                messages:$messages
            }'
        )

        API_RESPONSE=$(curl -s "$API_URL" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            --data-binary "$REQUEST_BODY"
        )

        if echo "$API_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
            echo "API Error:"
            echo "$API_RESPONSE" | jq '.error'
            break
        fi

        CHOICE=$(echo "$API_RESPONSE" | jq '.choices[0]')
        MESSAGE=$(echo "$CHOICE" | jq '.message')
        FINISH_REASON=$(echo "$CHOICE" | jq -r '.finish_reason')

        MESSAGES=$(echo "$MESSAGES" |
            jq --argjson msg "$MESSAGE" \
            '. + [$msg]'
        )

        if [ "$FINISH_REASON" = "tool_calls" ]; then

            TOOL_CALL=$(echo "$MESSAGE" | jq '.tool_calls[0]')

            TOOL_ID=$(echo "$TOOL_CALL" |
                jq -r '.id'
            )

            TOOL_NAME=$(echo "$TOOL_CALL" |
                jq -r '.function.name'
            )

            TOOL_ARGS_RAW=$(echo "$TOOL_CALL" |
                jq -r '.function.arguments'
            )

            TOOL_CMD=$(echo "$TOOL_ARGS_RAW" |
                jq -r '.command'
            )

            echo
            echo "[Tool Request]"
            echo "$TOOL_CMD"
            echo

            TOOL_OUTPUT=$(execute_bg_command "$TOOL_CMD")

            echo "$TOOL_OUTPUT"

            MESSAGES=$(echo "$MESSAGES" |
                jq \
                --arg id "$TOOL_ID" \
                --arg name "$TOOL_NAME" \
                --arg output "$TOOL_OUTPUT" \
                '. + [{
                    role:"tool",
                    tool_call_id:$id,
                    name:$name,
                    content:$output
                }]'
            )

        else
            TEXT_RESPONSE=$(echo "$MESSAGE" |
                jq -r '.content'
            )

            if [ "$TEXT_RESPONSE" != "null" ]; then
                echo
                echo "Assistant > $TEXT_RESPONSE"
            fi

            break
        fi
    done
done

