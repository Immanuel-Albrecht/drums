#!/bin/bash

for i in **/*wav; do
  sox "$i" "temp.wav" reverse silence 1 0.01 -86d reverse
  mv "temp.wav" "$i"
done
