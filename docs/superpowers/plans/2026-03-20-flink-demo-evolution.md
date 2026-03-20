# Flink Demo Application Evolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evolve `cp-flink-sql-sandbox` from a minimal Flink SQL demo into a rich e-commerce demo with datagen connectors, Flink SQL join jobs, sample queries, and CMF autoscaling.

**Architecture:** All-in-One workload in `workloads/cp-flink-sql-sandbox/`. Replace existing topics/schemas with a 5-topic e-commerce model (3 source, 2 sink). Add datagen connectors for data generation, two Flink SQL join jobs for enrichment, and CMF autoscaler configuration.

**Tech Stack:** Kustomize, CFK CRDs (KafkaTopic, Schema, Connector), CMF REST API, Flink SQL, ArgoCD sync waves and PostSync hooks.

**Design Spec:** `docs/superpowers/specs/2026-03-20-flink-demo-app-design.md`

---

## File Map

### Modified Files

| File | Responsibility |
|------|---------------|
| `bootstrap/templates/argocd-projects.yaml` | Add `Connector` kind to workloads AppProject whitelist |
| `workloads/cp-flink-sql-sandbox/base/kustomization.yaml` | Register all new resource files |
| `workloads/cp-flink-sql-sandbox/base/topics.yaml` | 5 KafkaTopic CRDs (replaces 2 old ones) |
| `workloads/cp-flink-sql-sandbox/base/schemas.yaml` | 5 ConfigMaps + 5 Schema CRDs (replaces 2+2 old ones) |
| `workloads/cp-flink-sql-sandbox/base/cmf-config-configmap.yaml` | Add autoscaler config to compute pool JSON |
| `workloads/cp-flink-sql-sandbox/README.md` | Rewrite for new demo |

### New Files

| File | Responsibility |
|------|---------------|
| `workloads/cp-flink-sql-sandbox/base/connectors.yaml` | 3 datagen Connector CRDs |
| `workloads/cp-flink-sql-sandbox/base/flink-sql-jobs.yaml` | PostSync Job submitting 2 INSERT INTO SQL statements |
| `workloads/cp-flink-sql-sandbox/base/sample-queries-configmap.yaml` | ConfigMap with sample SQL inspection queries |

### Unchanged Files (reference only)

| File | Why unchanged |
|------|--------------|
| `clusters/flink-demo/workloads/cp-flink-sql-sandbox.yaml` | ArgoCD Application — same name, path, namespace |
| `workloads/cp-flink-sql-sandbox/overlays/flink-demo/kustomization.yaml` | Just references base + cluster label |
| `workloads/cp-flink-sql-sandbox/base/cmf-init-job.yaml` | Catalog/database init — no changes |
| `workloads/cp-flink-sql-sandbox/base/cmf-compute-pool-job.yaml` | Compute pool init — no changes |

---

## Task 1: Add Connector to AppProject Whitelist

**Files:**
- Modify: `bootstrap/templates/argocd-projects.yaml:145` (after `FlinkApplication` entry)

- [ ] **Step 1: Add Connector kind to workloads namespaceResourceWhitelist**

In `bootstrap/templates/argocd-projects.yaml`, add a new entry after the `FlinkApplication` entry (line 145):

```yaml
    - group: platform.confluent.io
      kind: Connector
```

This goes between the existing `FlinkApplication` block and the `monitoring.coreos.com` `ServiceMonitor` block.

- [ ] **Step 2: Validate the Helm template renders**

Run:
```bash
helm template bootstrap bootstrap/ -f bootstrap/values.yaml 2>&1 | grep -A1 "kind: Connector"
```

Expected: Output showing `kind: Connector` in the rendered AppProject.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/templates/argocd-projects.yaml
git commit -m "Add Connector kind to workloads AppProject whitelist

Required for datagen connectors in the cp-flink-sql-sandbox workload."
```

---

## Task 2: Replace Topics

**Files:**
- Modify: `workloads/cp-flink-sql-sandbox/base/topics.yaml`

- [ ] **Step 1: Replace topics.yaml with 5 new topics**

Replace the entire contents of `topics.yaml` with:

```yaml
---
apiVersion: platform.confluent.io/v1beta1
kind: KafkaTopic
metadata:
  name: users
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  replicas: 3
  partitionCount: 6
  kafkaRestClassRef:
    name: default
    namespace: kafka
  configs:
    cleanup.policy: "compact"
---
apiVersion: platform.confluent.io/v1beta1
kind: KafkaTopic
metadata:
  name: orders
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  replicas: 3
  partitionCount: 6
  kafkaRestClassRef:
    name: default
    namespace: kafka
  configs:
    cleanup.policy: "delete"
---
apiVersion: platform.confluent.io/v1beta1
kind: KafkaTopic
metadata:
  name: clickstream
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  replicas: 3
  partitionCount: 6
  kafkaRestClassRef:
    name: default
    namespace: kafka
  configs:
    cleanup.policy: "delete"
---
apiVersion: platform.confluent.io/v1beta1
kind: KafkaTopic
metadata:
  name: enriched-orders
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  replicas: 3
  partitionCount: 6
  kafkaRestClassRef:
    name: default
    namespace: kafka
  configs:
    cleanup.policy: "delete"
---
apiVersion: platform.confluent.io/v1beta1
kind: KafkaTopic
metadata:
  name: user-activity
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  replicas: 3
  partitionCount: 6
  kafkaRestClassRef:
    name: default
    namespace: kafka
  configs:
    cleanup.policy: "delete"
```

Note: `users` topic uses `compact` cleanup policy since it serves as a changelog/lookup table for temporal joins.

- [ ] **Step 2: Validate Kustomize renders**

Run:
```bash
kubectl kustomize workloads/cp-flink-sql-sandbox/overlays/flink-demo/ 2>&1 | grep "kind: KafkaTopic" | wc -l
```

Expected: `5`

- [ ] **Step 3: Commit**

```bash
git add workloads/cp-flink-sql-sandbox/base/topics.yaml
git commit -m "Replace demo topics with e-commerce data model

Replace myevent/myaggregated with users, orders, clickstream,
enriched-orders, and user-activity topics (6 partitions, 3 replicas)."
```

---

## Task 3: Replace Schemas

**Files:**
- Modify: `workloads/cp-flink-sql-sandbox/base/schemas.yaml`

- [ ] **Step 1: Replace schemas.yaml with 5 ConfigMaps and 5 Schema CRDs**

Replace the entire contents of `schemas.yaml` with:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: users-value-avro-schema
  namespace: flink
data:
  schema: |
    {
      "type": "record",
      "name": "User",
      "namespace": "com.example.demo",
      "fields": [
        {"name": "user_id", "type": "string", "doc": "Unique user identifier"},
        {"name": "name", "type": "string", "doc": "Full name of the user"},
        {"name": "email", "type": "string", "doc": "Email address"},
        {"name": "region", "type": "string", "doc": "Geographic region (e.g., US-East, EU-West)"},
        {
          "name": "registered_at",
          "type": {"type": "long", "logicalType": "timestamp-millis"},
          "doc": "Registration timestamp in milliseconds since epoch"
        }
      ]
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: orders-value-avro-schema
  namespace: flink
data:
  schema: |
    {
      "type": "record",
      "name": "Order",
      "namespace": "com.example.demo",
      "fields": [
        {"name": "order_id", "type": "string", "doc": "Unique order identifier"},
        {"name": "user_id", "type": "string", "doc": "User who placed the order"},
        {"name": "product", "type": "string", "doc": "Product name"},
        {"name": "amount", "type": "double", "doc": "Order amount in the specified currency"},
        {"name": "currency", "type": "string", "doc": "Currency code (e.g., USD, EUR)"},
        {
          "name": "order_time",
          "type": {"type": "long", "logicalType": "timestamp-millis"},
          "doc": "Order timestamp in milliseconds since epoch"
        }
      ]
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickstream-value-avro-schema
  namespace: flink
data:
  schema: |
    {
      "type": "record",
      "name": "ClickEvent",
      "namespace": "com.example.demo",
      "fields": [
        {"name": "session_id", "type": "string", "doc": "Browser session identifier"},
        {"name": "user_id", "type": "string", "doc": "User performing the action"},
        {"name": "page_url", "type": "string", "doc": "URL of the page visited"},
        {"name": "action", "type": "string", "doc": "Action performed (e.g., view, click, add_to_cart)"},
        {
          "name": "event_time",
          "type": {"type": "long", "logicalType": "timestamp-millis"},
          "doc": "Event timestamp in milliseconds since epoch"
        }
      ]
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: enriched-orders-value-avro-schema
  namespace: flink
data:
  schema: |
    {
      "type": "record",
      "name": "EnrichedOrder",
      "namespace": "com.example.demo",
      "fields": [
        {"name": "order_id", "type": "string", "doc": "Unique order identifier"},
        {"name": "user_id", "type": "string", "doc": "User who placed the order"},
        {"name": "product", "type": "string", "doc": "Product name"},
        {"name": "amount", "type": "double", "doc": "Order amount"},
        {"name": "currency", "type": "string", "doc": "Currency code"},
        {
          "name": "order_time",
          "type": {"type": "long", "logicalType": "timestamp-millis"},
          "doc": "Order timestamp"
        },
        {"name": "name", "type": "string", "doc": "User's full name"},
        {"name": "email", "type": "string", "doc": "User's email address"},
        {"name": "region", "type": "string", "doc": "User's region"},
        {"name": "click_count", "type": ["null", "long"], "default": null, "doc": "Number of recent clicks by this user"},
        {"name": "last_page_url", "type": ["null", "string"], "default": null, "doc": "Last page visited by this user"}
      ]
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-activity-value-avro-schema
  namespace: flink
data:
  schema: |
    {
      "type": "record",
      "name": "UserActivity",
      "namespace": "com.example.demo",
      "fields": [
        {"name": "user_id", "type": "string", "doc": "Unique user identifier"},
        {"name": "name", "type": "string", "doc": "User's full name"},
        {"name": "email", "type": "string", "doc": "User's email address"},
        {"name": "region", "type": "string", "doc": "User's region"},
        {"name": "order_count", "type": ["null", "long"], "default": null, "doc": "Number of orders in the window"},
        {"name": "total_spend", "type": ["null", "double"], "default": null, "doc": "Total spend in the window"},
        {"name": "click_count", "type": ["null", "long"], "default": null, "doc": "Number of clicks in the window"},
        {"name": "unique_pages", "type": ["null", "long"], "default": null, "doc": "Number of unique pages visited"},
        {
          "name": "window_start",
          "type": ["null", {"type": "long", "logicalType": "timestamp-millis"}],
          "default": null,
          "doc": "Start of the aggregation window"
        }
      ]
    }
---
apiVersion: platform.confluent.io/v1beta1
kind: Schema
metadata:
  name: users-value
  annotations:
    argocd.argoproj.io/sync-wave: "35"
spec:
  schemaRegistryClusterRef:
    name: schemaregistry
    namespace: kafka
  data:
    configRef: users-value-avro-schema
    format: avro
  compatibilityLevel: BACKWARD
---
apiVersion: platform.confluent.io/v1beta1
kind: Schema
metadata:
  name: orders-value
  annotations:
    argocd.argoproj.io/sync-wave: "35"
spec:
  schemaRegistryClusterRef:
    name: schemaregistry
    namespace: kafka
  data:
    configRef: orders-value-avro-schema
    format: avro
  compatibilityLevel: BACKWARD
---
apiVersion: platform.confluent.io/v1beta1
kind: Schema
metadata:
  name: clickstream-value
  annotations:
    argocd.argoproj.io/sync-wave: "35"
spec:
  schemaRegistryClusterRef:
    name: schemaregistry
    namespace: kafka
  data:
    configRef: clickstream-value-avro-schema
    format: avro
  compatibilityLevel: BACKWARD
---
apiVersion: platform.confluent.io/v1beta1
kind: Schema
metadata:
  name: enriched-orders-value
  annotations:
    argocd.argoproj.io/sync-wave: "35"
spec:
  schemaRegistryClusterRef:
    name: schemaregistry
    namespace: kafka
  data:
    configRef: enriched-orders-value-avro-schema
    format: avro
  compatibilityLevel: BACKWARD
---
apiVersion: platform.confluent.io/v1beta1
kind: Schema
metadata:
  name: user-activity-value
  annotations:
    argocd.argoproj.io/sync-wave: "35"
spec:
  schemaRegistryClusterRef:
    name: schemaregistry
    namespace: kafka
  data:
    configRef: user-activity-value-avro-schema
    format: avro
  compatibilityLevel: BACKWARD
```

- [ ] **Step 2: Validate Kustomize renders all 10 documents**

Run:
```bash
kubectl kustomize workloads/cp-flink-sql-sandbox/overlays/flink-demo/ 2>&1 | grep -c "kind: ConfigMap\|kind: Schema"
```

Expected: At least `13` (5 schema ConfigMaps + 5 Schema CRDs + 3 existing CMF ConfigMaps)

- [ ] **Step 3: Commit**

```bash
git add workloads/cp-flink-sql-sandbox/base/schemas.yaml
git commit -m "Replace demo schemas with e-commerce Avro schemas

5 ConfigMaps + 5 Schema CRDs for users, orders, clickstream,
enriched-orders, and user-activity topics."
```

---

## Task 4: Create Datagen Connectors

**Files:**
- Create: `workloads/cp-flink-sql-sandbox/base/connectors.yaml`

- [ ] **Step 1: Create connectors.yaml with 3 datagen Connector CRDs**

Create `workloads/cp-flink-sql-sandbox/base/connectors.yaml`:

```yaml
---
apiVersion: platform.confluent.io/v1beta1
kind: Connector
metadata:
  name: datagen-users
  namespace: kafka
  annotations:
    argocd.argoproj.io/sync-wave: "36"
spec:
  class: io.confluent.kafka.connect.datagen.DatagenConnector
  taskMax: 1
  connectClusterRef:
    name: connect
    namespace: kafka
  configs:
    kafka.topic: users
    quickstart: users
    max.interval: "10"
    iterations: "-1"
    key.converter: org.apache.kafka.connect.storage.StringConverter
    value.converter: io.confluent.connect.avro.AvroConverter
    value.converter.schema.registry.url: "http://schemaregistry.kafka.svc.cluster.local:8081"
---
apiVersion: platform.confluent.io/v1beta1
kind: Connector
metadata:
  name: datagen-orders
  namespace: kafka
  annotations:
    argocd.argoproj.io/sync-wave: "36"
spec:
  class: io.confluent.kafka.connect.datagen.DatagenConnector
  taskMax: 1
  connectClusterRef:
    name: connect
    namespace: kafka
  configs:
    kafka.topic: orders
    quickstart: orders
    max.interval: "10"
    iterations: "-1"
    key.converter: org.apache.kafka.connect.storage.StringConverter
    value.converter: io.confluent.connect.avro.AvroConverter
    value.converter.schema.registry.url: "http://schemaregistry.kafka.svc.cluster.local:8081"
---
apiVersion: platform.confluent.io/v1beta1
kind: Connector
metadata:
  name: datagen-clickstream
  namespace: kafka
  annotations:
    argocd.argoproj.io/sync-wave: "36"
spec:
  class: io.confluent.kafka.connect.datagen.DatagenConnector
  taskMax: 1
  connectClusterRef:
    name: connect
    namespace: kafka
  configs:
    kafka.topic: clickstream
    quickstart: clickstream
    max.interval: "10"
    iterations: "-1"
    key.converter: org.apache.kafka.connect.storage.StringConverter
    value.converter: io.confluent.connect.avro.AvroConverter
    value.converter.schema.registry.url: "http://schemaregistry.kafka.svc.cluster.local:8081"
```

Notes:
- Explicit `namespace: kafka` overrides the ArgoCD Application's `flink` namespace destination.
- Sync-wave `"36"` (intentional deviation from spec's `"35"`) ensures schemas are registered before connectors start producing. The spec should be updated to reflect this.
- **Schema mismatch warning:** The datagen `quickstart` templates (e.g., `quickstart: users`) use their own predefined schemas with field names like `userid`, `registertime`, `regionid` — these do NOT match our custom Avro schemas (`user_id`, `name`, `email`, `region`, `registered_at`). The datagen connector auto-registers its own schemas to Schema Registry, which will conflict with our pre-registered schemas. During implementation, the connector configs will likely need to use `schema.string` with a custom Avro schema matching our definitions, or the SQL statements will need to use the datagen-generated field names instead. Resolve this during implementation by inspecting the actual datagen output.

- [ ] **Step 2: Validate Kustomize renders (will fail — file not yet in kustomization.yaml)**

Run:
```bash
cat workloads/cp-flink-sql-sandbox/base/connectors.yaml | grep "kind: Connector" | wc -l
```

Expected: `3`

- [ ] **Step 3: Commit**

```bash
git add workloads/cp-flink-sql-sandbox/base/connectors.yaml
git commit -m "Add datagen connectors for users, orders, clickstream

Three Connector CRDs generating ~100 msg/s each to the source topics.
Deployed in kafka namespace with sync-wave 36 (after schemas)."
```

---

## Task 5: Create Sample Queries ConfigMap

**Files:**
- Create: `workloads/cp-flink-sql-sandbox/base/sample-queries-configmap.yaml`

- [ ] **Step 1: Create the ConfigMap with sample SQL queries**

Create `workloads/cp-flink-sql-sandbox/base/sample-queries-configmap.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: flink-sql-sample-queries
  namespace: flink
data:
  01-inspect-users.sql: |
    -- Inspect user records from the datagen connector
    SELECT * FROM `kafka-cat`.`main-kafka-cluster`.`users` LIMIT 10;
  02-inspect-orders.sql: |
    -- Inspect order records from the datagen connector
    SELECT * FROM `kafka-cat`.`main-kafka-cluster`.`orders` LIMIT 10;
  03-inspect-clickstream.sql: |
    -- Inspect clickstream events from the datagen connector
    SELECT * FROM `kafka-cat`.`main-kafka-cluster`.`clickstream` LIMIT 10;
  04-users-by-region.sql: |
    -- Count users by region
    SELECT region, COUNT(*) as user_count
    FROM `kafka-cat`.`main-kafka-cluster`.`users`
    GROUP BY region;
  05-spend-per-user.sql: |
    -- Total spend per user
    SELECT user_id, SUM(amount) as total_spend
    FROM `kafka-cat`.`main-kafka-cluster`.`orders`
    GROUP BY user_id;
  06-popular-pages.sql: |
    -- Most visited pages
    SELECT page_url, COUNT(*) as visit_count
    FROM `kafka-cat`.`main-kafka-cluster`.`clickstream`
    GROUP BY page_url;
  07-inspect-enriched-orders.sql: |
    -- Verify enriched orders output (produced by Flink SQL join job)
    SELECT * FROM `kafka-cat`.`main-kafka-cluster`.`enriched-orders` LIMIT 10;
  08-inspect-user-activity.sql: |
    -- Verify user activity output (produced by Flink SQL join job)
    SELECT * FROM `kafka-cat`.`main-kafka-cluster`.`user-activity` LIMIT 10;
```

- [ ] **Step 2: Verify valid YAML**

Run:
```bash
cat workloads/cp-flink-sql-sandbox/base/sample-queries-configmap.yaml | grep "\.sql:" | wc -l
```

Expected: `8`

- [ ] **Step 3: Commit**

```bash
git add workloads/cp-flink-sql-sandbox/base/sample-queries-configmap.yaml
git commit -m "Add sample Flink SQL inspection queries as ConfigMap

Eight sample queries for inspecting source and sink topics via CMF API."
```

---

## Task 6: Create Flink SQL Jobs PostSync Job

**Files:**
- Create: `workloads/cp-flink-sql-sandbox/base/flink-sql-jobs.yaml`

Reference existing pattern: `workloads/cp-flink-sql-sandbox/base/cmf-init-job.yaml` (for init container and CMF API interaction structure).

- [ ] **Step 1: Create flink-sql-jobs.yaml**

Create `workloads/cp-flink-sql-sandbox/base/flink-sql-jobs.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: flink-sql-statements
  namespace: flink
data:
  enriched-orders.sql: |
    INSERT INTO `kafka-cat`.`main-kafka-cluster`.`enriched-orders`
    SELECT
      o.`order_id`,
      o.`user_id`,
      o.`product`,
      o.`amount`,
      o.`currency`,
      o.`order_time`,
      u.`name`,
      u.`email`,
      u.`region`,
      c.`click_count`,
      c.`last_page_url`
    FROM `kafka-cat`.`main-kafka-cluster`.`orders` o
    JOIN `kafka-cat`.`main-kafka-cluster`.`users` FOR SYSTEM_TIME AS OF o.`order_time` AS u
      ON o.`user_id` = u.`user_id`
    LEFT JOIN (
      SELECT
        `user_id`,
        COUNT(*) AS `click_count`,
        LAST_VALUE(`page_url`) AS `last_page_url`
      FROM `kafka-cat`.`main-kafka-cluster`.`clickstream`
      GROUP BY `user_id`, HOP(`event_time`, INTERVAL '1' MINUTE, INTERVAL '5' MINUTES)
    ) c ON o.`user_id` = c.`user_id`
  user-activity.sql: |
    INSERT INTO `kafka-cat`.`main-kafka-cluster`.`user-activity`
    SELECT
      u.`user_id`,
      u.`name`,
      u.`email`,
      u.`region`,
      o.`order_count`,
      o.`total_spend`,
      c.`click_count`,
      c.`unique_pages`,
      c.`window_start`
    FROM `kafka-cat`.`main-kafka-cluster`.`users` FOR SYSTEM_TIME AS OF c.`window_start` AS u
    LEFT JOIN (
      SELECT
        `user_id`,
        COUNT(*) AS `order_count`,
        SUM(`amount`) AS `total_spend`,
        `window_start`,
        `window_end`
      FROM TABLE(
        TUMBLE(TABLE `kafka-cat`.`main-kafka-cluster`.`orders`, DESCRIPTOR(`order_time`), INTERVAL '5' MINUTES)
      )
      GROUP BY `user_id`, `window_start`, `window_end`
    ) o ON u.`user_id` = o.`user_id`
    LEFT JOIN (
      SELECT
        `user_id`,
        COUNT(*) AS `click_count`,
        COUNT(DISTINCT `page_url`) AS `unique_pages`,
        `window_start`,
        `window_end`
      FROM TABLE(
        TUMBLE(TABLE `kafka-cat`.`main-kafka-cluster`.`clickstream`, DESCRIPTOR(`event_time`), INTERVAL '5' MINUTES)
      )
      GROUP BY `user_id`, `window_start`, `window_end`
    ) c ON u.`user_id` = c.`user_id` AND o.`window_start` = c.`window_start`
---
apiVersion: batch/v1
kind: Job
metadata:
  name: flink-sql-jobs-init
  namespace: flink
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 5
  template:
    metadata:
      name: flink-sql-jobs-init
    spec:
      restartPolicy: OnFailure
      initContainers:
      - name: wait-for-cmf
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          echo "Waiting for CMF to be ready..."
          until nc -z cmf-service.operator.svc.cluster.local 80; do
            echo "CMF not ready yet, waiting..."
            sleep 5
          done
          echo "CMF is ready!"
      - name: wait-for-compute-pool
        image: confluentinc/confluent-cli:4.53.0
        env:
        - name: CMF_URL
          value: "http://cmf-service.operator.svc.cluster.local:80"
        command:
        - /bin/sh
        - -c
        - |
          echo "Waiting for compute pool to be ready..."
          until confluent flink compute-pool list --environment env1 --url ${CMF_URL} 2>/dev/null | grep -q "pool"; do
            echo "Compute pool not ready yet, waiting..."
            sleep 10
          done
          echo "Compute pool is ready!"
      containers:
      - name: submit-sql-statements
        image: confluentinc/confluent-cli:4.53.0
        env:
        - name: CMF_URL
          value: "http://cmf-service.operator.svc.cluster.local:80"
        volumeMounts:
        - name: sql-statements
          mountPath: /sql
        command:
        - /bin/sh
        - -c
        - |
          set -e

          echo "Submitting enriched-orders SQL job..."
          confluent flink statement create enriched-orders \
            --sql "$(cat /sql/enriched-orders.sql)" \
            --compute-pool pool \
            --environment env1 \
            --database main-kafka-cluster \
            --catalog kafka-cat \
            --url ${CMF_URL} || echo "Statement may already exist"

          echo "Submitting user-activity SQL job..."
          confluent flink statement create user-activity \
            --sql "$(cat /sql/user-activity.sql)" \
            --compute-pool pool \
            --environment env1 \
            --database main-kafka-cluster \
            --catalog kafka-cat \
            --url ${CMF_URL} || echo "Statement may already exist"

          echo "Listing running statements..."
          confluent flink statement list \
            --environment env1 \
            --url ${CMF_URL}

          echo "SQL jobs submission complete!"
      volumes:
      - name: sql-statements
        configMap:
          name: flink-sql-statements
```

> **Implementation note:** The SQL statements use fully qualified table names (`catalog.database.table`). The exact SQL syntax — especially the temporal join (`FOR SYSTEM_TIME AS OF`) and window TVF (`TABLE(TUMBLE(...))`) — must be validated against the actual Flink 1.19 runtime. If the temporal join fails (e.g., because the `users` topic is not recognized as a versioned table), fall back to a regular stream-stream join with state TTL configured via `table.exec.state.ttl` in the compute pool config.

- [ ] **Step 2: Verify valid YAML**

Run:
```bash
cat workloads/cp-flink-sql-sandbox/base/flink-sql-jobs.yaml | grep -E "^kind:" | sort | uniq -c
```

Expected:
```
      1 kind: ConfigMap
      1 kind: Job
```

- [ ] **Step 3: Commit**

```bash
git add workloads/cp-flink-sql-sandbox/base/flink-sql-jobs.yaml
git commit -m "Add Flink SQL join jobs as PostSync hook

Two INSERT INTO statements: enriched-orders (temporal join) and
user-activity (windowed aggregation). Submitted via CMF REST API."
```

---

## Task 7: Add Autoscaler Config to Compute Pool

**Files:**
- Modify: `workloads/cp-flink-sql-sandbox/base/cmf-config-configmap.yaml:61-78` (the `flinkConfiguration` block inside `compute-pool.json`)

- [ ] **Step 1: Add autoscaler settings to compute pool flinkConfiguration**

In `workloads/cp-flink-sql-sandbox/base/cmf-config-configmap.yaml`, add the following entries to the `flinkConfiguration` JSON object inside the `cmf-compute-pool-config` ConfigMap (after `"state.checkpoints.num-retained": "10"`):

```json
            "kubernetes.operator.job.autoscaler.enabled": "true",
            "kubernetes.operator.job.autoscaler.metrics.window": "3m",
            "kubernetes.operator.job.autoscaler.stabilization.interval": "1m",
            "kubernetes.operator.job.autoscaler.target.utilization": "0.7",
            "kubernetes.operator.job.autoscaler.scale-down.max-factor": "0.5",
            "kubernetes.operator.job.autoscaler.scale-up.max-factor": "2.0"
```

Also add TaskManager replica bounds and state TTL. The `minReplicas`/`maxReplicas` fields go inside the `taskManager` object (alongside `resource`), and state TTL goes in `flinkConfiguration`:

```json
            "table.exec.state.ttl": "1h"
```

And inside the `taskManager` block:

```json
          "taskManager": {
            "replicas": 1,
            "minReplicas": 1,
            "maxReplicas": 5,
            "resource": {
              "cpu": 1.0,
              "memory": "1700m"
            }
          }
```

> **Implementation note:** The exact JSON path for `minReplicas`/`maxReplicas` depends on the CMF ComputePool API version. Verify against the CMF REST API docs or by inspecting the current compute pool spec. If the fields are not at `taskManager` level, try `clusterSpec` level or a separate `scaling` block. The key requirement is that these bounds are recognized by CMF when creating the compute pool.

- [ ] **Step 2: Validate JSON is well-formed**

Run:
```bash
kubectl kustomize workloads/cp-flink-sql-sandbox/overlays/flink-demo/ 2>&1 | grep -q "autoscaler.enabled" && echo "OK" || echo "FAIL"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add workloads/cp-flink-sql-sandbox/base/cmf-config-configmap.yaml
git commit -m "Enable CMF autoscaler on Flink compute pool

Autoscaler with 70% target utilization, 1-5 TaskManagers,
3m metrics window, 1m stabilization interval."
```

---

## Task 8: Update Kustomization to Include New Resources

**Files:**
- Modify: `workloads/cp-flink-sql-sandbox/base/kustomization.yaml`

- [ ] **Step 1: Add new resource files to kustomization.yaml**

Replace the entire contents of `workloads/cp-flink-sql-sandbox/base/kustomization.yaml` with:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - topics.yaml
  - schemas.yaml
  - connectors.yaml
  - cmf-config-configmap.yaml
  - cmf-init-job.yaml
  - cmf-compute-pool-job.yaml
  - flink-sql-jobs.yaml
  - sample-queries-configmap.yaml
```

- [ ] **Step 2: Validate full Kustomize build**

Run:
```bash
kubectl kustomize workloads/cp-flink-sql-sandbox/overlays/flink-demo/ 2>&1 | head -5
```

Expected: Valid YAML output (no errors).

Run a full resource count:
```bash
kubectl kustomize workloads/cp-flink-sql-sandbox/overlays/flink-demo/ 2>&1 | grep "^kind:" | sort | uniq -c
```

Expected approximately:
```
     10 kind: ConfigMap     (5 schema + 3 CMF config + 1 sample queries + 1 SQL statements)
      3 kind: Connector
      3 kind: Job           (2 existing PostSync + 1 new SQL PostSync)
      5 kind: KafkaTopic
      5 kind: Schema
```

- [ ] **Step 3: Commit**

```bash
git add workloads/cp-flink-sql-sandbox/base/kustomization.yaml
git commit -m "Register new resources in kustomization

Add connectors, flink-sql-jobs, and sample-queries-configmap."
```

---

## Task 9: Rewrite README

**Files:**
- Modify: `workloads/cp-flink-sql-sandbox/README.md`

- [ ] **Step 1: Replace README with updated documentation**

Replace the entire contents of `workloads/cp-flink-sql-sandbox/README.md` with:

```markdown
# CP Flink SQL Sandbox

## Overview

A self-contained e-commerce demo for Confluent Platform with Apache Flink. Deploys datagen connectors, Kafka topics, Avro schemas, Flink SQL join jobs, and CMF autoscaling.

## Data Flow

```
datagen-users -----> [users]       --+
                                     +--> Flink SQL Job 1 --> [enriched-orders]
datagen-orders ----> [orders]      --+
                                     +--> Flink SQL Job 2 --> [user-activity]
datagen-clickstream-> [clickstream] -+
```

## What's Included

### Kafka Topics (5)
- **Source**: `users`, `orders`, `clickstream` (6 partitions, 3 replicas each)
- **Sink**: `enriched-orders`, `user-activity`

### Datagen Connectors (3)
- `datagen-users`, `datagen-orders`, `datagen-clickstream`
- Each produces ~100 messages/second with Avro serialization

### Avro Schemas (5)
- Registered in Schema Registry for all source and sink topics

### Flink SQL Jobs (2)
- **enriched-orders**: Temporal join of orders with user profiles + clickstream summary
- **user-activity**: Windowed aggregation of user behavior across all streams

### CMF Autoscaling
- Compute pool `pool` with 1-5 TaskManagers
- 70% utilization target, 3-minute metrics window

### Sample Queries
- Available in the `flink-sql-sample-queries` ConfigMap
- Run via `kubectl get configmap flink-sql-sample-queries -n flink -o yaml`

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator
- Kafka cluster with Schema Registry and Connect
- S3proxy for object storage

## Getting Started

Once this application is synced in ArgoCD:

1. **Verify data generation**: Check Control Center for messages flowing into `users`, `orders`, `clickstream` topics
2. **Verify SQL jobs**: Check CMF for running `enriched-orders` and `user-activity` statements
3. **Inspect output**: View `enriched-orders` and `user-activity` topics in Control Center
4. **Run sample queries**: Use the CMF API to execute queries from the sample queries ConfigMap

### Endpoints

- **CMF API**: `http://cmf.flink-demo.confluentdemo.local`
- **Control Center**: `http://controlcenter.flink-demo.confluentdemo.local`
- **S3proxy**: `http://s3proxy.flink-demo.confluentdemo.local`

### Running Sample Queries via CMF API

```bash
# List available sample queries
kubectl get configmap flink-sql-sample-queries -n flink -o jsonpath='{.data}' | jq -r 'keys[]'

# Get a specific query
kubectl get configmap flink-sql-sample-queries -n flink -o jsonpath='{.data.01-inspect-users\.sql}'

# Submit a query via CMF API
confluent flink statement create my-query \
  --sql "SELECT * FROM \`kafka-cat\`.\`main-kafka-cluster\`.\`users\` LIMIT 10;" \
  --compute-pool pool \
  --environment env1 \
  --database main-kafka-cluster \
  --catalog kafka-cat \
  --url http://cmf.flink-demo.confluentdemo.local
```

## Breaking Changes from Previous Version

This workload replaces the original `cp-flink-sql` demo:
- Old topics `myevent` and `myaggregated` are no longer managed (orphaned — manual cleanup required)
- Old schemas `myevent-value` and `myaggregated-value` are no longer managed
- The upstream `cp-flink-sql` guide no longer applies — use this README instead
```

- [ ] **Step 2: Commit**

```bash
git add workloads/cp-flink-sql-sandbox/README.md
git commit -m "Rewrite README for evolved e-commerce demo

Document new topics, connectors, SQL jobs, autoscaling,
sample queries, and getting started instructions."
```

---

## Task 10: Final Validation and Documentation

- [ ] **Step 1: Run full Kustomize build for the overlay**

Run:
```bash
kubectl kustomize workloads/cp-flink-sql-sandbox/overlays/flink-demo/ > /dev/null 2>&1 && echo "Kustomize build: OK" || echo "Kustomize build: FAIL"
```

Expected: `Kustomize build: OK`

- [ ] **Step 2: Verify all resource kinds are in the AppProject whitelist**

Run:
```bash
kubectl kustomize workloads/cp-flink-sql-sandbox/overlays/flink-demo/ 2>&1 | grep -E "^kind:" | sort -u
```

Cross-reference each kind against the `workloads` AppProject `namespaceResourceWhitelist` in `bootstrap/templates/argocd-projects.yaml`. Every kind must appear.

Expected kinds and their whitelist status:
- `ConfigMap` — whitelisted (core group)
- `Connector` — whitelisted (added in Task 1)
- `Job` — whitelisted (batch group)
- `KafkaTopic` — whitelisted (platform.confluent.io)
- `Schema` — whitelisted (platform.confluent.io)

- [ ] **Step 3: Verify sync wave ordering is correct**

Run:
```bash
kubectl kustomize workloads/cp-flink-sql-sandbox/overlays/flink-demo/ 2>&1 | grep -B5 "sync-wave" | grep -E "name:|sync-wave"
```

Expected ordering:
- Topics at wave `"30"`
- Schemas at wave `"35"`
- Connectors at wave `"36"`
- PostSync hooks have `argocd.argoproj.io/hook: PostSync` (no wave number)

- [ ] **Step 4: Verify datagen plugin is available in Connect image**

If you have a running cluster, verify:
```bash
kubectl exec -n kafka connect-0 -- curl -s http://localhost:8083/connector-plugins | grep -i datagen
```

Expected: Output containing `io.confluent.kafka.connect.datagen.DatagenConnector`. If not found, the Connect deployment needs a `confluent-hub install` init container or a custom image with the plugin.

If no cluster is available, note this as a runtime verification step for first deployment.

- [ ] **Step 5: Review and update project documentation**

Check `docs/architecture.md` and `docs/project_spec.md` for references to `cp-flink-sql-sandbox`, `myevent`, `myaggregated`, or the Flink demo data flow. Update any sections that describe the old demo to reflect the new e-commerce data model. If no references exist, no changes needed.

- [ ] **Step 6: Update changelog**

Add an entry to `docs/changelog.md` under the next version:

```markdown
- Evolve `cp-flink-sql-sandbox` into a rich e-commerce demo with datagen connectors, Flink SQL join jobs, sample queries, and CMF autoscaling
```

- [ ] **Step 7: Commit changelog and docs updates**

```bash
git add docs/changelog.md
git commit -m "Update changelog for flink-demo evolution"
```
