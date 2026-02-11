class CircuitOpenError extends Error {
  constructor(message) {
    super(message);
    this.name = "CircuitOpenError";
  }
}

class CircuitBreaker {
  constructor(options) {
    const opts = options || {};
    this.failureThreshold = opts.failureThreshold || 5;
    this.resetTimeoutMs = opts.resetTimeoutMs || 15000;
    this.state = "CLOSED";
    this.failures = 0;
    this.nextAttempt = 0;
    this.halfOpenInFlight = false;
  }

  _transitionToOpen() {
    this.state = "OPEN";
    this.nextAttempt = Date.now() + this.resetTimeoutMs;
  }

  _transitionToHalfOpen() {
    this.state = "HALF_OPEN";
    this.halfOpenInFlight = false;
  }

  _transitionToClosed() {
    this.state = "CLOSED";
    this.failures = 0;
    this.halfOpenInFlight = false;
  }

  _canAttempt() {
    if (this.state === "OPEN") {
      if (Date.now() >= this.nextAttempt) {
        this._transitionToHalfOpen();
        return true;
      }
      return false;
    }

    if (this.state === "HALF_OPEN") {
      return !this.halfOpenInFlight;
    }

    return true;
  }

  async execute(fn) {
    if (!this._canAttempt()) {
      throw new CircuitOpenError("Circuit breaker is open");
    }

    if (this.state === "HALF_OPEN") {
      this.halfOpenInFlight = true;
    }

    try {
      const result = await fn();
      this._transitionToClosed();
      return result;
    } catch (err) {
      this.failures = Math.min(this.failures + 1, this.failureThreshold);
      if (this.state === "HALF_OPEN" || this.failures >= this.failureThreshold) {
        this._transitionToOpen();
      }
      throw err;
    } finally {
      if (this.state === "HALF_OPEN") {
        this.halfOpenInFlight = false;
      }
    }
  }

  getMetrics() {
    return {
      state: this.state,
      failures: this.failures
    };
  }
}

class BulkheadQueue {
  constructor(poolSize) {
    this.poolSize = poolSize;
    this.active = 0;
    this.queue = [];
  }

  run(task) {
    return new Promise((resolve, reject) => {
      const runTask = () => {
        this.active += 1;
        Promise.resolve()
          .then(task)
          .then(resolve)
          .catch(reject)
          .finally(() => {
            this.active -= 1;
            this._dequeue();
          });
      };

      if (this.active < this.poolSize) {
        runTask();
      } else {
        this.queue.push(runTask);
      }
    });
  }

  _dequeue() {
    if (this.queue.length === 0) {
      return;
    }

    if (this.active >= this.poolSize) {
      return;
    }

    const next = this.queue.shift();
    next();
  }

  getMetrics() {
    return {
      active: this.active,
      queued: this.queue.length,
      poolSize: this.poolSize
    };
  }
}

module.exports = {
  BulkheadQueue,
  CircuitBreaker,
  CircuitOpenError
};
