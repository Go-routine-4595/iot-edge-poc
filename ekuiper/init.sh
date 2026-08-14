#!/bin/sh
set -eu
BASE=http://ekuiper:9081
until curl -fsS "$BASE/streams" >/dev/null 2>&1; do
  sleep 1
done

curl -fsS "$BASE/streams" | grep -q '"inference_events"' ||   curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @/config/stream.json "$BASE/streams"

curl -fsS "$BASE/rules" | grep -q '"id":"create_alert"' ||   curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @/config/rule.json "$BASE/rules"

echo
echo "eKuiper initialized"
