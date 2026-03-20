# Flink Demo Application Design

**Date:** 2026-03-20
**Status:** Draft
**Workload:** `cp-flink-sql-sandbox` (evolved from existing)

## Overview

Evolve the existing `cp-flink-sql-sandbox` workload from a minimal Flink SQL demo into a rich, self-contained demo application with datagen connectors, multiple Kafka topics, Flink SQL join jobs, sample queries, and autoscaling.

## Requirements

- Replace existing demo topics/schemas with a realistic e-commerce data model
- Generate continuous data via datagen connectors (100 msg/s per topic)
- Create two Flink SQL join jobs producing enriched output topics
- Provide sample SQL inspection queries for interactive use
- Enable CMF autoscaling on the Flink compute pool
- Keep everything in the single `cp-flink-sql-sandbox` workload (All-in-One approach)

## Architecture

### Approach: All-in-One Workload

All components live in `workloads/cp-flink-sql-sandbox/`. This was chosen over splitting into multiple workloads because:
- Single ArgoCD Application — simplest dependency management
- Matches existing pattern (topics + schemas + CMF init already co-located)
- Self-contained demo — one workload = one demo environment

### Data Flow

```
datagen-users ──► [users topic] ──────────────────┐
                                                    ├──► Flink SQL Job 1 ──► [enriched-orders topic]
datagen-orders ──► [orders topic] ─────────────────┤
                                                    ├──► Flink SQL Job 2 ──► [user-activity topic]
datagen-clickstream ──► [clickstream topic] ───────┘
```

## Topics

### Source Topics (datagen-produced, 100 msg/s each)

| Topic | Partitions | Replicas | Key | Description |
|-------|-----------|----------|-----|-------------|
| `users` | 6 | 3 | `user_id` (string) | User profiles — id, name, email, region, registered_at |
| `orders` | 6 | 3 | `order_id` (string) | Orders — id, user_id, product, amount, currency, order_time |
| `clickstream` | 6 | 3 | `session_id` (string) | Click events — session_id, user_id, page_url, action, event_time |

### Sink Topics (Flink SQL-produced)

| Topic | Partitions | Replicas | Key | Description |
|-------|-----------|----------|-----|-------------|
| `enriched-orders` | 6 | 3 | `order_id` (string) | Orders joined with user details + recent clickstream |
| `user-activity` | 6 | 3 | `user_id` (string) | User 360 view — profile + clickstream + order history |

All topics use Avro format with schemas registered in Schema Registry via CFK `Schema` CRDs. Sync-wave `"30"`.

## Schemas

Five Avro schemas at sync-wave `"35"`, each consisting of a `ConfigMap` (holding the Avro JSON schema) and a `Schema` CRD (referencing the ConfigMap via `configRef`), following the existing pattern in `schemas.yaml`. Total: 5 ConfigMaps + 5 Schema CRDs = 10 YAML documents.

| Schema Subject | Key Fields | Types |
|---------------|------------|-------|
| `users-value` | user_id (string), name (string), email (string), region (string), registered_at (timestamp-millis) | All non-null |
| `orders-value` | order_id (string), user_id (string), product (string), amount (double), currency (string), order_time (timestamp-millis) | All non-null |
| `clickstream-value` | session_id (string), user_id (string), page_url (string), action (string), event_time (timestamp-millis) | All non-null |
| `enriched-orders-value` | order_id (string), user_id (string), product (string), amount (double), currency (string), order_time (timestamp-millis), name (string), email (string), region (string), click_count (long), last_page_url (string, nullable) | click_count/last_page_url nullable |
| `user-activity-value` | user_id (string), name (string), email (string), region (string), order_count (long), total_spend (double), click_count (long), unique_pages (long), window_start (timestamp-millis) | aggregation fields nullable |

## Datagen Connectors

Three `Connector` CRDs at sync-wave `"35"`:

| Connector | Topic | Rate | Key Config |
|-----------|-------|------|------------|
| `datagen-users` | `users` | ~100 msg/s (`max.interval: "10"`) | `value.converter: AvroConverter` |
| `datagen-orders` | `orders` | ~100 msg/s | Links to users via `user_id` field |
| `datagen-clickstream` | `clickstream` | ~100 msg/s | Links to users via `user_id` field |

Connectors reference the existing Connect cluster (`connect` in `kafka` namespace). The datagen connector's built-in quickstart templates or custom schema definitions will be used, aligned with the registered Avro schemas.

### Namespace Handling

The ArgoCD Application for `cp-flink-sql-sandbox` targets the `flink` namespace. However, `Connector` CRDs must be created in the same namespace as the `Connect` cluster they reference (`kafka`). Each Connector manifest must include an explicit `namespace: kafka` in its metadata to override the Application's default destination namespace.

### Datagen Plugin Prerequisite

The `cp-server-connect` image (`confluentinc/cp-server-connect:8.2.0`) ships with the `kafka-connect-datagen` plugin pre-installed. This should be verified during implementation by checking the Connect worker's `/connector-plugins` REST endpoint. If the plugin is not present, a `confluent-hub install` init container would be needed on the Connect deployment.

### Throughput Note

`max.interval: "10"` sets the maximum interval between messages to 10ms, yielding approximately 100 msg/s per connector (the actual interval is random between 0 and `max.interval`). This is sufficient for a demo — exact throughput is not required.

## Flink Compute Pool, Catalog & Database

### Compute Pool

Reuse existing `pool` compute pool. Updated with autoscaler configuration (see Autoscaling section).

- Name: `pool`
- Type: DEDICATED
- Flink Version: v1_19
- TaskManager slots: 4
- TaskManager resources: 1 CPU, 1700MB
- JobManager resources: 1 CPU, 1700MB

### Catalog

Reuse existing `kafka-cat` KafkaCatalog. No changes. Points to Schema Registry.

### Database

Reuse existing `main-kafka-cluster` KafkaDatabase. No changes. Points to Kafka bootstrap.

## Flink SQL Jobs

### Continuous Join Jobs

Deployed via a PostSync Kubernetes Job that submits SQL statements to CMF REST API.

> **Important:** The SQL statements below are illustrative of the intended join logic. The exact syntax will be refined during implementation to ensure compatibility with Flink SQL streaming semantics (e.g., proper temporal join syntax using `FOR SYSTEM_TIME AS OF`, correct window alignment, and bounded state management). The core intent of each job is described below.

**Job 1: enriched-orders**

Intent: For each order, attach the user's profile (temporal join on `user_id`) and a summary of their recent clickstream activity.

```sql
-- Illustrative — will be refined for proper temporal join syntax
INSERT INTO `enriched-orders`
SELECT
  o.order_id, o.user_id, o.product, o.amount, o.currency, o.order_time,
  u.name, u.email, u.region,
  c.click_count, c.last_page_url
FROM `orders` o
JOIN `users` FOR SYSTEM_TIME AS OF o.order_time u ON o.user_id = u.user_id
LEFT JOIN (
  SELECT user_id, COUNT(*) as click_count, LAST_VALUE(page_url) as last_page_url
  FROM `clickstream`
  GROUP BY user_id, HOP(event_time, INTERVAL '1' MINUTE, INTERVAL '5' MINUTES)
) c ON o.user_id = c.user_id;
```

**Job 2: user-activity**

Intent: Per user, aggregate order count/spend and clickstream activity over 5-minute tumbling windows.

```sql
-- Illustrative — will be refined for proper window alignment and temporal semantics
INSERT INTO `user-activity`
SELECT
  u.user_id, u.name, u.email, u.region,
  o.order_count, o.total_spend,
  c.click_count, c.unique_pages,
  c.window_start
FROM `users` FOR SYSTEM_TIME AS OF c.window_start u
LEFT JOIN (
  SELECT user_id, COUNT(*) as order_count, SUM(amount) as total_spend,
         window_start, window_end
  FROM TABLE(TUMBLE(TABLE `orders`, DESCRIPTOR(order_time), INTERVAL '5' MINUTES))
  GROUP BY user_id, window_start, window_end
) o ON u.user_id = o.user_id
LEFT JOIN (
  SELECT user_id, COUNT(*) as click_count, COUNT(DISTINCT page_url) as unique_pages,
         window_start, window_end
  FROM TABLE(TUMBLE(TABLE `clickstream`, DESCRIPTOR(event_time), INTERVAL '5' MINUTES))
  GROUP BY user_id, window_start, window_end
) c ON u.user_id = c.user_id AND o.window_start = c.window_start;
```

> **Implementation note:** The exact SQL will be validated against Flink 1.19 syntax and the CMF statement submission API. Key considerations: temporal joins require versioned/upsert sources, window TVFs (Table-Valued Functions) are preferred over legacy GROUP BY TUMBLE syntax in Flink 1.15+, and state TTL should be configured to prevent unbounded state growth.

### Sample Inspection Queries

Provided as a ConfigMap for users to run interactively via CMF API:

- `SELECT * FROM users LIMIT 10;`
- `SELECT * FROM orders LIMIT 10;`
- `SELECT * FROM clickstream LIMIT 10;`
- `SELECT region, COUNT(*) FROM users GROUP BY region;`
- `SELECT user_id, SUM(amount) FROM orders GROUP BY user_id;`
- `SELECT page_url, COUNT(*) FROM clickstream GROUP BY page_url ORDER BY COUNT(*) DESC;`
- `SELECT * FROM \`enriched-orders\` LIMIT 10;`
- `SELECT * FROM \`user-activity\` LIMIT 10;`

## Autoscaling

CMF autoscaler enabled on the compute pool via Flink configuration.

| Setting | Value |
|---------|-------|
| `kubernetes.operator.job.autoscaler.enabled` | `true` |
| `kubernetes.operator.job.autoscaler.metrics.window` | `3m` |
| `kubernetes.operator.job.autoscaler.stabilization.interval` | `1m` |
| `kubernetes.operator.job.autoscaler.target.utilization` | `0.7` |
| `kubernetes.operator.job.autoscaler.scale-down.max-factor` | `0.5` |
| `kubernetes.operator.job.autoscaler.scale-up.max-factor` | `2.0` |
| Min TaskManagers | 1 |
| Max TaskManagers | 5 |

Monitored via existing ServiceMonitor (port 9249) and PodMonitor (port 9999).

## File Changes

### Modified Files

| File | Changes |
|------|---------|
| `workloads/cp-flink-sql-sandbox/base/kustomization.yaml` | Add connectors, new schemas, SQL jobs ConfigMap |
| `workloads/cp-flink-sql-sandbox/base/topics.yaml` | Replace with 5 new topics |
| `workloads/cp-flink-sql-sandbox/base/schemas.yaml` | Replace with 5 Avro schemas (10 YAML docs: 5 ConfigMaps + 5 Schema CRDs) |
| `workloads/cp-flink-sql-sandbox/base/cmf-config-configmap.yaml` | Add autoscaler config to compute pool |
| `workloads/cp-flink-sql-sandbox/README.md` | Rewrite for new demo |
| `bootstrap/templates/argocd-projects.yaml` | Add `Connector` kind to workloads project whitelist |

### New Files

| File | Purpose |
|------|---------|
| `workloads/cp-flink-sql-sandbox/base/connectors.yaml` | 3 datagen Connector CRDs |
| `workloads/cp-flink-sql-sandbox/base/flink-sql-jobs.yaml` | PostSync Job to submit INSERT INTO SQL statements |
| `workloads/cp-flink-sql-sandbox/base/sample-queries-configmap.yaml` | ConfigMap with sample inspection SQL queries |

### Unchanged Files

- `clusters/flink-demo/workloads/cp-flink-sql-sandbox.yaml` — ArgoCD Application unchanged
- `workloads/cp-flink-sql-sandbox/overlays/flink-demo/kustomization.yaml` — Overlay unchanged
- All `flink-resources/` files — FlinkEnvironment, CMFRestClass, ServiceMonitor untouched
- All `confluent-resources/` files — Kafka, Connect, Schema Registry untouched

## Sync Wave Ordering

```
Wave 30:   Topics (users, orders, clickstream, enriched-orders, user-activity)
Wave 35:   Schemas (Avro schemas for all 5 topics) + Connectors (datagen x3)
PostSync:  CMF init (catalog + database) → Compute pool → SQL jobs
```

### PostSync Job Ordering

ArgoCD does not guarantee ordering between PostSync hooks. To ensure correct sequencing, the SQL submission job will include init containers that poll the CMF API to verify:
1. The catalog and database exist (created by `cmf-catalog-database-init`)
2. The compute pool is ready (created by `cmf-compute-pool-init`)

This is consistent with the existing pattern — the current PostSync jobs already use init containers to wait for CMF and Schema Registry readiness.

## AppProject Compatibility

**Required change:** The `Connector` kind (group: `platform.confluent.io`) is NOT currently in the `workloads` AppProject whitelist. It must be added to `bootstrap/templates/argocd-projects.yaml` under `namespaceResourceWhitelist` before deployment.

The following kinds are already whitelisted: `KafkaTopic`, `Schema`, `ConfigMap`, `Job`.

## Breaking Changes

Removing the existing `myevent` and `myaggregated` topics/schemas from the manifests means ArgoCD will no longer manage them. Since the ArgoCD Application does not have `automated.prune: true`, the old resources will become **orphaned** (not automatically deleted). They will appear as "out of sync" in ArgoCD.

**Cleanup approach:** The old topics and schemas should be manually deleted after the new manifests are deployed, or a manual prune can be triggered via ArgoCD UI/CLI. Alternatively, if desired, `prune: true` could be enabled on the Application's sync policy to automate cleanup.

Other impacts:
- The old topics and schemas are replaced by the new e-commerce data model
- Any users following the original `cp-flink-sql` demo guide will find a different setup
- The README will be updated to reflect the new demo flow

## Dependencies

No new external dependencies. Uses existing:
- Connect cluster (`confluent-resources`)
- Schema Registry (`confluent-resources`)
- CMF operator and REST API (`cmf-operator`)
- S3proxy for checkpoints (`s3proxy`)
- Flink Kubernetes Operator (`flink-kubernetes-operator`)
