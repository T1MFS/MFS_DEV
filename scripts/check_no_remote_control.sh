#!/usr/bin/env bash
# Fails if MFS gains a way to be controlled from outside: an inbound listener, URL-scheme or push entry point,
# or a background mode that would let a server wake it. MFS only sends data out (see docs/REMOTE_CONTROL_POLICY.md).
set -euo pipefail

cd "$(dirname "$0")/.."

symbols='NWListener|onOpenURL|CFBundleURLTypes|registerForRemoteNotifications|didReceiveRemoteNotification|UNNotificationServiceExtension|WKScriptMessageHandler|MCSession|CFSocketCreate|GCDWebServer|Telegraph|NSUserActivity'

if matches=$(grep -rnE --include='*.swift' "\\b(${symbols})\\b" Sources); then
  echo "Inbound control entry points found in Sources/:" >&2
  echo "$matches" >&2
  exit 1
fi

if grep -nE 'remote-notification|CFBundleURLTypes|processing|fetch' Sources/Info.plist; then
  echo "Sources/Info.plist enables an inbound or server-triggered entry point." >&2
  exit 1
fi
echo "OK: no inbound control entry points"
