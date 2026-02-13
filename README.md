# Resilient Multi-Tenant API with Bulkhead Isolation

A production-style, multi-tenant REST API that uses the **bulkhead pattern** to isolate resources between different customer tiers (`free`, `pro`, `enterprise`). The system enforces per-tier rate limits, maintains independent circuit breakers, and provides real-time observability through a metrics endpoint.

---

## Table of Contents

- [Architecture](#architecture)
- [Design Choices](#design-choices)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Setup and Execution](#setup-and-execution)
- [API Endpoints](#api-endpoints)
- [Bulkhead Configuration](#bulkhead-configuration)
- [Environment Variables](#environment-variables)
- [Testing the Circuit Breaker](#testing-the-circuit-breaker)
- [Running the Load Test](#running-the-load-test)
- [How It Works](#how-it-works)

---

## Architecture

```
                  ┌─────────────────────────────────────────────────────────────────┐
                  │                         API Service                             │
                  │                                                                 │
  HTTP Request    │  ┌──────────┐    ┌──────────────┐    ┌───────────────────────┐  │
  ─────────────►  │  │  Tenant  │───►│ Rate Limiter │───►│    Bulkhead Router    │  │
  X-Tenant-Tier   │  │  Parser  │    │  (per tier)  │    │                       │  │
                  │  └──────────┘    └──────────────┘    │  ┌─────────────────┐  │  │
                  │                                      │  │  FREE Bulkhead  │  │  │
                  │                                      │  │  Workers: 10    │  │  │
                  │                                      │  │  DB Pool: 5     │──┼──┼──► PostgreSQL
                  │                                      │  │  Breaker        │  │  │
                  │                                      │  └─────────────────┘  │  │
                  │                                      │  ┌─────────────────┐  │  │
                  │                                      │  │  PRO Bulkhead   │  │  │
                  │                                      │  │  Workers: 30    │  │  │
                  │                                      │  │  DB Pool: 20    │──┼──┼──► PostgreSQL
                  │                                      │  │  Breaker        │  │  │
                  │                                      │  └─────────────────┘  │  │
                  │                                      │  ┌─────────────────┐  │  │
                  │                                      │  │ ENTERPRISE      │  │  │
                  │                                      │  │  Workers: 60    │  │  │
                  │                                      │  │  DB Pool: 50    │──┼──┼──► PostgreSQL
                  │                                      │  │  Breaker        │  │  │
                  │                                      │  └─────────────────┘  │  │
                  │                                      └───────────────────────┘  │
                  └─────────────────────────────────────────────────────────────────┘
```

Each tier is fully isolated: its own database connection pool, its own worker queue, its own circuit breaker, and its own rate limit window. A flood of `free`-tier traffic cannot consume `pro` or `enterprise` resources.

---

## Design Choices

### Why Node.js?

Node.js with Express provides a lightweight, single-process runtime that makes the bulkhead abstraction very explicit. Each tier gets a dedicated `pg.Pool` (connection pool) and `BulkheadQueue` (concurrency limiter), rather than relying on framework-managed thread pools that hide resource allocation.

### Bulkhead Implementation

Rather than using OS threads (which Node.js does not natively expose for request handling), the bulkhead is implemented as a **concurrency-limited task queue** per tier:

- **`BulkheadQueue`** — Limits how many database operations can run concurrently for a tier. When the pool is full, incoming requests queue up. This mirrors a bounded thread pool in Java/Go but uses JavaScript's event loop and Promises.
- **`pg.Pool`** — Each tier gets its own PostgreSQL connection pool with a hard `max` limit (`5`, `20`, `50`). The pools are completely independent; one tier exhausting its connections has zero effect on others.

### Circuit Breaker

A custom three-state circuit breaker (`CLOSED` → `OPEN` → `HALF_OPEN` → `CLOSED`) is attached to each tier's database path. After 5 consecutive failures, the breaker opens and immediately rejects requests for that tier with `503 Service Unavailable`, preventing the failing tier from consuming database resources. After a 15-second cooldown, the breaker transitions to `HALF_OPEN` and allows one probe request through to test recovery.

### Rate Limiting

A fixed-window rate limiter resets every 60 seconds. The `free` tier is capped at 100 requests per minute, `pro` at 1,000, and `enterprise` has no limit. Requests exceeding the limit receive `429 Too Many Requests`.

### No External Dependencies for Resilience

The circuit breaker, rate limiter, and bulkhead queue are implemented from scratch with zero external libraries. This keeps the Docker image small, avoids supply-chain risk, and makes the code fully transparent for review.

---

## Project Structure

```
.
├── .env.example           # Environment variable template
├── .dockerignore           # Files excluded from Docker build context
├── .gitignore              # Git ignore rules
├── Dockerfile              # API service container image
├── docker-compose.yml      # Service orchestration (api + db)
├── init-db.sql             # Database schema and seed data
├── load-test.sh            # Bash load-test script
├── package.json            # Node.js dependencies
├── README.md               # This file
├── src/
│   ├── index.js            # Express API, routes, middleware
│   └── bulkhead.js         # BulkheadQueue, CircuitBreaker classes
└── tests/
    └── integration.test.sh # Integration test script
```

---

## Prerequisites

- **Docker Desktop** (or Docker Engine + Docker Compose v2)

No local Node.js installation is required; everything runs inside containers.

---

## Setup and Execution

### 1. Clone the repository

```bash
git clone <repository-url>
cd "Resilient Multi Tenant API with the Bulkhead Pattern"
```

### 2. Create the environment file

```bash
cp .env.example .env
```

The defaults in `.env.example` are ready to use — no changes needed.

### 3. Build and start the services

```bash
docker-compose up --build
```

Docker Compose will:
1. Start PostgreSQL and wait for it to be healthy (`pg_isready`).
2. Run `init-db.sql` to create the `tenant_data` table and seed it.
3. Build the API image and start it once the database is ready.
4. Both services register health checks; you can monitor with `docker-compose ps`.

### 4. Verify the stack is running

```bash
# Health check
curl http://localhost:8080/health
# Expected: {"status":"healthy"}

# Data endpoint (free tier)
curl -H "X-Tenant-Tier: free" http://localhost:8080/api/data
# Expected: [{"id":1,"tier":"free","payload":{"message":"Free tier data point 1"},...}]

# Metrics
curl http://localhost:8080/metrics/bulkheads
# Expected: JSON with free/pro/enterprise pool stats and circuit breaker states
```

### 5. Stop the services

```bash
docker-compose down
```

---

## API Endpoints

### `GET /health`

Returns the health status of the API.

**Response (200 OK):**
```json
{"status": "healthy"}
```

### `GET /api/data`

Returns data records for the tenant's tier.

**Required Header:** `X-Tenant-Tier` — one of `free`, `pro`, `enterprise`

**Response (200 OK):**
```json
[
  {
    "id": 1,
    "tier": "free",
    "payload": {"message": "Free tier data point 1"},
    "created_at": "2026-02-11T12:00:00.000Z"
  }
]
```

**Error Responses:**
| Status | Condition |
|--------|-----------|
| `400 Bad Request` | Missing or invalid `X-Tenant-Tier` header |
| `429 Too Many Requests` | Rate limit exceeded for the tier |
| `503 Service Unavailable` | Circuit breaker is open or database failure |

**Query Parameters:**
- `?force_error=true` — Simulate a database failure for circuit breaker testing.

### `GET /metrics/bulkheads`

Returns real-time metrics for all tier bulkheads.

**Response (200 OK):**
```json
{
  "free": {
    "connectionPool": {"active": 0, "idle": 1, "pending": 0, "max": 5},
    "threadPool": {"active": 0, "queued": 0, "poolSize": 10},
    "circuitBreaker": {"state": "CLOSED", "failures": 0}
  },
  "pro": {
    "connectionPool": {"active": 0, "idle": 1, "pending": 0, "max": 20},
    "threadPool": {"active": 0, "queued": 0, "poolSize": 30},
    "circuitBreaker": {"state": "CLOSED", "failures": 0}
  },
  "enterprise": {
    "connectionPool": {"active": 0, "idle": 1, "pending": 0, "max": 50},
    "threadPool": {"active": 0, "queued": 0, "poolSize": 60},
    "circuitBreaker": {"state": "CLOSED", "failures": 0}
  }
}
```

---

## Bulkhead Configuration

| Tier | DB Connection Pool Max | Worker Pool Size | Rate Limit | Circuit Breaker Threshold |
|------|------------------------|------------------|------------|--------------------------|
| free | 5 | 10 | 100 req/min | 5 consecutive failures |
| pro | 20 | 30 | 1,000 req/min | 5 consecutive failures |
| enterprise | 50 | 60 | Unlimited | 5 consecutive failures |

---

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `API_PORT` | Port the API listens on | `8080` |
| `DATABASE_URL` | PostgreSQL connection string | `postgresql://user:password@db:5432/tenantdb` |

All variables are documented in `.env.example`.

---

## Testing the Circuit Breaker

You can trip a tier's circuit breaker without taking down the database:

```bash
# Send 5+ forced errors to open the free tier breaker
for i in $(seq 1 6); do
  curl -s -w "%{http_code}\n" -o /dev/null \
    -H "X-Tenant-Tier: free" \
    "http://localhost:8080/api/data?force_error=true"
done

# Check that the free breaker is OPEN while others remain CLOSED
curl -s http://localhost:8080/metrics/bulkheads | python3 -m json.tool

# Verify pro tier is unaffected
curl -H "X-Tenant-Tier: pro" http://localhost:8080/api/data
```

The breaker auto-recovers after 15 seconds (transitions to `HALF_OPEN`, then `CLOSED` on a successful request).

---

## Running the Load Test

The `load-test.sh` script generates heavy concurrent traffic on the `free` tier while sending a low, steady stream to `pro` and `enterprise`. This demonstrates that the bulkhead pattern keeps premium tiers responsive under free-tier overload.

```bash
chmod +x load-test.sh
./load-test.sh
```

**What to expect:**
- **Free tier**: Most requests beyond the first 100 will return `429 Too Many Requests`.
- **Pro tier**: All requests succeed with `200 OK` and low latency.
- **Enterprise tier**: All requests succeed with `200 OK` and low latency.

The script outputs a summary table at the end showing success/failure counts per tier.

While the load test runs, you can monitor the bulkhead state in a separate terminal:

```bash
watch -n1 'curl -s http://localhost:8080/metrics/bulkheads | python3 -m json.tool'
```

---

## How It Works

### Request Flow

1. **Tenant identification**: The `X-Tenant-Tier` header is parsed and validated. Invalid or missing headers return `400`.
2. **Rate limiting**: The request is checked against the tier's rate limit window. Excess requests return `429`.
3. **Bulkhead queue**: The request enters the tier's worker queue. If all workers are busy, it waits in the queue.
4. **Circuit breaker**: The breaker checks whether the tier's database path is healthy. If the breaker is `OPEN`, the request is rejected immediately with `503`.
5. **Database query**: The request executes against the tier's dedicated connection pool.
6. **Response**: Results are returned as JSON, or appropriate error codes are sent.

### Failure Isolation

- If the `free` tier exhausts its 5 database connections, `pro` and `enterprise` pools are unaffected.
- If the `free` tier's circuit breaker opens after repeated failures, only `free` requests are fast-failed; other tiers continue normally.
- If `free` tier traffic spikes far beyond its rate limit, excess requests are rejected at step 2, never reaching the database at all.

---

## License

This project is provided for educational purposes.
