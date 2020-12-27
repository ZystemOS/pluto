#!/usr/bin/env bash

IMAGE_PATH_DIR=$1

mkdir test/fat32/mnt
sudo mount -o utf8=true $IMAGE_PATH_DIR test/fat32/mnt/
sudo cp -r test/fat32/test_files/. test/fat32/mnt/
sudo umount test/fat32/mnt/
rm -rf test/fat32/mnt
