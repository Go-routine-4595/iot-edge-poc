# feature/bloblang-rules

Variant of the iot-edge-poc stack using **Redpanda Connect + Bloblang** as the
rules engine, replacing eKuiper. Everything else in the stack is unchanged.

Compare with `main` (eKuiper) to evaluate both approaches on separate PiBlades.

---

## What changed from main

| | main (eKuiper) | this branch (Bloblang) |
|---|---|---|
| Rules engine | eKuiper + ekuiper-init | rp-rules-engine |
| Rule authorship | SQL via REST API | YAML / Bloblang |
| Runtime rule change | REST API call, no restart | Edit file, restart container |
| Rules in git | Requires extra tooling | Native — file in repo |
| Windowed aggregation | Built-in | Cache processor (manual) |
| Container count | +2 (ekuiper, ekuiper-init) | +1 (rp-rules-engine) |
| New dependency | eKuiper | None — already uses Redpanda Connect |

## Files added or changed

```
docker-compose.yml                        ← ekuiper/ekuiper-init removed, rp-rules-engine added
redpanda-connect/rp-rules-engine.yaml     ← new — Bloblang pipeline config
BLOBLANG-RULES.md                         ← this file
```

All other files (nats/, nanomq/, mock-inference/, redpanda-connect/inference-to-mqtt.yaml,
redpanda-connect/alerts-to-jetstream.yaml, redpanda-connect/alerts-to-emqx.yaml) are
identical to main.

---

## Running this branch

```bash
git clone https://github.com/Go-routine-4595/iot-edge-poc.git
cd iot-edge-poc
git checkout feature/bloblang-rules
docker compose up
```

To watch alerts in real time (separate terminal):
```bash
mosquitto_sub -h localhost -p 1883 -t "videoai/alerts/generated"
```

---

## Changing a rule

No rebuild needed. Edit the pipeline config and restart the rules engine:

```bash
nano redpanda-connect/rp-rules-engine.yaml
docker compose restart rp-rules-engine
```

---

## TODO — payload schema validation

The Bloblang rules reference field names (`use_case`, `camera_id`, `violation_type`)
that have not yet been confirmed against the actual mock-inference payload.

Before finalising the rules, run the stack and observe what mock-inference publishes:

```bash
# Via NanoMQ (MQTT)
mosquitto_sub -h localhost -p 1883 -t "videoai/inference/events"

# Or via NATS JetStream directly
nats sub "videoai.inference.events" --server nats://localhost:4222
```

Adjust field names in `redpanda-connect/rp-rules-engine.yaml` to match.
The fallback `GENERIC-001` rule (confidence > 0.60, no use_case required) will
fire regardless and confirm the pipeline is working end to end.

---

*Copper Sentinel IVA · FMI-MIS / Accenture · PoC — not for production use*
