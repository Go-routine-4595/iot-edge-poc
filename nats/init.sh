#!/bin/sh
set -eu

URL=nats://nats:4222

until nats --server "$URL" stream ls >/dev/null 2>&1; do
    sleep 1
done

configure_stream() {
    NAME="$1"
    SUBJECT="$2"
    MAXAGE="$3"
    MAXBYTES="$4"

    if nats --server "$URL" stream info "$NAME" >/dev/null 2>&1; then
        echo "Updating stream $NAME"

        nats --server "$URL" stream edit "$NAME" \
                --subjects "$SUBJECT" \
                --discard old \
                --max-msgs=-1 \
                --max-bytes="$MAXBYTES" \
                --max-age="$MAXAGE" \
                --max-msg-size=-1 \
                --replicas 1 \
                --force
    else
        echo "Creating stream $NAME"

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

echo "-------------------------- nat-init starting --------------------------"

# INFERENCE captures what mock-inference publishes over core NATS.
# ALERTS captures what eKuiper publishes over MQTT on topic "videoai/alerts":
# the server's built-in MQTT listener maps that topic to the NATS subject
# videoai.alerts, so this stream stores it with no adapter in between.
configure_stream INFERENCE videoai.inference.events 1h 262144000
configure_stream ALERTS videoai.alerts 24h 262144000

nats --server "$URL" stream list
echo "-------------------------- nat-init exiting --------------------------"