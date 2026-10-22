#!/bin/bash
set -e

echo "Initializing firewall..."
/usr/local/bin/init-firewall.sh

exec setpriv --reuid node --regid node --init-groups "$@"
