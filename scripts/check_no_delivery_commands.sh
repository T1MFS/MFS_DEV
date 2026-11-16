#!/usr/bin/env bash
# Fails if MFS source calls any Omnipod insulin-delivery command (T-1.5.2 / ST-1.5.2.2).
set -euo pipefail

cd "$(dirname "$0")/.."

symbols='enactBolus|enactTempBasal|cancelBolus|suspendDelivery|resumeDelivery|syncBasalRateSchedule|syncDeliveryLimits'

if matches=$(grep -rnE --include='*.swift' "\\b(${symbols})\\b" Sources); then
  echo "Forbidden insulin-delivery symbols found in Sources/:" >&2
  echo "$matches" >&2
  exit 1
fi
echo "OK: no insulin-delivery commands in Sources/"
