#!/bin/bash
PKGNAME="proxmox-offline-mirror"

errlog(){
        echo $1
        exit 1

}

exec_build(){
        apt update
        apt install librust-proxmox-router-dev librust-proxmox-router-2+cli-dev librust-proxmox-subscription-0.4+api-types-dev librust-proxmox-subscription-dev -y
        yes |mk-build-deps --install --remove
        echo "clean "
        make clean || echo ok
        echo "build deb in `pwd` "
        make dsc || errlog "build dsc error"
        make deb || errlog "build deb error"
}

echo "This is $PKGNAME build scripts"


SH_PATH=$(realpath "$0")
SH_DIR=$(dirname $SH_PATH)

cd $SH_DIR/$PKGNAME
exec_build
