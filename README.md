# IoT Edge PoC

## Architecture principle

**NATS JetStream is the only durable event persistence layer on the edge.**

- JetStream owns retention, replay, pending outbound events, expiry, and disk limits.
- Redpanda Connect is a stateless protocol/integration layer; no Connect buffer is configured.
- NanoMQ is the local MQTT broker used by local MQTT components such as eKuiper. It is not the WAN persistence layer and does not bridge alerts to the cloud in this PoC.
- eKuiper owns stream/rule processing.

## Event flow

```text
mock-inference
    |
    | NATS: videoai.inference.events
    v
NATS / JetStream [INFERENCE]
    |
    v
Redpanda Connect: rp-inference-to-mqtt
    |
    | MQTT: videoai/inference/events
    v
NanoMQ
    |
    v
eKuiper
    |
    | MQTT: videoai/alerts/generated
    v
NanoMQ
    |
    v
Redpanda Connect: rp-alerts-to-jetstream
    |
    | NATS: videoai.alerts
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

The final delivery pipeline has no intermediate persistent buffer. If central EMQX is unavailable, the Redpanda Connect output cannot complete and the JetStream message is not acknowledged. JetStream remains responsible for the pending event until delivery succeeds or the stream retention/expiry policy removes it.

## Directory layout

```text
iot-edge-poc/
├── docker-compose.yml
├── mock-inference/
│   ├── config.env
│   └── log/
├── nats/
│   ├── nats.conf
│   └── init.sh
├── redpanda-connect/
│   ├── inference-to-mqtt.yaml
│   ├── alerts-to-jetstream.yaml
│   ├── alerts-to-emqx.yaml
│   └── emqx.env
├── ekuiper/
│   ├── init.sh
│   ├── stream.json
│   └── rule.json
├── nanomq/
│   └── nanomq.conf
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
```

Within the Compose network, `nats` is the broker hostname.

## Configure central EMQX

Edit `redpanda-connect/emqx.env`:

```env
EMQX_URL=ssl://emqx.example.local:8883
EMQX_CLIENT_ID=edge-alert-forwarder
EMQX_TOPIC=videoai/alerts
EMQX_USERNAME=
EMQX_PASSWORD=
```

The outbound pipeline uses MQTT QoS 1 and TLS certificate verification.

If central EMQX uses a private CA, mount the CA into the `rp-alerts-to-emqx` service and add `root_cas_file` under the MQTT output TLS configuration in `alerts-to-emqx.yaml`.

## Start

```bash
docker compose up -d
docker compose ps
```

## Useful logs

```bash
docker compose logs -f mock-inference
docker compose logs -f rp-inference-to-mqtt
docker compose logs -f ekuiper
docker compose logs -f rp-alerts-to-jetstream
docker compose logs -f rp-alerts-to-emqx
```

## Debug local MQTT

```bash
mosquitto_sub -h localhost -p 1883 -t 'videoai/#' -v
```

## JetStream monitoring

NATS monitoring is exposed on:

```text
http://localhost:8222
```

Current PoC retention limits:

- `INFERENCE`: subject `videoai.inference.events`, max age 1 hour, max 250 MiB.
- `ALERTS`: subject `videoai.alerts`, max age 24 hours, max 250 MiB.
- NATS server total JetStream file-store cap: 1 GiB.

These are PoC values and should be tuned from the real event rate, acceptable outage duration, and disk budget.

## eKuiper rule

The current rule remains deliberately simple:

```sql
SELECT * FROM inference_events
```

This proves the full transport and persistence path before coupling the rule to the final inference-event schema.

## Persistence note

NanoMQ has no cloud bridge configured in this stack. The MQTT input used by `rp-alerts-to-jetstream` uses a clean session, so NanoMQ is not intentionally used as a durable queue for generated alerts.

There is therefore a small reliability boundary between eKuiper's publish and the point where the alert reaches JetStream. For a production design where *every generated alert must become durable atomically*, we should next evaluate replacing that local alert MQTT hop with a synchronous eKuiper -> Redpanda Connect -> JetStream handoff. The WAN store-and-forward path is already centralized in JetStream.

## Production hardening still to do

1. Pin tested container image versions instead of `latest`.
2. Define the final alert JSON schema and an immutable `event_id` for duplicate detection.
3. Decide stream-level versus per-message TTL policy for each event/alert class.
4. Configure central EMQX hostname, authentication, CA/client certificates, and MQTT topic convention.
5. Add health checks and Compose dependency readiness checks.
6. Add NATS authentication/TLS if required on the local Docker network.
7. Move secrets out of Git-managed configuration for Komodo deployment.
8. Add observability/health metrics for JetStream backlog and outbound EMQX delivery.
9. Test WAN outage, restart, TTL expiry, disk limits, and duplicate-delivery scenarios.

## Central EMQX endpoint

The PoC is configured for `backend.christophe.engineering:8883`.

- `rp-alerts-to-emqx` is the reliable outbound alert path. It consumes JetStream `ALERTS` and publishes directly to central EMQX. WAN outages therefore leave messages pending in JetStream.
- NanoMQ also has a TLS bridge configuration to the same broker, but its `forwards` and `subscription` mappings are intentionally empty for now. This prevents NanoMQ from becoming a second persistence/retry path for alerts.
- NanoMQ SQLite/bridge disk caching is intentionally not configured. JetStream is the single persistence owner.
