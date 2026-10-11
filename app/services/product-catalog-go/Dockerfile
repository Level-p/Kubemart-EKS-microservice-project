# ---- Build: static Go binary ----
FROM golang:1.27-alpine AS build
WORKDIR /src
# Download modules first so this layer is cached until go.mod/go.sum change
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Unit tests run here; the PostgreSQL integration test skips itself (no TEST_DATABASE_URL)
RUN go test ./... \
 && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/product-catalog .

# ---- Run: distroless, non-root, no shell ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/product-catalog /product-catalog
ENV PORT=8080
EXPOSE 8080
# Numeric "nonroot" user so Kubernetes runAsNonRoot can verify it
USER 65532:65532
ENTRYPOINT ["/product-catalog"]
