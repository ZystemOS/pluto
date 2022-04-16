#!/usr/bin/env bash
set -ex

IMAGE_PATH_DIR=$1
mkdir -p test/fat32/mnt
whoami

if [ "$(whoami)" = "root" ]; then
	sudo mount -o utf8=true $IMAGE_PATH_DIR test/fat32/mnt/
	cp -r test/fat32/test_files/. test/fat32/mnt/
	sudo umount test/fat32/mnt/
else
	sudo mount -o utf8=true $IMAGE_PATH_DIR test/fat32/mnt/
	sudo cp -r test/fat32/test_files/. test/fat32/mnt/
	sudo umount test/fat32/mnt/
fi

rm -rf test/fat32/mnt
