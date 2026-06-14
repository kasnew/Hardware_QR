#!/bin/bash
if [ "$(tty)" = "/dev/tty1" ]; then
    /usr/local/bin/hardware_qr.sh
fi
