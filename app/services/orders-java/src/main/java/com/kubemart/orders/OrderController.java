package com.kubemart.orders;

import com.kubemart.orders.Models.Cart;
import com.kubemart.orders.Models.CartItem;
import com.kubemart.orders.Models.CreateOrderRequest;
import com.kubemart.orders.Models.Order;
import com.kubemart.orders.Models.OrderItem;
import com.kubemart.orders.Models.PaymentRequest;
import com.kubemart.orders.Models.PaymentResponse;
import com.kubemart.orders.Models.Product;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataAccessException;
import org.springframework.transaction.TransactionException;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Checkout:
 *   1. read the cart (Rust)
 *   2. reserve every item in the catalog (Go): stock goes down, or 409 if sold out
 *   3. store the order in PostgreSQL as PENDING_PAYMENT (database down: stop, nobody is charged)
 *   4. charge the payment service (Python)
 *   5. paid: empty the cart. Not paid (or payment down): put the stock back
 *   6. store the result (CONFIRMED, PAYMENT_DECLINED or PAYMENT_FAILED)
 */
@RestController
public class OrderController {

    private static final Logger log = LoggerFactory.getLogger(OrderController.class);

    private final RestClient cartClient;
    private final RestClient catalogClient;
    private final RestClient paymentClient;
    private final OrderRepository repository;
    private final MeterRegistry meters;
    private final Counter revenue;

    public OrderController(RestClient.Builder builder,
                           OrderRepository repository,
                           MeterRegistry meters,
                           @Value("${services.cart-url}") String cartUrl,
                           @Value("${services.catalog-url}") String catalogUrl,
                           @Value("${services.payment-url}") String paymentUrl) {
        this.cartClient = builder.clone().baseUrl(cartUrl).build();
        this.catalogClient = builder.clone().baseUrl(catalogUrl).build();
        this.paymentClient = builder.clone().baseUrl(paymentUrl).build();
        this.repository = repository;
        this.meters = meters;
        // Prometheus: kubemart_order_revenue_cents_total
        this.revenue = Counter.builder("kubemart.order.revenue.cents")
                .description("Value of confirmed orders, in cents")
                .register(meters);
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "ok", "service", "orders");
    }

    @PostMapping("/orders")
    public ResponseEntity<?> createOrder(@RequestBody CreateOrderRequest request) {
        if (request == null || request.userId() == null || request.userId().isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "userId is required"));
        }
        String userId = request.userId();

        // 1. Read the cart (Rust service)
        Cart cart = cartClient.get().uri("/cart/{userId}", userId).retrieve().body(Cart.class);
        if (cart == null || cart.items() == null || cart.items().isEmpty()) {
            return ResponseEntity.badRequest().body(Map.of("error", "cart is empty"));
        }

        // 2. Reserve stock and take the current price from the catalog (Go service)
        List<OrderItem> items = new ArrayList<>();
        long total = 0;
        String currency = "GBP";
        try {
            for (CartItem cartItem : cart.items()) {
                Product product = catalogClient.post()
                        .uri("/products/{id}/reserve", cartItem.productId())
                        .contentType(MediaType.APPLICATION_JSON)
                        .body(Map.of("quantity", cartItem.quantity()))
                        .retrieve()
                        .body(Product.class);
                long lineTotal = product.priceCents() * cartItem.quantity();
                total += lineTotal;
                currency = product.currency();
                items.add(new OrderItem(product.id(), product.name(), cartItem.quantity(), product.priceCents(), lineTotal));
            }
        } catch (HttpClientErrorException.Conflict | HttpClientErrorException.NotFound ex) {
            releaseStock(items);
            String productId = cart.items().get(items.size()).productId();
            count(ex instanceof HttpClientErrorException.Conflict ? "OUT_OF_STOCK" : "UNKNOWN_PRODUCT");
            return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of(
                    "error", ex instanceof HttpClientErrorException.Conflict ? "not enough stock" : "unknown product",
                    "productId", productId));
        } catch (RestClientException ex) {
            releaseStock(items);
            throw ex;
        }

        // 3. Record the order BEFORE charging: if the database is down, nobody is charged.
        String orderId = "ord-" + UUID.randomUUID().toString().replace("-", "").substring(0, 12);
        Instant createdAt = Instant.now();
        try {
            repository.save(new Order(orderId, userId, items, total, currency, "PENDING_PAYMENT", null, createdAt));
        } catch (DataAccessException | TransactionException ex) {
            // TransactionException: no connection could be opened for the transaction
            releaseStock(items);
            log.error("order database unavailable, nothing charged userId={}: {}", userId, ex.getMessage());
            count("DATABASE_ERROR");
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                    .body(Map.of("error", "orders are temporarily unavailable, you have not been charged"));
        }

        // 4. Charge the payment service (Python service)
        PaymentResponse payment;
        try {
            payment = paymentClient.post()
                    .uri("/payments")
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(new PaymentRequest(orderId, userId, total, currency))
                    .retrieve()
                    .body(PaymentResponse.class);
        } catch (RestClientException ex) {
            releaseStock(items);
            updateStatus(orderId, "PAYMENT_FAILED", null);
            throw ex;
        }
        boolean approved = payment != null && "approved".equalsIgnoreCase(payment.status());
        String status = approved ? "CONFIRMED" : "PAYMENT_DECLINED";
        String paymentId = payment != null ? payment.paymentId() : null;

        // 5. Paid: empty the cart. Declined: the items go back on sale.
        if (approved) {
            try {
                cartClient.delete().uri("/cart/{userId}", userId).retrieve().toBodilessEntity();
            } catch (RestClientException ex) {
                // The order is paid: a cart that was not emptied must not fail it
                log.warn("order paid but cart not cleared orderId={} userId={}: {}", orderId, userId, ex.getMessage());
            }
        } else {
            releaseStock(items);
        }

        // 6. Record the result. The payment is stored by the payment service under
        //    this order id, so an order left PENDING_PAYMENT can always be reconciled.
        updateStatus(orderId, status, paymentId);
        Order order = new Order(orderId, userId, items, total, currency, status, paymentId, createdAt);
        count(status);
        if (approved) {
            revenue.increment(total);
        }
        log.info("order processed orderId={} userId={} status={} totalCents={}", orderId, userId, status, total);

        return ResponseEntity.status(approved ? HttpStatus.CREATED : HttpStatus.PAYMENT_REQUIRED).body(order);
    }

    @GetMapping("/orders")
    public List<Order> listOrders(@RequestParam(required = false) String userId) {
        return repository.findRecent(userId, 50);
    }

    @GetMapping("/orders/{id}")
    public ResponseEntity<Order> getOrder(@PathVariable String id) {
        return repository.findById(id).map(ResponseEntity::ok).orElse(ResponseEntity.notFound().build());
    }

    private void updateStatus(String orderId, String status, String paymentId) {
        try {
            repository.updateStatus(orderId, status, paymentId);
        } catch (DataAccessException | TransactionException ex) {
            // TransactionException: no connection could be opened for the transaction
            // The customer's result is already decided; the order stays PENDING_PAYMENT
            // and the payment service's record is the source of truth for reconciliation.
            log.error("order status not saved, reconcile orderId={} status={} paymentId={}: {}",
                    orderId, status, paymentId, ex.getMessage());
        }
    }

    /** Puts reserved items back. Best effort: a failure is logged for follow-up, never hidden. */
    private void releaseStock(List<OrderItem> items) {
        for (OrderItem item : items) {
            try {
                catalogClient.post()
                        .uri("/products/{id}/release", item.productId())
                        .contentType(MediaType.APPLICATION_JSON)
                        .body(Map.of("quantity", item.quantity()))
                        .retrieve()
                        .toBodilessEntity();
            } catch (RestClientException ex) {
                log.error("stock release failed productId={} quantity={}: {}", item.productId(), item.quantity(), ex.getMessage());
            }
        }
    }

    /** Prometheus: kubemart_orders_total{status="CONFIRMED|PAYMENT_DECLINED|OUT_OF_STOCK|..."} */
    private void count(String status) {
        meters.counter("kubemart.orders", "status", status).increment();
    }

    /** A downstream service is down or returned an error. */
    @ExceptionHandler(RestClientException.class)
    public ResponseEntity<Map<String, String>> downstreamError(RestClientException ex) {
        log.error("downstream call failed: {}", ex.getMessage());
        count("DOWNSTREAM_ERROR");
        return ResponseEntity.status(HttpStatus.BAD_GATEWAY)
                .body(Map.of("error", "a downstream service is unavailable", "detail", String.valueOf(ex.getMessage())));
    }
}
