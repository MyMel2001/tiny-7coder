#!/usr/bin/env bash

# Strict error handling
set -euo pipefail

# === CONFIGURATION ===
PROJECT_DIR="$(realpath .)"
T7C_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

cd "$T7C_DIR"
# Path to your .env file
ENV_FILE=".env"

if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # 1. Skip lines starting with # (comments) or empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # 2. Parse key and value (split on the first '=')
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key=$(echo "${BASH_REMATCH[1]}" | xargs) # trim whitespace from key
            val="${BASH_REMATCH[2]}"

            # 3. Strip leading/trailing single or double quotes from value
            val="${val%\"}"
            val="${val#\"}"
            val="${val%\'}"
            val="${val#\'}"

            # 4. Export the variable
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
# Unique temporary paths for persistent background shell (Haiku, Mac, Linux friendly)
TMP_DIR=$(mktemp -d -t 7cl-harness-XXXXXX)
FIFO_IN="$TMP_DIR/bash_in"
FIFO_OUT="$TMP_DIR/bash_out"

# Cleanup background processes and FIFOs on exit
cleanup() {
    rm -rf "$TMP_DIR"
    # Kill background jobs safely
    kill $(jobs -p) 2>/dev/null || true
}
trap cleanup EXIT

# 1. Initialize background persistent shell
mkfifo "$FIFO_IN"
mkfifo "$FIFO_OUT"

# Start background interactive bash routing stderr to stdout
bash --noprofile --norc -i < "$FIFO_IN" > "$FIFO_OUT" 2>&1 &

# Open descriptors to prevent EOF on FIFOs
exec 3> "$FIFO_IN"
exec 4< "$FIFO_OUT"

# Function to execute a command in the persistent background shell
execute_bg_command() {
    local cmd="$1"
    local sentinel="CMD_DONE_$(cat /dev/urandom | env LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
    
    # Write command and unique sentinel to the persistent shell
    echo "$cmd" >&3
    echo "echo $sentinel" >&3
    
    # Read response line-by-line until we hit the sentinel
    while IFS= read -r line <&4; do
        if [[ "$line" == *"$sentinel"* ]]; then
            break
        fi
        echo "$line"
    done
}

# Define the Tool schema using the OpenAI standard "function" format
TOOLS_JSON=$(cat <<EOF
[
  {
    "type": "function",
    "function": {
      "name": "execute_bash",
      "description": "Executes a command inside a persistent, stateful Bash session on the user's computer. Use this to read/write files, inspect directories, and run scripts.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The shell command to run."
          }
        },
        "required": ["command"]
      }
    }
  }
]
EOF
)

# Start conversation state with an initial System Instruction
MESSAGES=$(cat <<EOF
[
  {
    "role": "system",
    "content": "You are a stateful terminal assistant. You have access to a tool called 'execute_bash' to interact with the system. You must run commands to solve the user's problem. When you run a command, you will see its real-time output in the next step. Keep running commands sequentially until the task is complete."
  }
]
EOF
)

echo "=== OpenAI-Compatible Bash Harness Activated ==="
echo "Endpoint: $API_URL"
echo "Model: $MODEL"
echo "Operating System: $(uname -s)"
echo "Type your request below (e.g. 'list files in the current folder')"
echo "------------------------------------------------------------------"

while true; do
    echo "User > "
    read USER_INPUT

    # Append user message to conversation history
    MESSAGES="PREVIOUS HISTORY: $MESSAGES\n\nNOW: $USER_INPUT"

    # Agent loop (handling multiple sequential tool execution steps if needed)
    while true; do
        echo "Thinking..."
        
        # Call OpenAI-compatible Chat Completions API
        API_RESPONSE=$(curl -s "$API_URL" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d $(jq -n \
                --arg model "$MODEL" \
                --argjson tools "$TOOLS_JSON" \
                --argjson messages "$MESSAGES" \
                '{model: $model, tools: $tools, messages: $messages}')
        )

        # Check for API-level errors
        if echo "$API_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
            echo "API Error: $(echo "$API_RESPONSE" | jq -r '.error.message')" >&2
            break 2
        fi

        # Extract choice and message data
        CHOICE=$(echo "$API_RESPONSE" | jq '.choices[0]')
        MESSAGE=$(echo "$CHOICE" | jq '.message')
        FINISH_REASON=$(echo "$CHOICE" | jq -r '.finish_reason')

        # Append assistant's response to history (crucial for maintaining OpenAI's tool state)
        MESSAGES=$(echo "$MESSAGES" | jq --argjson msg "$MESSAGE" '. + [$msg]')

        # Check if the model decided to call a tool
        if [ "$FINISH_REASON" = "tool_calls" ]; then
            # Handle the tool call
            TOOL_CALL=$(echo "$MESSAGE" | jq '.tool_calls[0]')
            TOOL_ID=$(echo "$TOOL_CALL" | jq -r '.id')
            TOOL_NAME=$(echo "$TOOL_CALL" | jq -r '.function.name')
            
            # Extract and parse the tool arguments
            TOOL_ARGS_RAW=$(echo "$TOOL_CALL" | jq -r '.function.arguments')
            TOOL_CMD=$(echo "$TOOL_ARGS_RAW" | jq -r '.command')

            echo -e "\n[Tool Request - $TOOL_NAME]: \033[1;33m$TOOL_CMD\033[0m"
            
            # Run the command in our persistent background shell
            TOOL_OUTPUT=$(execute_bg_command "$TOOL_CMD")
            
            # Print execution output locally to terminal
            echo "$TOOL_OUTPUT"

            # Append tool execution result using standard OpenAI response format
            MESSAGES=$(echo "$MESSAGES" | jq \
                --arg id "$TOOL_ID" \
                --arg output "$TOOL_OUTPUT" \
                --arg name "$TOOL_NAME" \
                '. + [{"role": "tool", "tool_call_id": $id, "name": $name, "content": $output}]')
        else
            # Claude/Model has completed the task and responded with final text
            TEXT_RESPONSE=$(echo "$MESSAGE" | jq -r '.content')
            if [ "$TEXT_RESPONSE" != "null" ]; then
                echo -e "\nAssistant > $TEXT_RESPONSE"
            fi
            break
        fi
    done
done
