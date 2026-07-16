#!/bin/bash
while true
do
read -p "request >" req
python3 "t7c.py" "$req"
done
