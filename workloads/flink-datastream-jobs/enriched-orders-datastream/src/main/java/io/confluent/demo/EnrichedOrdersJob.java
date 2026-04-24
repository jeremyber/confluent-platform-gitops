package io.confluent.demo;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.functions.JoinFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.api.java.functions.KeySelector;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.windowing.assigners.TumblingEventTimeWindows;
import org.apache.flink.streaming.api.windowing.time.Time;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;

public class EnrichedOrdersJob {
    private static final Logger LOG = LoggerFactory.getLogger(EnrichedOrdersJob.class);
    private static final ObjectMapper objectMapper = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        final StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(10000); // checkpoint every 10 seconds

        String kafkaBootstrap = System.getenv().getOrDefault("KAFKA_BOOTSTRAP", "kafka.kafka.svc.cluster.local:9071");

        // Source: users
        KafkaSource<String> usersSource = KafkaSource.<String>builder()
                .setBootstrapServers(kafkaBootstrap)
                .setTopics("users")
                .setGroupId("enriched-orders-users-consumer")
                .setStartingOffsets(OffsetsInitializer.earliest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<UserEvent> users = env
                .fromSource(usersSource, WatermarkStrategy
                        .<String>forBoundedOutOfOrderness(Duration.ofSeconds(5))
                        .withTimestampAssigner((event, timestamp) -> {
                            try {
                                JsonNode node = objectMapper.readTree(event);
                                return node.get("registered_at").asLong();
                            } catch (Exception e) {
                                LOG.error("Failed to parse user event", e);
                                return System.currentTimeMillis();
                            }
                        }), "Users Source")
                .map(json -> {
                    JsonNode node = objectMapper.readTree(json);
                    return new UserEvent(
                            node.get("user_id").asText(),
                            node.get("name").asText(),
                            node.get("email").asText(),
                            node.get("region").asText(),
                            node.get("registered_at").asLong()
                    );
                });

        // Source: orders
        KafkaSource<String> ordersSource = KafkaSource.<String>builder()
                .setBootstrapServers(kafkaBootstrap)
                .setTopics("orders")
                .setGroupId("enriched-orders-orders-consumer")
                .setStartingOffsets(OffsetsInitializer.earliest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<OrderEvent> orders = env
                .fromSource(ordersSource, WatermarkStrategy
                        .<String>forBoundedOutOfOrderness(Duration.ofSeconds(5))
                        .withTimestampAssigner((event, timestamp) -> {
                            try {
                                JsonNode node = objectMapper.readTree(event);
                                return node.get("order_time").asLong();
                            } catch (Exception e) {
                                LOG.error("Failed to parse order event", e);
                                return System.currentTimeMillis();
                            }
                        }), "Orders Source")
                .map(json -> {
                    JsonNode node = objectMapper.readTree(json);
                    return new OrderEvent(
                            node.get("order_id").asText(),
                            node.get("user_id").asText(),
                            node.get("product").asText(),
                            node.get("amount").asDouble(),
                            node.get("currency").asText(),
                            node.get("order_time").asLong()
                    );
                });

        // Join orders with users
        DataStream<String> enrichedOrders = orders
                .join(users)
                .where((KeySelector<OrderEvent, String>) OrderEvent::getUserId)
                .equalTo((KeySelector<UserEvent, String>) UserEvent::getUserId)
                .window(TumblingEventTimeWindows.of(Time.hours(1)))
                .apply((JoinFunction<OrderEvent, UserEvent, String>) (order, user) -> {
                    ObjectNode result = objectMapper.createObjectNode();
                    result.put("order_id", order.getOrderId());
                    result.put("user_id", order.getUserId());
                    result.put("product", order.getProduct());
                    result.put("amount", order.getAmount());
                    result.put("currency", order.getCurrency());
                    result.put("order_time", order.getOrderTime());
                    result.put("name", user.getName());
                    result.put("email", user.getEmail());
                    result.put("region", user.getRegion());
                    return result.toString();
                });

        // Sink: enriched-orders
        KafkaSink<String> sink = KafkaSink.<String>builder()
                .setBootstrapServers(kafkaBootstrap)
                .setRecordSerializer(KafkaRecordSerializationSchema.builder()
                        .setTopic("enriched-orders")
                        .setValueSerializationSchema(new SimpleStringSchema())
                        .build())
                .build();

        enrichedOrders.sinkTo(sink);

        env.execute("Enriched Orders DataStream Job");
    }

    // POJOs
    public static class UserEvent {
        private String userId;
        private String name;
        private String email;
        private String region;
        private long registeredAt;

        public UserEvent() {}

        public UserEvent(String userId, String name, String email, String region, long registeredAt) {
            this.userId = userId;
            this.name = name;
            this.email = email;
            this.region = region;
            this.registeredAt = registeredAt;
        }

        public String getUserId() { return userId; }
        public String getName() { return name; }
        public String getEmail() { return email; }
        public String getRegion() { return region; }
        public long getRegisteredAt() { return registeredAt; }
    }

    public static class OrderEvent {
        private String orderId;
        private String userId;
        private String product;
        private double amount;
        private String currency;
        private long orderTime;

        public OrderEvent() {}

        public OrderEvent(String orderId, String userId, String product, double amount, String currency, long orderTime) {
            this.orderId = orderId;
            this.userId = userId;
            this.product = product;
            this.amount = amount;
            this.currency = currency;
            this.orderTime = orderTime;
        }

        public String getOrderId() { return orderId; }
        public String getUserId() { return userId; }
        public String getProduct() { return product; }
        public double getAmount() { return amount; }
        public String getCurrency() { return currency; }
        public long getOrderTime() { return orderTime; }
    }
}
