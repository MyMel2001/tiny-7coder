#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
while true
do
read -p "request >" req
python3 "$SCRIPT_DIR/t7c.py" "$req"
done
