#!/bin/sh
cd $(dirname $0)
echo "Watching `pwd` for *.wks changes..."
./gitwatch.sh .
