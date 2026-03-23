# CP Flink E-Commerce Demo

## Overview

A self-contained e-commerce demo for Confluent Platform with Apache Flink. Deploys datagen connectors, Kafka topics, Avro schemas, Flink SQL join jobs, and CMF autoscaling.

This workload is fully independent and does not modify any existing workloads in the repository.

## Data Flow

```
datagen-users -----> [users]       --+
                                     +--> Flink SQL Job 1 --> [enriched-orders]
datagen-orders ----> [orders]      --+
                                     +--> Flink SQL Job 2 --> [user-activity]
datagen-clickstream-> [clickstream] -+
```

## What's Included

### Kafka Resources
- **Kafka Topics (5)**: `users`, `orders`, `clickstream` (source) + `enriched-orders`, `user-activity` (sink)
- **Avro Schemas (5)**: Registered in Schema Registry for all topics
- **Datagen Connectors (3)**: ~100 messages/second each with Avro serialization

### Flink Resources
- **Flink SQL Jobs (2)**:
  - `enriched-orders`: Temporal join of orders with user profiles + clickstream summary
  - `user-activity`: Windowed aggregation of user behavior across all streams
- **Compute Pool**: Dedicated `ecommerce-pool` with CMF autoscaling (1-5 TaskManagers, 70% utilization target)
- **Sample Queries**: Pre-configured inspection queries in `flink-sql-sample-queries` ConfigMap

## Prerequisites

The following must be deployed before this application:
- Confluent for Kubernetes (CFK) operator
- Confluent Manager for Apache Flink (CMF) operator
- Kafka cluster with Schema Registry and Connect
- S3proxy for object storage
- Flink Kubernetes Operator
- FlinkEnvironment `env1` (deployed by `flink-resources` workload)
- Kafka catalog and database (deployed by `cp-flink-sql-sandbox` workload)

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

### Running Sample Queries

```bash
# List available sample queries
kubectl get configmap flink-sql-sample-queries -n flink -o jsonpath='{.data}' | jq -r 'keys[]'

# Get a specific query
kubectl get configmap flink-sql-sample-queries -n flink -o jsonpath='{.data.01-inspect-users\.sql}'

# Submit a query via CMF API
confluent flink statement create my-query \
  --sql "SELECT * FROM \`kafka-cat\`.\`main-kafka-cluster\`.\`users\` LIMIT 10;" \
  --compute-pool ecommerce-pool \
  --environment env1 \
  --database main-kafka-cluster \
  --catalog kafka-cat \
  --url http://cmf.flink-demo.confluentdemo.local
```

## Removing This Demo

To remove this demo without affecting other workloads:
1. Delete the ArgoCD Application `cp-flink-ecommerce-demo`
2. The `ecommerce-pool` compute pool, topics, schemas, and connectors will be cleaned up
3. No other workloads are affected
