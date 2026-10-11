# ---- Build ----
FROM rust:1.99-slim-bookworm AS build
WORKDIR /src

# Cache dependencies: build once with a dummy main.rs
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs \
 && cargo build --release --locked \
 && rm -rf src

COPY src ./src
# Touch main.rs so cargo rebuilds the real code, not the cached dummy.
# Unit tests run here; the Valkey integration test skips itself (no TEST_VALKEY_ADDR).
RUN touch src/main.rs \
 && cargo test --release --locked \
 && cargo build --release --locked

# ---- Run ----
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/cart /cart
ENV PORT=8080
EXPOSE 8080
# Numeric "nonroot" user so Kubernetes runAsNonRoot can verify it
USER 65532:65532
ENTRYPOINT ["/cart"]
