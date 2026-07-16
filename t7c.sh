#!/usr/bin/env bash

# Strict error handling
set -euo pipefail

# --- Configuration Section ---
CONFIG_DIR="$HOME/.config/nodemixaholic-software/tiny-7coder"
mkdir -p "$CONFIG_DIR" > /dev/null 2>&1

# Source environment variables from .env if it exists in the script's directory
ENV_FILE="$CONFIG_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key=$(echo "${BASH_REMATCH[1]}" | xargs)
            val="${BASH_REMATCH[2]}"
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            export "$key=$val"
        fi
    done < "$ENV_FILE"
fi

# Model & Host Settings
MODEL="${MODEL_NAME:-deepseek-v4-flash:cloud}"
HOST="${API_HOST:-100.118.11.83:11434}"

# --- Dependency Check ---
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' is required to parse JSON safely. Please install it." >&2
    exit 1
fi

# --- System Prompt ---
SYSTEM_PROMPT="You are an autonomous Unix software agent. Your goal is to solve the user's request.
You execute your tasks by generating structured TOOL CALLS. You will run in a loop, observing the results of your actions until the task is complete.

You have access to 3 tools. To use a tool, output a JSON block matching one of these formats:

1. To execute a shell command:
{
  \"tool\": \"execute_bash\",
  \"command\": \"your command here\"
}

2. To read the full contents of a file:
{
  \"tool\": \"read_file\",
  \"path\": \"relative/or/absolute/path/to/file\"
}

3. To overwrite/create a file with specific content:
{
  \"tool\": \"replace_file\",
  \"path\": \"path/to/file\",
  \"content\": \"new content goes here\"
}

3. To append a file with specific content:
{
  \"tool\": \"append_file\",
  \"path\": \"path/to/file\",
  \"content\": \"new content goes here\"
}

If you have completely solved the user's request and no further actions are needed, output:
{
  \"tool\": \"done\",
  \"summary\": \"A short description of what you accomplished\"
}

Rules:
- Choose ONLY ONE tool call per turn.
- Output ONLY the raw JSON block. No markdown, no backticks, no conversational text.
- Do not overcomplicate shell commands."

# --- Initialize Stateful Background Shell ---
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tiny-7coder-XXXXXX")
FIFO_IN="$TMP_DIR/in"
FIFO_OUT="$TMP_DIR/out"

cleanup() {
    if [ -n "${TMP_DIR:-}" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT

mkfifo "$FIFO_IN" "$FIFO_OUT"
bash --noprofile --norc < "$FIFO_IN" > "$FIFO_OUT" 2>&1 &
SHELL_PID=$!

exec 3> "$FIFO_IN"
exec 4< "$FIFO_OUT"

# Persistent Shell Execution
execute_bg() {
    local cmd="$1"
    local sentinel="CMD_DONE_$(date +%s%N)"
    echo "$cmd" >&3
    echo "echo $sentinel" >&3
    while IFS= read -r line <&4; do
        [[ "$line" == *"$sentinel"* ]] && break
        echo "$line"
    done
}

# Identify the Host OS
[ -f /etc/os-release ] && . /etc/os-release || PRETTY_NAME="$(uname -s)"

# Run initialization in current directory
execute_bg "cd '$(pwd)'" > /dev/null

# --- UI & Input ---
echo "=== 7coder Autonomous Harness Active ==="
echo "Host: $HOST | Model: $MODEL | OS: $PRETTY_NAME"
echo "------------------------------------------------------------------"

printf "\n\033[1;35mUser Request >\033[0m "
if ! read -r USER_INPUT || [ -z "$USER_INPUT" ]; then
    echo "Empty input. Exiting."
    exit 0
fi

LAST_TOOL_OUTPUT="[Session initialized. Choose your first tool action.]"

# --- Autonomous Agent Loop ---
while true; do
    CURRENT_PWD=$(execute_bg "pwd" | tr -d '\n\r')

    echo -e "Thinking ($MODEL)..." 

    # Call LLM
    PAYLOAD=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p, stream: false}')
    RESPONSE=$(curl -s -X POST "http://$HOST/api/generate" -H "Content-Type: application/json" -d "$PAYLOAD")
    
    # Extract the tool JSON payload
    RAW_JSON=$(echo "$RESPONSE" | jq -r '.response' | sed -e 's/^`*json//' -e 's/`*$//' | tr -d '\n\r')

    # Validate JSON parsing
    if ! echo "$RAW_JSON" | jq . >/dev/null 2>&1; then
        echo "Error: Model did not return valid JSON. Retrying..."
        LAST_TOOL_OUTPUT="Error: Your output was not valid JSON. Please try again using strictly the JSON tool formats."
        continue
    fi

    TOOL_NAME=$(echo "$RAW_JSON" | jq -r '.tool')

    # --- Tool router ---
    case "$TOOL_NAME" in
        "execute_bash")
            CMD=$(echo "$RAW_JSON" | jq -r '.command')
            echo -e "\n[TOOL: BASH] $CMD"
            
            # Execute command statefully
            LAST_TOOL_OUTPUT=$(execute_bg "$CMD")
            echo "$LAST_TOOL_OUTPUT"
            ;;

        "read_file")
            FILE_PATH=$(echo "$RAW_JSON" | jq -r '.path')
            echo -e "\n[TOOL: READ] $FILE_PATH"
            
            if [ -f "$FILE_PATH" ]; then
                LAST_TOOL_OUTPUT=$(cat "$FILE_PATH")
                echo "$LAST_TOOL_OUTPUT"
            else
                LAST_TOOL_OUTPUT="Error: File '$FILE_PATH' does not exist."
                echo "$LAST_TOOL_OUTPUT"
            fi
            ;;

        "replace_file")
            FILE_PATH=$(echo "$RAW_JSON" | jq -r '.path')
            CONTENT=$(echo "$RAW_JSON" | jq -r '.content')
            echo -e "\n[TOOL: REPLACE TEXT] $FILE_PATH"
            
            # Overwrite file cleanly using cat heredoc to prevent shell escape corruption
            if echo "$CONTENT" > "$FILE_PATH"; then
                LAST_TOOL_OUTPUT="Success: File '$FILE_PATH' was successfully written."
                echo "File updated."
            else
                LAST_TOOL_OUTPUT="Error: Failed to write to '$FILE_PATH'."
                echo "$LAST_TOOL_OUTPUT"
            fi
            ;;
        
        "append_file")
            FILE_PATH=$(echo "$RAW_JSON" | jq -r '.path')
            CONTENT=$(echo "$RAW_JSON" | jq -r '.content')
            echo -e "\[TOOL: APPEND TEXT] $FILE_PATH"
            
            # Overwrite file cleanly using cat heredoc to prevent shell escape corruption
            if echo "$CONTENT" >> "$FILE_PATH"; then
                LAST_TOOL_OUTPUT="Success: File '$FILE_PATH' was successfully written."
                echo "File updated."
            else
                LAST_TOOL_OUTPUT="Error: Failed to write to '$FILE_PATH'."
                echo "$LAST_TOOL_OUTPUT"
            fi
            ;;

        "done")
            SUMMARY=$(echo "$RAW_JSON" | jq -r '.summary')
            echo -e "[TASK COMPLETE]"
            echo -e "Summary: $SUMMARY\n"
            break
            ;;

        *)
            echo "Error: Unknown tool '$TOOL_NAME' requested by model."
            LAST_TOOL_OUTPUT="Error: The tool '$TOOL_NAME' is invalid. Choose either execute_bash, read_file, replace_file, append_file, or done."
            ;;
    esac
done
