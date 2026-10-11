package com.kubemart.orders;

import com.kubemart.orders.Models.Order;
import com.kubemart.orders.Models.OrderItem;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/** Stores orders in PostgreSQL (tables created by Flyway, see db/migration). */
@Repository
public class OrderRepository {

    private final JdbcClient jdbc;

    public OrderRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** The order and all its items are written together, or not at all. */
    @Transactional
    public void save(Order order) {
        jdbc.sql("""
                INSERT INTO orders (id, user_id, total_cents, currency, status, payment_id, created_at)
                VALUES (:id, :userId, :total, :currency, :status, :paymentId, :createdAt)""")
                .param("id", order.id())
                .param("userId", order.userId())
                .param("total", order.totalCents())
                .param("currency", order.currency())
                .param("status", order.status())
                .param("paymentId", order.paymentId())
                .param("createdAt", Timestamp.from(order.createdAt()))
                .update();
        int position = 0;
        for (OrderItem item : order.items()) {
            jdbc.sql("""
                    INSERT INTO order_items (order_id, position, product_id, name, quantity, unit_price_cents, line_total_cents)
                    VALUES (:orderId, :position, :productId, :name, :quantity, :unit, :line)""")
                    .param("orderId", order.id())
                    .param("position", position++)
                    .param("productId", item.productId())
                    .param("name", item.name())
                    .param("quantity", item.quantity())
                    .param("unit", item.unitPriceCents())
                    .param("line", item.lineTotalCents())
                    .update();
        }
    }

    public void updateStatus(String id, String status, String paymentId) {
        jdbc.sql("UPDATE orders SET status = :status, payment_id = :paymentId WHERE id = :id")
                .param("status", status)
                .param("paymentId", paymentId)
                .param("id", id)
                .update();
    }

    public Optional<Order> findById(String id) {
        List<Order> found = load("WHERE id = :value", id, 1);
        return found.stream().findFirst();
    }

    /** Newest first. userId may be null for all users. */
    public List<Order> findRecent(String userId, int limit) {
        return userId == null ? load("", null, limit) : load("WHERE user_id = :value", userId, limit);
    }

    private List<Order> load(String where, String value, int limit) {
        var query = jdbc.sql("SELECT id, user_id, total_cents, currency, status, payment_id, created_at FROM orders "
                + where + " ORDER BY created_at DESC LIMIT :limit").param("limit", limit);
        if (value != null) {
            query = query.param("value", value);
        }
        Map<String, Header> headers = new LinkedHashMap<>();
        query.query((rs, n) -> new Header(rs.getString("id"), rs.getString("user_id"), rs.getLong("total_cents"),
                        rs.getString("currency"), rs.getString("status"), rs.getString("payment_id"),
                        rs.getTimestamp("created_at")))
                .list()
                .forEach(h -> headers.put(h.id(), h));
        if (headers.isEmpty()) {
            return List.of();
        }

        Map<String, List<OrderItem>> items = new LinkedHashMap<>();
        jdbc.sql("""
                SELECT order_id, product_id, name, quantity, unit_price_cents, line_total_cents
                FROM order_items WHERE order_id IN (:ids) ORDER BY order_id, position""")
                .param("ids", new ArrayList<>(headers.keySet()))
                .query((rs, n) -> Map.entry(rs.getString("order_id"), new OrderItem(rs.getString("product_id"),
                        rs.getString("name"), rs.getInt("quantity"), rs.getLong("unit_price_cents"),
                        rs.getLong("line_total_cents"))))
                .list()
                .forEach(e -> items.computeIfAbsent(e.getKey(), k -> new ArrayList<>()).add(e.getValue()));

        return headers.values().stream()
                .map(h -> new Order(h.id(), h.userId(), items.getOrDefault(h.id(), List.of()), h.total(),
                        h.currency(), h.status(), h.paymentId(), h.createdAt().toInstant()))
                .toList();
    }

    private record Header(String id, String userId, long total, String currency, String status, String paymentId,
                          Timestamp createdAt) {
    }
}
