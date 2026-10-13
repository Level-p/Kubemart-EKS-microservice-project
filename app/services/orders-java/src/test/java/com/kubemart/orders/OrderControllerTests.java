package com.kubemart.orders;

import com.kubemart.orders.Models.CreateOrderRequest;
import com.kubemart.orders.Models.Order;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.micrometer.metrics.test.autoconfigure.AutoConfigureMetrics;
import org.springframework.boot.resttestclient.TestRestTemplate;
import org.springframework.boot.resttestclient.autoconfigure.AutoConfigureTestRestTemplate;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.content;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ActiveProfiles("test")
@AutoConfigureMetrics // tests switch metrics exporters off by default
@AutoConfigureTestRestTemplate
class OrderControllerTests {

    private static final String CART = "http://cart";
    private static final String CATALOG = "http://catalog";
    private static final String PAYMENT = "http://payment";

    @Autowired
    private TestRestTemplate rest;

    @Autowired
    private OrderRepository repository;

    private MockRestServiceServer downstream;
    private OrderController controller;

    @BeforeEach
    void setUp() {
        // A controller whose cart, catalog and payment calls go to a fake server
        RestClient.Builder builder = RestClient.builder();
        downstream = MockRestServiceServer.bindTo(builder).build();
        controller = new OrderController(builder, repository, new SimpleMeterRegistry(), CART, CATALOG, PAYMENT);
    }

    private void cartWith(String user, String json) {
        downstream.expect(requestTo(CART + "/cart/" + user)).andExpect(method(HttpMethod.GET))
                .andRespond(withSuccess(json, MediaType.APPLICATION_JSON));
    }

    private void reserve(String id, int qty, long price) {
        downstream.expect(requestTo(CATALOG + "/products/" + id + "/reserve")).andExpect(method(HttpMethod.POST))
                .andExpect(content().json("{\"quantity\":" + qty + "}"))
                .andRespond(withSuccess("{\"id\":\"" + id + "\",\"name\":\"Item " + id + "\",\"priceCents\":" + price
                        + ",\"currency\":\"GBP\",\"stock\":5}", MediaType.APPLICATION_JSON));
    }

    private void release(String id, int qty) {
        downstream.expect(requestTo(CATALOG + "/products/" + id + "/release"))
                .andExpect(content().json("{\"quantity\":" + qty + "}"))
                .andRespond(withSuccess("{}", MediaType.APPLICATION_JSON));
    }

    private void payment(String status) {
        downstream.expect(requestTo(PAYMENT + "/payments")).andExpect(method(HttpMethod.POST))
                .andRespond(withSuccess("{\"paymentId\":\"pay-1\",\"orderId\":\"x\",\"status\":\"" + status + "\"}",
                        MediaType.APPLICATION_JSON));
    }

    @Test
    void paidOrderIsStoredAndCartCleared() {
        cartWith("alice", "{\"userId\":\"alice\",\"items\":[{\"productId\":\"p-1\",\"quantity\":2},{\"productId\":\"p-2\",\"quantity\":1}],\"totalItems\":3}");
        reserve("p-1", 2, 1000);
        reserve("p-2", 1, 500);
        payment("approved");
        downstream.expect(requestTo(CART + "/cart/alice")).andExpect(method(HttpMethod.DELETE))
                .andRespond(withStatus(HttpStatus.NO_CONTENT));

        ResponseEntity<?> response = controller.createOrder(new CreateOrderRequest("alice"));

        downstream.verify();
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        Order order = (Order) response.getBody();
        assertThat(order.totalCents()).isEqualTo(2500);
        Order stored = repository.findById(order.id()).orElseThrow();
        assertThat(stored.status()).isEqualTo("CONFIRMED");
        assertThat(stored.items()).hasSize(2);
        assertThat(stored.items().get(0).lineTotalCents()).isEqualTo(2000);
    }

    @Test
    void declinedPaymentPutsStockBack() {
        cartWith("bob", "{\"userId\":\"bob\",\"items\":[{\"productId\":\"p-3\",\"quantity\":1}],\"totalItems\":1}");
        reserve("p-3", 1, 90000);
        payment("declined");
        release("p-3", 1);

        ResponseEntity<?> response = controller.createOrder(new CreateOrderRequest("bob"));

        downstream.verify();
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.PAYMENT_REQUIRED);
        assertThat(repository.findRecent("bob", 10)).extracting(Order::status).containsExactly("PAYMENT_DECLINED");
    }

    @Test
    void soldOutItemReleasesEarlierReservations() {
        cartWith("carol", "{\"userId\":\"carol\",\"items\":[{\"productId\":\"p-1\",\"quantity\":1},{\"productId\":\"p-9\",\"quantity\":5}],\"totalItems\":6}");
        reserve("p-1", 1, 1000);
        downstream.expect(requestTo(CATALOG + "/products/p-9/reserve"))
                .andRespond(withStatus(HttpStatus.CONFLICT).body("{\"error\":\"not enough stock\"}")
                        .contentType(MediaType.APPLICATION_JSON));
        release("p-1", 1);

        ResponseEntity<?> response = controller.createOrder(new CreateOrderRequest("carol"));

        downstream.verify();
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.CONFLICT);
        assertThat(((Map<?, ?>) response.getBody()).get("productId")).isEqualTo("p-9");
        assertThat(repository.findRecent("carol", 10)).isEmpty();
    }

    @Test
    void databaseDownMeansNobodyIsCharged() {
        OrderRepository broken = new OrderRepository(null) {
            @Override
            public void save(Order order) {
                // What Spring really throws when no connection can be opened for the transaction
                throw new org.springframework.transaction.CannotCreateTransactionException("database is down");
            }
        };
        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        OrderController offline = new OrderController(builder, broken, new SimpleMeterRegistry(), CART, CATALOG, PAYMENT);
        server.expect(requestTo(CART + "/cart/dave")).andRespond(withSuccess(
                "{\"userId\":\"dave\",\"items\":[{\"productId\":\"p-1\",\"quantity\":1}],\"totalItems\":1}",
                MediaType.APPLICATION_JSON));
        server.expect(requestTo(CATALOG + "/products/p-1/reserve")).andRespond(withSuccess(
                "{\"id\":\"p-1\",\"name\":\"Mug\",\"priceCents\":1200,\"currency\":\"GBP\",\"stock\":5}",
                MediaType.APPLICATION_JSON));
        // No payment call is expected: only the stock release
        server.expect(requestTo(CATALOG + "/products/p-1/release")).andRespond(withSuccess());

        ResponseEntity<?> response = offline.createOrder(new CreateOrderRequest("dave"));

        server.verify();
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
    }

    @Test
    void healthEndpointReturnsOk() {
        ResponseEntity<Map> response = rest.getForEntity("/health", Map.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).containsEntry("service", "orders");
    }

    @Test
    void missingUserIdIsRejected() {
        ResponseEntity<Map> response = rest.postForEntity("/orders", Map.of(), Map.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
    }

    @Test
    void unknownOrderReturns404() {
        ResponseEntity<String> response = rest.getForEntity("/orders/does-not-exist", String.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
    }

    @Test
    void prometheusEndpointIsExposed() {
        ResponseEntity<String> response = rest.getForEntity("/actuator/prometheus", String.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).contains("jvm_memory_used_bytes");
    }
}
