package com.kubemart.orders;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * KubeMart orders service.
 * Turns a cart into an order: reads the cart (Rust), prices each item with the
 * product catalog (Go), charges the payment service (Python), then empties the cart.
 */
@SpringBootApplication
public class OrdersApplication {

    public static void main(String[] args) {
        SpringApplication.run(OrdersApplication.class, args);
    }
}
