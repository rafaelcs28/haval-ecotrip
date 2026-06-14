#!/usr/bin/env bash
# Sai 0 se AGORA for dia de semana (seg–sex) E entre 16:00 e 23:00. Senão sai 1.
set -euo pipefail

dow=$(date +%u)                 # 1=seg .. 7=dom
cur=$(( $(date +%H) * 60 + $(date +%M) ))
from=$(( 16 * 60 ))             # 16:00
to=$(( 23 * 60 ))              # 23:00

if (( dow >= 1 && dow <= 5 )) && (( cur >= from && cur <= to )); then
  echo "DENTRO ($(date '+%a %H:%M'))"
  exit 0
else
  echo "FORA ($(date '+%a %H:%M'))"
  exit 1
fi
