package com.kubemart.orders;

import java.time.Instant;
import java.util.List;

/** JSON contracts used by the orders service. Unknown JSON fields are ignored by Spring Boot. */
public final class Models {

    private Models() {
    }

    // ---- API of this service ----
    public record CreateOrderRequest(String userId) {
    }

    public record OrderItem(String productId, String name, int quantity, long unitPriceCents, long lineTotalCents) {
    }

    public record Order(String id, String userId, List<OrderItem> items, long totalCents, String currency,
                        String status, String paymentId, Instant createdAt) {
    }

    // ---- Downstream services ----
    /** Cart service (Rust) */
    public record CartItem(String productId, int quantity) {
    }

    public record Cart(String userId, List<CartItem> items, int totalItems) {
    }

    /** Product catalog service (Go) */
    public record Product(String id, String name, long priceCents, String currency, int stock) {
    }

    /** Payment service (Python) */
    public record PaymentRequest(String orderId, String userId, long amountCents, String currency) {
    }

    public record PaymentResponse(String paymentId, String orderId, String status, String reason) {
    }
}
