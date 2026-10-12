#!/bin/sh
# Example notify script: writes every state change to the container log.
# keepalived appends these arguments to the configured command:
#   $1  INSTANCE or GROUP
#   $2  name of the instance, e.g. VI_1
#   $3  new state: MASTER, BACKUP, FAULT or STOP
#   $4  current priority
# The script runs asynchronously; its exit code is ignored by keepalived.
echo "notify: $1 $2 changed to $3 (priority $4)" > /proc/1/fd/1
