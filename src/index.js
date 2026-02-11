const express = require("express");
const { Pool } = require("pg");
const {
  BulkheadQueue,
  CircuitBreaker,
  CircuitOpenError
} = require("./bulkhead");

const API_PORT = Number.parseInt(process.env.API_PORT || "8080", 10);
const DATABASE_URL = process.env.DATABASE_URL;

if (!DATABASE_URL) {
  console.error("DATABASE_URL is required");
  process.exit(1);
}

const TIERS = ["free", "pro", "enterprise"];
const TIER_CONFIG = {
  free: { poolMax: 5, workerSize: 10, rateLimit: 100 },
  pro: { poolMax: 20, workerSize: 30, rateLimit: 1000 },
  enterprise: { poolMax: 50, workerSize: 60, rateLimit: null }
};

const resources = {};
const rateState = new Map();

for (const tier of TIERS) {
  const config = TIER_CONFIG[tier];
  resources[tier] = {
    pool: new Pool({
      connectionString: DATABASE_URL,
      max: config.poolMax,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000
    }),
    bulkhead: new BulkheadQueue(config.workerSize),
    circuitBreaker: new CircuitBreaker({
      failureThreshold: 5,
      resetTimeoutMs: 15000
    })
  };

  rateState.set(tier, { windowStart: 0, count: 0 });
}

const app = express();

function getTier(req) {
  const headerValue = req.header("X-Tenant-Tier");
  if (!headerValue) {
    return null;
  }

  const tier = headerValue.toLowerCase();
  if (!TIERS.includes(tier)) {
    return null;
  }

  return tier;
}

function checkRateLimit(tier) {
  const limit = TIER_CONFIG[tier].rateLimit;
  if (!limit) {
    return { allowed: true };
  }

  const state = rateState.get(tier);
  const now = Date.now();
  if (now - state.windowStart >= 60000) {
    state.windowStart = now;
    state.count = 0;
  }

  if (state.count >= limit) {
    return { allowed: false, limit };
  }

  state.count += 1;
  return { allowed: true, limit };
}

app.get("/health", (req, res) => {
  res.status(200).json({ status: "healthy" });
});

app.get("/api/data", async (req, res) => {
  const tier = getTier(req);
  if (!tier) {
    res.status(400).json({ error: "Missing or invalid X-Tenant-Tier header" });
    return;
  }

  const rateResult = checkRateLimit(tier);
  if (!rateResult.allowed) {
    res.status(429).json({
      error: "Rate limit exceeded",
      limit: rateResult.limit
    });
    return;
  }

  const forceError = req.query.force_error === "true";
  const tierResources = resources[tier];

  try {
    const rows = await tierResources.bulkhead.run(() =>
      tierResources.circuitBreaker.execute(async () => {
        if (forceError) {
          throw new Error("Forced error for circuit breaker testing");
        }

        const result = await tierResources.pool.query(
          "SELECT id, tier, payload, created_at FROM tenant_data WHERE tier = $1 ORDER BY id",
          [tier]
        );

        return result.rows;
      })
    );

    res.status(200).json(rows);
  } catch (err) {
    if (err instanceof CircuitOpenError) {
      res.status(503).json({ error: "Circuit breaker open" });
      return;
    }

    res.status(503).json({ error: "Service unavailable" });
  }
});

app.get("/metrics/bulkheads", (req, res) => {
  const payload = {};

  for (const tier of TIERS) {
    const tierResources = resources[tier];
    const pool = tierResources.pool;

    const total = pool.totalCount || 0;
    const idle = pool.idleCount || 0;
    const pending = pool.waitingCount || 0;
    const active = Math.max(total - idle, 0);

    payload[tier] = {
      connectionPool: {
        active,
        idle,
        pending,
        max: pool.options.max
      },
      threadPool: tierResources.bulkhead.getMetrics(),
      circuitBreaker: tierResources.circuitBreaker.getMetrics()
    };
  }

  res.status(200).json(payload);
});

const server = app.listen(API_PORT, () => {
  console.log(`API listening on port ${API_PORT}`);
});

async function shutdown() {
  server.close();
  await Promise.all(
    Object.values(resources).map((resource) => resource.pool.end())
  );
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
