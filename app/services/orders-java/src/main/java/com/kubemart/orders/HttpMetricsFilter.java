package com.kubemart.orders;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.servlet.HandlerMapping;

import java.io.IOException;
import java.time.Duration;

/**
 * Publishes the same HTTP metrics as the Go, Rust and Python services, so every
 * service looks alike in Grafana and the alert rules:
 *   http_requests_total{method, route, status}
 *   http_request_duration_seconds{method, route}  (histogram, same buckets)
 */
@Component
public class HttpMetricsFilter extends OncePerRequestFilter {

    private static final Duration[] BUCKETS = {
            Duration.ofMillis(5), Duration.ofMillis(10), Duration.ofMillis(25), Duration.ofMillis(50),
            Duration.ofMillis(100), Duration.ofMillis(250), Duration.ofMillis(500), Duration.ofSeconds(1),
            Duration.ofMillis(2500), Duration.ofSeconds(5)};

    private final MeterRegistry meters;

    public HttpMetricsFilter(MeterRegistry meters) {
        this.meters = meters;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        long start = System.nanoTime();
        try {
            chain.doFilter(request, response);
        } finally {
            // The route pattern (/orders/{id}), never the raw path, so the number of series stays small
            Object pattern = request.getAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE);
            String route = pattern != null ? pattern.toString() : "unmatched";
            String method = request.getMethod();
            Counter.builder("http.requests")
                    .description("HTTP requests by method, route and status code.")
                    .tags("method", method, "route", route, "status", Integer.toString(response.getStatus()))
                    .register(meters)
                    .increment();
            Timer.builder("http.request.duration")
                    .description("HTTP request duration by method and route.")
                    .tags("method", method, "route", route)
                    .serviceLevelObjectives(BUCKETS)
                    .register(meters)
                    .record(Duration.ofNanos(System.nanoTime() - start));
        }
    }
}
