#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
while true
do
read -p "request >" req
"$SCRIPT_DIR/python3" "t7c.py" "$req"
done
