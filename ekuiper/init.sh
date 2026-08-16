#!/bin/sh
set -eu

BASE="http://ekuiper:9081"

echo "Waiting for eKuiper..."
until curl -fsS "$BASE/streams" >/dev/null 2>&1; do
  sleep 1
done

if curl -fsS "$BASE/streams" | grep -q '"inference_events"'; then
  echo "Stream inference_events already exists"
else
  echo "Creating stream inference_events"
  curl -fsS \
    -X POST \
    -H 'Content-Type: application/json' \
    --data-binary @/config/stream.json \
    "$BASE/streams"
  echo
fi

echo "Creating/updating rule create_alert"
curl -fsS \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data-binary @/config/rule.json \
  "$BASE/rules/create_alert"

echo

echo "Active rule:"
curl -fsS "$BASE/rules/create_alert"
echo
