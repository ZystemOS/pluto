#!/bin/bash

BOOT_DIR=$1
MODULES_DIR=$2
ISO_DIR=$3
PLUTO_ELF=$4
OUTPUT_FILE=$5

MAP_FILE=$MODULES_DIR/'kernel.map'

exit_missing() {
    printf "$_ must be installed\n";
    exit 1;
}

# Check dependencies
which xorriso > /dev/null || exit_missing
which grub-mkrescue > /dev/null || exit_missing
which readelf > /dev/null || exit_missing

mkdir -p $BOOT_DIR
mkdir -p $MODULES_DIR

cp -r grub $BOOT_DIR
cp $PLUTO_ELF $BOOT_DIR/"pluto.elf"

# Read the symbols from the binary, remove all the unnecessary columns with awk and emit to a map file
readelf -s $PLUTO_ELF | grep -F "FUNC" | awk '{$1=$3=$4=$5=$6=$7=""; print $0}' | sort -k 1 > $MAP_FILE
echo "" >> $MAP_FILE

grub-mkrescue -o $OUTPUT_FILE $ISO_DIR
