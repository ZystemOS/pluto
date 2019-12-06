#!/bin/bash
# Read the symbols from the binary, remove all the unnecessary columns with awk and emit to a map file
readelf -s $1 | grep -F "FUNC" | awk '{$1=$3=$4=$5=$6=$7=""; print $0}' | sort -k 1 > $2
echo "" >> $2
