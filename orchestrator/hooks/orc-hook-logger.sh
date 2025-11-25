#!/bin/bash

event="$1"
shift

LOG_FILE="/var/lib/orchestrator/hooks.log"

{
  echo "=============================="
  echo "$(date '+%Y-%m-%d %H:%M:%S') [${event}]"
  echo "  args: $@"
} >> "$LOG_FILE" 2>&1
