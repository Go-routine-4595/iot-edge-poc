# IoT Edge PoC

## Architecture principle

**NATS JetStream is the only durable event persistence layer on the edge, and
the only message broker on the edge.**

- JetStream owns retention, replay, pending outbound events, expiry, and disk limits.
- The NATS server's **built-in MQTT listener** serves local MQTT components. There is no separate MQTT broker.
- eKuiper owns stream/rule processing and speaks MQTT directly to NATS — no protocol adapter between them.
- Redpanda Connect is a stateless integration layer used only for the WAN hop to central EMQX; no Connect buffer is configured.

## Event flow

```text
mock-inference
    |
    | NATS: videoai.inference.events
    v
NATS / JetStream [INFERENCE]
    |
    | MQTT sub QoS 0: videoai/inference/events   (same server, same message)
    v
eKuiper   rule: create_alert
    |
    | MQTT pub QoS 1: videoai/alerts
    v
NATS / JetStream [ALERTS]
    |
    | durable consumer
    v
Redpanda Connect: rp-alerts-to-emqx
    |
    | MQTT/TLS QoS 1
    v
Central EMQX
```

NanoMQ, `rp-inference-to-mqtt` and `rp-alerts-to-jetstream` are gone. Three
containers and two extra network hops were removed; the messages they carried
now never leave the NATS server.

The final delivery pipeline still has no intermediate persistent buffer. If
central EMQX is unavailable, the Redpanda Connect output cannot complete and
the JetStream message is not acknowledged. JetStream remains responsible for
the pending event until delivery succeeds or the stream retention/expiry
policy removes it.

## How MQTT on NATS works here

The NATS server has accepted MQTT clients natively since 2.2. `nats/nats.conf`
adds one `mqtt { port: 1883 }` block and the same binary that serves NATS
clients on 4222 accepts MQTT connections on 1883.

Topic and subject are the same name with a different separator — `/` becomes `.`:

| MQTT topic                 | NATS subject               |
| -------------------------- | -------------------------- |
| `videoai/inference/events` | `videoai.inference.events` |
| `videoai/alerts`           | `videoai.alerts`           |

Wildcards map the same way: `+` is `*`, `#` is `>`.

That equivalence is the whole trick. eKuiper subscribes to
`videoai/inference/events` and receives exactly what `mock-inference` published
on `videoai.inference.events`. eKuiper publishes to `videoai/alerts` and the
`ALERTS` stream, which is bound to subject `videoai.alerts`, stores it.

**JetStream is mandatory for the MQTT listener**, not optional as it is for core
NATS: the server persists MQTT session state, QoS 1/2 delivery tracking and
retained messages in internal `$MQTT_*` streams. JetStream is already enabled in
this PoC, so no extra configuration is needed.

### Reliability of each hop

**Alerts (eKuiper → JetStream) got stronger.** A QoS 1 MQTT publish is persisted
by the server before the PUBACK is returned, and the same inbound message is
published on subject `videoai.alerts` and captured by the `ALERTS` stream. The
previous design's "small reliability boundary" — eKuiper publishing to a
separate broker and hoping a Connect pipeline moved it into JetStream before
anything crashed — no longer exists. The alert is durable at the moment
eKuiper's publish is acknowledged.

**Inference (JetStream → eKuiper) got weaker, deliberately.** NATS delivers
messages published by *core NATS* clients to MQTT subscriptions as **QoS 0,
always** — this is a documented server limitation, not a configuration choice.
The old `rp-inference-to-mqtt` used a durable JetStream consumer, so events
queued while eKuiper was down. Now, inference events produced while eKuiper is
disconnected are missed. The events themselves are still durable in the
`INFERENCE` stream and can be replayed manually; eKuiper just will not see them
automatically.

That trade is deliberate for a PoC. Two ways to close it when it matters:

1. Have `mock-inference` (and later the real inference service) publish over
   **MQTT QoS 1** to `videoai/inference/events` instead of core NATS. The message
   is then stored for at-least-once MQTT delivery *and* still captured by the
   `INFERENCE` stream on the mapped subject, so eKuiper gets a durable
   subscription with no adapter reintroduced. This is the recommended path.
2. Reintroduce a single Redpanda Connect hop with a durable JetStream consumer
   that republishes over MQTT QoS 1. This works but puts a container back.

### Other MQTT-on-NATS constraints worth knowing

- **MQTT 3.1.1 only.** A client offering MQTT 5.0 is rejected with CONNACK code 1.
  eKuiper is pinned to `3.1.1` in both the source config and the sink action.
- Topic segments may not contain spaces. A literal `.` in a topic is escaped by
  the server (supported since 2.10).
- Two MQTT sessions using the same client ID evict each other, so the eKuiper
  source (`ekuiper-inference-sub`) and sink (`ekuiper-alert-publisher`) use
  distinct IDs.
- Retained messages are best-effort in clustered mode. Not used here.

## Directory layout

```text
iot-edge-poc/
├── docker-compose.yml
├── mock-inference/
│   ├── config.env
│   └── log/
├── nats/
│   ├── nats.conf          # JetStream + MQTT listener
│   └── init.sh            # creates INFERENCE and ALERTS streams
├── redpanda-connect/
│   ├── alerts-to-emqx.yaml
│   └── emqx.env
├── ekuiper/
│   ├── init.sh
│   ├── stream.json
│   └── rule.json
├── data/
│   ├── nats/
│   └── ekuiper/
└── log/
    └── ekuiper/
```

## Configure mock inference

`mock-inference/config.env`:

```env
LOG_DIR=/log
LOG_LEVEL=info
GENERATE_INTERVAL=2s
HOST=nats
PORT=4222
CLIENT_ID=mock-inference-client
TOPICS=videoai.inference.events
STREAM_NAME=INFERENCE
```

Within the Compose network, `nats` is the broker hostname for both protocols:
`nats://nats:4222` and `tcp://nats:1883`.

## Configure central EMQX

Edit `redpanda-connect/emqx.env`:

```env
EMQX_URL=ssl://backend.christophe.engineering:8883
EMQX_CLIENT_ID=edge-alert-forwarder
EMQX_TOPIC=videoai/alerts
EMQX_USERNAME=
EMQX_PASSWORD=
```

The outbound pipeline uses MQTT QoS 1 and TLS.

If central EMQX uses a private CA, mount the CA into the `rp-alerts-to-emqx`
service and add `root_cas_file` under the MQTT output TLS configuration in
`alerts-to-emqx.yaml`.

## Start

```bash
docker compose up -d
docker compose ps
```

## Useful logs

```bash
docker compose logs -f mock-inference
docker compose logs -f ekuiper
docker compose logs -f rp-alerts-to-emqx
```

## Debug local MQTT

The MQTT listener is the NATS server itself, on the same port as before:

```bash
mosquitto_sub -h localhost -p 1883 -t 'videoai/#' -v
```

The same traffic is visible on the NATS side, which is a useful way to confirm
the topic/subject mapping:

```bash
nats --server nats://localhost:4222 sub 'videoai.>'
```

Publishing from either side reaches the other:

```bash
mosquitto_pub -h localhost -p 1883 -t videoai/alerts -q 1 -m '{"test":1}'
nats --server nats://localhost:4222 pub videoai.inference.events '{"confidence":0.9}'
```

## JetStream monitoring

NATS monitoring is exposed on:

```text
http://localhost:8222
```

Stream state, including the internal MQTT streams:

```bash
nats --server nats://localhost:4222 stream ls --all
nats --server nats://localhost:4222 stream info ALERTS
```

Current PoC retention limits:

- `INFERENCE`: subject `videoai.inference.events`, max age 1 hour, max 250 MiB.
- `ALERTS`: subject `videoai.alerts`, max age 24 hours, max 250 MiB.
- NATS server total JetStream file-store cap: 1 GiB.

The server also creates its own internal streams under the same 1 GiB cap —
on 2.14 that is `$MQTT_msgs`, `$MQTT_out`, `$MQTT_sess`, `$MQTT_rmsgs` and
`$MQTT_qos2in`. `$MQTT_msgs` uses interest retention, so it drains as QoS 1
subscribers acknowledge; it is not a second copy of the event history.

These are PoC values and should be tuned from the real event rate, acceptable
outage duration, and disk budget.

## eKuiper rule

```sql
SELECT * FROM inference_events WHERE confidence > 0.6
```

Source: MQTT `videoai/inference/events`, QoS 0, MQTT 3.1.1, client ID
`ekuiper-inference-sub` (set via `MQTT_SOURCE__DEFAULT__*` environment
variables on the `ekuiper` service).

Sink: MQTT `videoai/alerts`, QoS 1, MQTT 3.1.1, client ID
`ekuiper-alert-publisher` (set in `ekuiper/rule.json`).

## Inbound commands

The removed NanoMQ config carried a placeholder bridge to
`backend.christophe.engineering` for `test/command` and `test/nanomq`. NATS
cannot act as an MQTT *client* against a remote broker, so if the edge needs to
receive commands from central EMQX, that path has to be defined explicitly —
either a Redpanda Connect pipeline (MQTT input from EMQX → NATS output) or a
NATS leaf-node connection to a cloud NATS. Nothing in this stack does it today.

## Production hardening still to do

1. Pin tested container image versions instead of `latest`.
2. Decide whether inference events should be published over MQTT QoS 1 so eKuiper's input becomes at-least-once (see "Reliability of each hop").
3. Define the final alert JSON schema and an immutable `event_id` for duplicate detection.
4. Decide stream-level versus per-message TTL policy for each event/alert class.
5. Configure central EMQX hostname, authentication, CA/client certificates, and MQTT topic convention.
6. Add NATS authentication/TLS on both listeners; the MQTT listener is currently open on 1883 like the old broker was.
7. Define the inbound command path, if one is needed.
8. Move secrets out of Git-managed configuration for Komodo deployment.
9. Add observability/health metrics for JetStream backlog and outbound EMQX delivery.
10. Test WAN outage, restart, TTL expiry, disk limits, and duplicate-delivery scenarios.