# tiny-7coder

A return to form for **7coder** — going back to its origins of being a simple tool.

"Not a coding platform. Just a model with hands." --ChatGPT

`tiny-7coder` is a small, dependency-free Unix-like systems agent designed to do one thing well: take a user's request, reason through the task with an AI model, and perform actions directly on the local system through a minimal set of tools.

Instead of being a large framework, plugin system, or complicated automation platform, tiny-7coder focuses on simplicity. It is a lightweight command-line companion that connects an LLM to a handful of practical system operations.

## Features

* 🪶 **Tiny footprint** — built with only Bash and Python's standard library
* 🤖 **AI-powered task execution** — uses a local or remote model endpoint
* 🛠️ **Simple tool interface**

  * Read files
  * Append to files
  * Replace file contents
  * Run shell commands
  * List directories
* 🔌 **Model agnostic** — works with any Ollama-compatible API endpoint
* ⚙️ **Minimal configuration** — no databases, no services, no dependencies
* 🐧 **Unix-oriented workflow** — designed around the command line and filesystem

## Philosophy

tiny-7coder is intentionally small.

The goal is not to create a massive coding environment or an all-in-one development platform. The goal is to return to the original spirit of 7coder: a simple tool that gets out of the way and helps you accomplish tasks quickly.

A user gives a request.
The model decides the next action.
The tool executes it.
The process repeats until the task is complete.

## Requirements

* Python 3.9+
* An Ollama-compatible AI model endpoint
* A Unix-like environment (Linux/macOS recommended)

## Installation
Follow instructions to create .env


Clone the repository:

```bash
git clone <repository-url>
cd /your/project/path
```

Run it:


```bash
python3 /path/to/t7c.py "Create a hello world script"
```

## Configuration

tiny-7coder stores its configuration in:

```
~/.config/nodemixaholic-software/tiny-7coder/.env
```

The configuration file is automatically created on first run.

Example configuration:

```env
MODEL=deepseek-v4-flash:cloud
HOST=localhost:11434
VERIFY_SSL=False
```

### Configuration Options

| Variable     | Description                         | Default                   |
| ------------ | ----------------------------------- | ------------------------- |
| `MODEL`      | Model name to use                   | `deepseek-v4-flash:cloud` |
| `HOST`       | Model API host                      | `http://127.0.0.1:11434`     |
| `SEARCH_PREFIX`       | Search query prefix                      | `https://searx.nodemixaholic.com/search?q=`     |
| `VERIFY_SSL` | Enable SSL certificate verification | `false`                    |

## How It Works

1. The user provides a task:

```bash
tiny-7coder "Update the README with installation instructions"
```

2. tiny-7coder sends the request and current context to the configured model.

3. The model responds with a single executable tool command.

4. tiny-7coder runs that command.

5. The result is returned to the model.

6. The loop continues until the model responds with:

```
DONE
```

The agent limits execution to 10 steps per request to prevent runaway operations.

## Security Notes

tiny-7coder can execute shell commands on the machine where it runs.

Use it responsibly:

* Review the model being used
* Avoid running it with unnecessary privileges
* Use isolated environments for untrusted tasks
* Keep backups of important files

## Why "tiny"?

Because useful tools do not need to be complicated.

tiny-7coder intentionally avoids:

* Large dependency trees
* Complex configuration systems
* Heavy user interfaces
* Unnecessary abstractions

It is a small bridge between an AI model and the operating system.

## License

MIT
