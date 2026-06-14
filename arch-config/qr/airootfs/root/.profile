#!/bin/bash
if [ "$(tty)" = "/dev/tty1" ]; then
    if [ -x /usr/local/bin/hardware_qr.sh ]; then
        /usr/local/bin/hardware_qr.sh
    else
        sh /usr/local/bin/hardware_qr.sh
    fi
fi
