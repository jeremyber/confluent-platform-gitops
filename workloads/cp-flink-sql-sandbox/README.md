# CP Flink SQL Sandbox

## Overview

A self-contained e-commerce demo for Confluent Platform with Apache Flink. This workload deploys datagen connectors, Kafka topics, Avro schemas, Flink SQL join jobs, and CMF autoscaling to demonstrate real-time stream processing patterns.

The demo simulates an e-commerce platform with users, orders, and clickstream data that are enriched and aggregated in real-time using Flink SQL.

## Data Flow

```
datagen-users -----> [users]       --+
                                     +--> Flink SQL Job 1 --> [enriched-orders]
datagen-orders ----> [orders]      --+
                                     +--> Flink SQL Job 2 --> [user-activity]
datagen-clickstream-> [clickstream] -+
```

**Source Topics (with datagen connectors):**
- `users` - User profile data (~100 msg/s)
- `orders` - E-commerce order events (~100 msg/s)
- `clickstream` - User clickstream events (~100 msg/s)

**Sink Topics (produced by Flink SQL):**
- `enriched-orders` - Orders joined with user profile data
- `user-activity` - Windowed aggregation of clickstream activity per user

## What's Included

### Kafka Resources
- **Kafka Topics (5)**: 3 source topics + 2 sink topics, all with Avro serialization
- **Avro Schemas (5)**: Registered in Schema Registry for all topics
- **Datagen Connectors (3)**: Kafka Connect datagen source connectors producing ~100 msg/s each

### Flink Resources
- **Flink SQL Jobs (2)**:
  - `enriched-orders-job` - Temporal join of orders with users
  - `user-activity-job` - Tumbling window aggregation of clickstream by user
- **CMF Autoscaling**: Configured with 1-5 TaskManagers, 70% CPU utilization target
- **Sample Queries**: Pre-configured inspection queries in `flink-sql-sample-queries` ConfigMap

### Infrastructure
- **Flink Catalog**: Kafka catalog with Schema Registry integration
- **Flink Database**: Connection to Kafka cluster
- **Compute Pool**: Flink compute pool with S3 checkpoint/savepoint storage

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator
- Kafka cluster with Schema Registry and Connect
- S3proxy for object storage

## Getting Started

Once this application is synced in ArgoCD, follow these steps to explore the demo:

### 1. Verify Data Generation

Access Control Center to verify that all three source topics are receiving data from the datagen connectors:

```bash
# Control Center UI
open http://controlcenter.flink-demo.confluentdemo.local
```

Navigate to **Topics** and verify message throughput on:
- `users`
- `orders`
- `clickstream`

### 2. Verify SQL Jobs in CMF

Check that both Flink SQL jobs are running:

```bash
# List all SQL statements
kubectl exec -n flink deploy/cmf -- \
  curl -s http://localhost:8080/sql/v1/organizations/default/environments/default/statements | jq
```

You should see both `enriched-orders-job` and `user-activity-job` in `RUNNING` state.

### 3. Inspect Output Topics

Verify that the Flink SQL jobs are producing results to the sink topics:

```bash
# Via Control Center UI
open http://controlcenter.flink-demo.confluentdemo.local

# Or consume directly (requires Confluent CLI in a kafka client pod)
kubectl exec -it -n kafka kafka-0 -- bash
kafka-avro-console-consumer \
  --bootstrap-server kafka:9092 \
  --topic enriched-orders \
  --from-beginning \
  --property schema.registry.url=http://schemaregistry:8081
```

### 4. Run Sample Queries via CMF API

The workload includes pre-configured sample queries that you can execute to inspect the data:

```bash
# Get the sample queries ConfigMap
kubectl get configmap -n flink flink-sql-sample-queries -o yaml

# Example: List top 10 users by order count (temporal join result)
QUERY=$(cat <<'EOF'
SELECT user_id, user_name, COUNT(*) as order_count
FROM enriched_orders
GROUP BY user_id, user_name
ORDER BY order_count DESC
LIMIT 10;
EOF
)

# Submit query via CMF API
kubectl exec -n flink deploy/cmf -- \
  curl -s -X POST http://localhost:8080/sql/v1/organizations/default/environments/default/statements \
  -H "Content-Type: application/json" \
  -d "{\"sql\": \"$QUERY\", \"properties\": {\"sql.current-catalog\": \"kafka-catalog\", \"sql.current-database\": \"kafka-database\"}}" | jq

# Get statement results (replace <statement-name> with the name from the previous response)
kubectl exec -n flink deploy/cmf -- \
  curl -s http://localhost:8080/sql/v1/organizations/default/environments/default/statements/<statement-name>/results | jq
```

**Using Confluent CLI** (if available in your environment):

```bash
# Configure CLI to use CMF endpoint
export CMF_API_URL="http://cmf.flink-demo.confluentdemo.local"

# Submit a query
confluent flink statement create \
  --sql "SELECT * FROM enriched_orders LIMIT 10;" \
  --compute-pool <compute-pool-id>
```

### Endpoints

Access the following services via Ingress (when deployed in the `flink-demo` cluster):

- **CMF API**: `http://cmf.flink-demo.confluentdemo.local`
- **Control Center**: `http://controlcenter.flink-demo.confluentdemo.local`
- **S3proxy**: `http://s3proxy.flink-demo.confluentdemo.local`

## Breaking Changes from Previous Version

This workload has been completely redesigned from the original `cp-flink-sql-sandbox`. If you are upgrading from a previous version, be aware of the following breaking changes:

- **Old topics `myevent` and `myaggregated` are orphaned** - These topics are no longer managed by this workload and must be manually cleaned up if desired
- **Old schemas `myevent-value` and `myaggregated-value` are no longer managed** - These Schema Registry subjects will remain but are not used
- **The upstream cp-flink-sql guide no longer applies** - This workload is now a self-contained e-commerce demo and does not follow the steps in the [rjmfernandes/cp-flink-sql](https://github.com/rjmfernandes/cp-flink-sql) repository

To clean up old resources manually:

```bash
# Delete old topics (optional)
kubectl exec -n kafka kafka-0 -- kafka-topics --bootstrap-server kafka:9092 --delete --topic myevent
kubectl exec -n kafka kafka-0 -- kafka-topics --bootstrap-server kafka:9092 --delete --topic myaggregated

# Delete old schemas (optional)
kubectl exec -n kafka deploy/schemaregistry -- \
  curl -X DELETE http://localhost:8081/subjects/myevent-value
kubectl exec -n kafka deploy/schemaregistry -- \
  curl -X DELETE http://localhost:8081/subjects/myaggregated-value
```

## Architecture Notes

- **Sync Wave Ordering**: Resources are deployed in the following order to ensure dependencies are met:
  1. Wave 30: Topics
  2. Wave 35: Schemas
  3. Wave 36: Connectors (requires Kafka Connect with datagen plugin)
  4. Wave 40: Flink SQL Jobs (requires topics and schemas to exist)
  5. Wave 45: Autoscaler configuration

- **Connector Namespace**: Datagen connectors are deployed to the `kafka` namespace (where Kafka Connect runs) even though the ArgoCD application targets the `flink` namespace

- **Temporal Joins**: The `enriched-orders-job` uses Flink SQL temporal joins to combine order events with the latest user profile data at the time of the order

- **Windowed Aggregation**: The `user-activity-job` uses tumbling windows to aggregate clickstream events per user over time intervals
