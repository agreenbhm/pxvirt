#!/bin/bash
SCRIPT_DIR=$(cd $(dirname ${BASH_SOURCE[0]}); pwd)
PKGNAME=$(basename $SCRIPT_DIR)

echo "This is $PKGNAME build scripts"

. ../common.sh

cd $SCRIPT_DIR/$PKGNAME/submodules/proxmox-backup/
apt update
yes |mk-build-deps --install --remove
apt install librust-pbs-api-types-dev -y
cd $SCRIPT_DIR/$PKGNAME
exec_build_make

