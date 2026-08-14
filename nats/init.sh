#!/bin/sh
set -eu
URL=nats://nats:4222

echo "Waiting for NATS..."

until nats --server "$URL" account info >/dev/null 2>&1; do
  sleep 1
done

echo "NATS is ready"

create_stream() {
  NAME="$1"
  SUBJECT="$2"
  MAXAGE="$3"
  MAXBYTES="$4"

  if nats --server "$URL" stream info "$NAME" >/dev/null 2>&1; then
    echo "$NAME already exists"
  else
    echo "Creating stream $NAME for subject $SUBJECT"
    nats --server "$URL" stream add "$NAME" \
    --subjects "$SUBJECT" \
    --storage file \
    --retention limits \
    --discard old \
    --max-msgs=-1 \
    --max-bytes="$MAXBYTES" \
    --max-age="$MAXAGE" \
    --max-msg-size=-1 \
    --replicas 1 \
    --defaults
  fi
}

create_stream INFERENCE videoai.inference.events 1h 262144000
create_stream ALERTS videoai.alerts 24h 262144000
nats --server "$URL" stream list
