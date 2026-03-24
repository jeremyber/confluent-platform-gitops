# CP Flink E-Commerce Demo

## Overview

A self-contained e-commerce demo for Confluent Platform with Apache Flink. Deploys a custom JSON data producer, Kafka topics, JSON schemas, and Flink SQL join/aggregation jobs.

This workload is fully independent and does not modify any existing workloads in the repository.

## Data Flow

```
Shell Producer (users)      --> [users]       --+
                                                +--> Flink SQL Job 1 --> [enriched-orders]
Shell Producer (orders)     --> [orders]      --+
                                                +--> Flink SQL Job 2 --> [user-activity]
Shell Producer (clickstream)--> [clickstream] -+
```

## What's Included

### Kafka Resources
- **Kafka Topics (5)**: `users`, `orders`, `clickstream` (source) + `enriched-orders`, `user-activity` (sink)
- **JSON Schemas (5)**: Registered in Schema Registry for all topics
- **Data Producer**: Deployment with 3 containers producing structured JSON data continuously (~1-2 msg/sec per topic)

### Flink Resources
- **Flink SQL Jobs (2)**:
  - `enriched-orders`: Interval join of orders with user profiles
  - `user-activity`: Windowed clickstream aggregation joined with user profiles
- **Compute Pool**: Dedicated `ecommerce-pool` with CMF autoscaling (1-5 TaskManagers, 70% utilization target)
- **Sample Queries**: Pre-configured inspection queries in `flink-sql-sample-queries` ConfigMap

## Deployment Order

After applying the bootstrap app, some infrastructure auto-syncs and some requires manual sync.

**Auto-sync (no action needed):**
namespaces (100) → cfk-operator (105) → cmf-ingress (110) → controlcenter-ingress (115) → flink-kubernetes-operator (116) → observability-resources (117) → cmf-operator (118)

**Manual sync — in this order:**

| Order | Wave | ArgoCD App | What it deploys |
|-------|------|------------|-----------------|
| 1 | 106 | `s3proxy` | Object storage for Flink checkpoints |
| 2 | 110 | `confluent-resources` | Kafka brokers, KRaft, Schema Registry, Connect |
| 3 | 115 | `cp-flink-sql-sandbox` | PostSync creates shared Kafka catalog + database in CMF |
| 4 | 116 | `cp-flink-ecommerce-demo` | Topics, schemas, producer, Flink SQL jobs |
| 5 | 120 | `flink-resources` | FlinkEnvironment, compute pools |

**Wait for confluent-resources to be fully healthy** (all Kafka brokers, SR, Connect Running) before syncing subsequent apps.

The ecommerce demo's PostSync jobs have init containers that wait for the catalog, database, and compute pool to exist — so syncing steps 3-5 close together is fine.

## Verification

### 1. Check the producer is running
```bash
kubectl get pods -n kafka -l app=datagen-producer
# Should show 3/3 Running
```

### 2. Spot-check topic data
```bash
kubectl exec kafka-0 -n kafka -c kafka -- kafka-console-consumer \
  --bootstrap-server localhost:9071 --topic users --max-messages 3 --timeout-ms 5000
```

### 3. Check Flink SQL statements
```bash
# Via CMF API
confluent flink statement list --environment env1 \
  --url http://cmf-service.operator.svc.cluster.local:80

# Or via kubectl
kubectl exec connect-0 -n kafka -- curl -s \
  "http://cmf-service.operator.svc.cluster.local:80/cmf/api/v1/environments/env1/statements" \
  | python3 -m json.tool
```

### 4. Check enriched output topics
```bash
kubectl exec kafka-0 -n kafka -c kafka -- kafka-console-consumer \
  --bootstrap-server localhost:9071 --topic enriched-orders --max-messages 3 --timeout-ms 10000
```

### Endpoints

- **CMF API**: `http://cmf.flink-demo.confluentdemo.local`
- **Control Center**: `http://controlcenter.flink-demo.confluentdemo.local`
- **S3proxy**: `http://s3proxy.flink-demo.confluentdemo.local`

## Removing This Demo

To remove this demo without affecting other workloads:
1. Delete the ArgoCD Application `cp-flink-ecommerce-demo`
2. The `ecommerce-pool` compute pool, topics, schemas, and producer will be cleaned up
3. No other workloads are affected
