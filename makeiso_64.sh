#!/usr/bin/env bash

which readelf > /dev/null || exit_missing

INSTALL_PATH=$1
BIN_PATH=$2
PLUTO_ELF=$3
OUTPUT_FILE=$4
RAMDISK=$5

if [[ ! -f ./echfs/echfs-utils ]]
then
    echo "Building echfs-utils"
	cd echfs
	make echfs-utils
	cd ..
fi

if [[ ! -f ./limine/limine-install ]]
then
    echo "Building limine-install"
	cd limine
	make limine-install
	cd ..
fi

MAP_FILE=$INSTALL_PATH/"kernel.map"

# Read the symbols from the binary, remove all the unnecessary columns with awk and emit to a map file
readelf -s --wide $PLUTO_ELF | grep -F "FUNC" | awk '{$1=$3=$4=$5=$6=$7=""; print $0}' | sort -k 1 > $MAP_FILE
echo "" >> $MAP_FILE

if [[ -f $OUTPUT_FILE ]]
then
    rm $OUTPUT_FILE
fi

mkdir -p $BIN_PATH

dd if=/dev/zero bs=1M count=0 seek=64 of=$OUTPUT_FILE
parted -s $OUTPUT_FILE mklabel msdos
parted -s $OUTPUT_FILE mkpart primary 1 100%
./echfs/echfs-utils -m -p0 $OUTPUT_FILE quick-format 32768
./echfs/echfs-utils -m -p0 $OUTPUT_FILE import limine.cfg limine.cfg
./echfs/echfs-utils -m -p0 $OUTPUT_FILE import limine/limine.sys limine.sys
./echfs/echfs-utils -m -p0 $OUTPUT_FILE import $PLUTO_ELF pluto.elf
./echfs/echfs-utils -m -p0 $OUTPUT_FILE import $RAMDISK initrd.ramdisk
./echfs/echfs-utils -m -p0 $OUTPUT_FILE import $MAP_FILE kernel.map
./limine/limine-install $OUTPUT_FILE
