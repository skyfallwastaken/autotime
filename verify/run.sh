#!/bin/bash
# Scratch: launch one Autotime build, drive it and capture window screenshots.
# usage: run.sh <app path> <label> <outdir>
set -uo pipefail
APP=$1; LABEL=$2; OUT=$3
D=/tmp/drive
mkdir -p "$OUT"

# Best effort: grant Accessibility so no permission dialog/banner appears (runner SIP is off).
REQ=$(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')
if [ -n "$REQ" ]; then
  echo "$REQ" | csreq -r- -b /tmp/csreq.bin && HEX=$(xxd -p /tmp/csreq.bin | tr -d '\n')
  for DB in "/Library/Application Support/com.apple.TCC/TCC.db"; do
    sudo sqlite3 "$DB" "DELETE FROM access WHERE client='dev.autotime.Autotime'; INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,flags,indirect_object_identifier,last_modified) VALUES('kTCCServiceAccessibility','dev.autotime.Autotime',0,2,4,1,X'$HEX',0,'UNUSED',$(date +%s));" || echo "TCC insert failed"
  done
fi

pkill -x Autotime; sleep 1
open "$APP"
sleep 6
shot() {
  local name=$1
  sleep 2
  local id=$($D winid | tail -1)
  screencapture -x -o -l "$id" "$OUT/$LABEL-$name.png" && echo "captured $LABEL-$name (window $id)"
}

$D size 1280 820
shot activities-1280
$D click Chronological AXRadioButton; shot chronological-1280
$D click Unified AXRadioButton
$D texts > "$OUT/$LABEL-activities-texts.txt"
$D click Stats AXStaticText || $D click Stats
shot stats-day-1280
$D texts > "$OUT/$LABEL-stats-day-texts.txt"
$D click Week AXRadioButton; shot stats-week-1280
$D click Month AXRadioButton; shot stats-month-1280
$D click Day AXRadioButton
$D size 980 640; shot stats-day-980
$D size 1600 1000; shot stats-day-1600
$D size 980 640
$D click Activities AXStaticText || $D click Activities
shot activities-980
pkill -x Autotime
screencapture -x "$OUT/$LABEL-screen.png"
