# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
FROM scratch
ADD rootfs.tar.gz /
COPY deps/ /deps/
RUN mkdir -p /tmp /var/lock && apk add --no-network --allow-untrusted --repositories-file /dev/null /deps/*.apk && rm -rf /deps && printf '#!/bin/sh\ntouch /tmp/toolkit-boot-ready\n' > /etc/rc.local
CMD ["/sbin/init"]
