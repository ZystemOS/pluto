#!/usr/bin/env bash

MAP_FILE=$1
PLUTO_ELF=$2
OUTPUT_FILE=$3
RAMDISK=$4

exit_missing() {
    printf "$_ must be installed\n";
    exit 1;
}

which readelf > /dev/null || exit_missing

if [[ ! -f ./limine/limine-install ]]
then
    echo "Building limine-install"
	cd limine
	make limine-install
	cd ..
fi

# Read the symbols from the binary, remove all the unnecessary columns with awk and emit to a map file
readelf -s --wide $PLUTO_ELF | grep -F "FUNC" | awk '{$1=$3=$4=$5=$6=$7=""; print $0}' | sort -k 1 > $MAP_FILE
echo "" >> $MAP_FILE
