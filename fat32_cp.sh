#!/usr/bin/env bash
set -ex

IMAGE_PATH_DIR=$1

copy() {
    mcopy -i $IMAGE_PATH_DIR "$1" ::"$2"
    if [[ -d $1 ]]; then
        for x in $1/*; do
            copy "$x" "$2/$(basename $1)"
        done
    fi
}
for x in test/fat32/test_files/*; do
    copy "$x" ""
done
mdir -i $IMAGE_PATH_DIR ::
