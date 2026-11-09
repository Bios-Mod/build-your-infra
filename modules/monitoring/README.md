# Monitoring

Without telemetry and synthetic checks, service degradation goes unnoticed until users report failures. Pull-based host metrics collection, endpoint availability probing, and time-series visualization across the lab without exposing unauthenticated management interfaces.

**Requires:** [`modules/hardening/`](../hardening/README.md) fully deployed with an active WireGuard `wg0` tunnel on both targets before applying this module.

> **Deployment scope:** Prometheus, `blackbox_exporter`, and Grafana run
> exclusively on the local VM (`multi-lab-local`). EC2 (`multi-lab-vps`) runs
> `node_exporter` only, scraped across the WireGuard tunnel — no new AWS
> instances or Security Group changes are required.

## Implementations

| Environment | Technology | Doc |
| --- | --- | --- |
| self-managed (local VM + EC2) | Prometheus · Grafana · node_exporter · blackbox_exporter | [monitoring-self-managed.md](self-managed/monitoring-self-managed.md) |
| aws-native | N/A — self-managed only | — |

**Automation (self-managed):** Ansible role [`monitoring`](../../stacks/full-infra/self-managed/automation/self-managed-automation.md#monitoring--prometheus-and-grafana-stack) (`monitoring_targets`: VM + EC2; `monitoring_servers`: local VM)
