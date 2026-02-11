# Resilient Multi-Tenant API with Bulkhead Isolation

This project implements a multi-tenant REST API that isolates resources by tenant tier using separate connection pools, worker queues, rate limits, and circuit breakers. It is packaged for Docker Compose to demonstrate bulkhead isolation under load.

## Architecture overview

- **Tenant isolation:** Separate PostgreSQL connection pools and worker queues for `free`, `pro`, and `enterprise` tiers.
- **Bulkhead pattern:** Each tier has its own pool sizes and concurrency limits to avoid cross-tier saturation.
- **Rate limits:** `free` is capped at 100 RPM, `pro` at 1000 RPM, and `enterprise` is unlimited.
- **Circuit breakers:** Each tier has an independent breaker that opens after 5 consecutive failures. Use `?force_error=true` to trip a tier breaker.
- **Metrics:** `/metrics/bulkheads` provides real-time visibility into pool utilization and breaker state.

## Requirements

- Docker Desktop (or Docker Engine)

## Quick start

1. Copy `.env.example` to `.env` and adjust if needed.
2. Build and start the stack:

```bash
docker-compose up --build
```

3. Validate endpoints:

```bash
curl http://localhost:8080/health
curl -H "X-Tenant-Tier: free" http://localhost:8080/api/data
curl http://localhost:8080/metrics/bulkheads
```

## Bulkhead configuration

| Tier | DB pool max | Worker pool size | Rate limit |
| --- | --- | --- | --- |
| free | 5 | 10 | 100 RPM |
| pro | 20 | 30 | 1000 RPM |
| enterprise | 50 | 60 | unlimited |

## Circuit breaker testing

Trip the breaker for a tier by forcing errors:

```bash
curl -H "X-Tenant-Tier: free" "http://localhost:8080/api/data?force_error=true"
```

After 5 consecutive failures, the tier breaker opens and returns 503 until the reset timeout elapses. Check breaker state at `/metrics/bulkheads`.

## Load test

Run the included script to generate heavy load on `free` while sending a steady stream to `pro` and `enterprise`:

```bash
chmod +x load-test.sh
./load-test.sh
```

The output will show that `pro` and `enterprise` stay responsive while `free` hits rate limits or higher latency. Use `/metrics/bulkheads` to confirm pool saturation on `free`.

## Endpoints

- `GET /health` - health check
- `GET /api/data` - data query (requires `X-Tenant-Tier`)
- `GET /metrics/bulkheads` - bulkhead metrics

## Notes

- `X-Tenant-Tier` must be `free`, `pro`, or `enterprise`.
- The database is initialized with seed data from `init-db.sql`.
