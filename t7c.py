#!/usr/bin/env python3
import os
import sys
import json
import platform
import subprocess
import ssl
import urllib.request
import urllib.error

# --- Configuration Section ---
CONFIG_DIR = os.path.expanduser("~/.config/nodemixaholic-software/tiny-7coder")
ENV_FILE = os.path.join(CONFIG_DIR, ".env")

# Ensure config directory and .env file exist
os.makedirs(CONFIG_DIR, exist_ok=True)
if not os.path.exists(ENV_FILE):
    with open(ENV_FILE, "w") as f:
        f.write("# tiny-7coder configuration\n")

# Load environment variables manually to avoid dependencies
if os.path.exists(ENV_FILE):
    with open(ENV_FILE, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                # Strip potential quotes and carriage returns
                key = key.strip()
                val = val.strip().strip("'\"").replace("\r", "")
                os.environ[key] = val

# Set defaults
MODEL = os.environ.get("MODEL", "deepseek-v4-flash:cloud")
HOST = os.environ.get("HOST", "100.118.11.83:11434")
VERIFY_SSL = os.environ.get("VERIFY_SSL", "true").lower() not in ("false", "0", "no")


PROJECT_DIR = os.getcwd()
# --- Helper Tool Functions ---
def read_file(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return f"Error reading file: {str(e)}"

def append_file(filepath, content):
    try:
        with open(filepath, "a", encoding="utf-8") as f:
            f.write(content + "\n")
        return f"Successfully appended to {filepath}"
    except Exception as e:
        return f"Error appending to file: {str(e)}"

def replace_file(filepath, content):
    try:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(content)
        return f"Successfully wrote to {filepath}"
    except Exception as e:
        return f"Error writing to file: {str(e)}"

def run_bash(command):
    try:
        result = subprocess.run(
            command,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120
        )
        output = result.stdout
        if result.stderr:
            output += "\nSTDERR:\n" + result.stderr
        return output.strip()
    except Exception as e:
        return f"Error executing command: {str(e)}"

def list_files(dir):
    try:
        result = subprocess.run(
            "ls -lah " + dir,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120
        )
        output = result.stdout
        if result.stderr:
            output += "\nSTDERR:\n" + result.stderr
        return output.strip()
    except Exception as e:
        return f"Error listing files: {str(e)}"

# --- Tool Execution Router ---
def execute_tool(proposed_command):
    parts = proposed_command.strip().split(maxsplit=1)
    if not parts:
        return "Error: Empty command received."
    
    tool = parts[0]
    args = parts[1] if len(parts) > 1 else ""

    if tool == "read_file":
        return read_file(args.strip())
    elif tool == "append_file":
        sub_parts = args.split(maxsplit=1)
        path = sub_parts[0] if len(sub_parts) > 0 else ""
        content = sub_parts[1] if len(sub_parts) > 1 else ""
        return append_file(path, content)
    elif tool == "replace_file":
        sub_parts = args.split(maxsplit=1)
        path = sub_parts[0] if len(sub_parts) > 0 else ""
        content = sub_parts[1] if len(sub_parts) > 1 else ""
        return replace_file(path, content)
    elif tool == "bash":
        return run_bash(args)
    elif tool == "list_files":
        return list_files(args)
    else:
        # Fallback: if no clear tool prefix is matched, treat the whole line as a bash command
        return run_bash(proposed_command)

# --- System Prompt ---
SYSTEM_PROMPT = """You are tiny-7coder, an autonomous Unix-like systems agent.
Your goal is to solve the user's task step-by-step using the provided tools.

You have access to these tools:
1. read_file <file_path> : Reads a file's content.
2. append_file <file_path> <content> : Appends text to a file.
3. replace_file <file_path> <content> : Overwrites/creates a file with content.
4. bash <command> : Runs a standard shell command.
5. list_files <dir_path> : Lists all files in a directory.

Rules:
1. You work in an iterative loop. Output exactly ONE tool call at a time.
2. If the task is fully completed, output the word 'DONE' instead of a tool call.
3. Output ONLY the raw executable command or 'DONE'. Do not wrap in markdown, backticks, or write explanations."""

# --- Main Agent Loop ---
def main():
    if len(sys.argv) < 2:
        print("Usage: tiny-7coder \"<request>\"")
        sys.exit(1)

    prompt_request = sys.argv[1]
    os_name = platform.system()
    
    print(f"Starting task: {prompt_request}")
    print("--------------------------------------")

    history = f"User Request: {prompt_request}"
    step = 1
    max_steps = 10

    while step <= max_steps:
        print(f"Thinking (Step {step}, Model: {MODEL})...")

        full_prompt = (
            f"System: {SYSTEM_PROMPT}\n"
            f"Context: OS: {os_name} | User: {os.environ.get('USER', 'unknown')} | PWD: {os.getcwd()}\n"
            f"History of actions taken so far:\n{history}\n"
            f"Respond with your next tool call (or 'DONE'):"
        )

        payload = {
            "model": MODEL,
            "prompt": full_prompt,
            "stream": False
        }

        # Parse HOST to handle schemes safely
        host_clean = HOST.strip()
        if host_clean.startswith("http://") or host_clean.startswith("https://"):
            req_url = f"{host_clean.rstrip('/')}/api/generate"
        else:
            req_url = f"http://{host_clean}/api/generate"

        req_data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            req_url, 
            data=req_data, 
            headers={"Content-Type": "application/json"},
            method="POST"
        )

        # Setup SSL context if needed
        ssl_context = None
        if req_url.startswith("https://") and not VERIFY_SSL:
            ssl_context = ssl._create_unverified_context()

        try:
            # Pass the ssl_context parameter directly into urlopen
            with urllib.request.urlopen(req, context=ssl_context) as response:
                res_data = json.loads(response.read().decode("utf-8"))
                final_cmd = res_data.get("response", "").strip()
        except urllib.error.URLError as e:
            print(f"Error: Connection to model at {HOST} failed: {e.reason}")
            sys.exit(1)
        except Exception as e:
            print(f"Error communicating with model: {str(e)}")
            sys.exit(1)

        if not final_cmd:
            print("Error: Received empty response from model.")
            sys.exit(1)

        if final_cmd == "DONE":
            print("Task completed successfully.")
            sys.exit(0)

        print(f"Command: {final_cmd}")
        

        print("Executing...")
        output = execute_tool(final_cmd)
        print(f"Output: {output}")
        print("--------------------------------------")

        # Update run history for context in the next iteration
        history += f"\nStep {step} Command: {final_cmd}\nResult: {output}"
        step += 1

    print(f"Reached maximum execution limit of {max_steps} steps.")

if __name__ == "__main__":
    main()
