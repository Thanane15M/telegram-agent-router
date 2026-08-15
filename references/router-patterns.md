# Router patterns — deterministic first, classifier second

The router decides *which bounded handler* receives work. It does not authorize arbitrary capabilities.

## Route order

A robust default order is:

1. callback prefix;
2. known command;
3. active session/flow lock;
4. unambiguous deterministic hint;
5. constrained classifier for ambiguity;
6. clarification or bounded fallback.

The executable fast path is in `../examples/router_contract.py`.

## Do not hard-code magic confidence thresholds

A confidence value from an LLM is not automatically calibrated. Choose clarification/direct-route thresholds from labeled eval data and observed routing errors, not generic constants copied from an example.

For a classifier result, validate:

- target ID is in the active registry;
- target is allowed for this bot/user/context;
- confidence is finite and inside expected bounds;
- output parses against a strict schema;
- low-confidence/high-impact cases do not trigger privileged actions.

## Constrained classifier shape

Prefer a closed target set and structured output:

```json
{
  "agent_id": "support",
  "confidence": 0.74,
  "reason_code": "billing_vs_support_ambiguous"
}
```

Do not require or store hidden chain-of-thought. A short reason code or externally useful rationale is sufficient for auditability.

## Fast path

Commands and callbacks should not pay LLM latency/cost.

```python
from examples.router_contract import route_fast_path

decision = route_fast_path(
    message,
    command_routes={"/invoice": "invoice"},
    callback_data=callback_data,
    callback_routes={"approve": "approvals"},
    locked_agent=session.locked_agent,
    keyword_routes={"support": ["error", "broken"]},
)

if decision.needs_classifier:
    # call the constrained classifier here
    ...
```

Keyword routing should succeed only when the rule is unambiguous for the configured set. Otherwise fall through.

## Request lifecycle

Avoid holding a database transaction or scarce connection across an LLM/network call.

```text
short DB txn: dedupe/load session/context
→ release DB resource
→ classifier/agent/tool work
→ validate proposed effects
→ short DB txn: persist state/effects/audit
→ Telegram send (idempotent/retry-aware)
```

Exact ordering may vary when a product needs an outbox/transactional-send pattern, but long external waits inside database transactions should be intentional and justified.

## Job worker

A worker should:

1. claim a durable job;
2. establish request-scoped `app.bot_id`;
3. load/create session;
4. build bounded context;
5. route;
6. execute selected agent with its own permissions;
7. validate output/proposed side effects;
8. persist durable effects with idempotency;
9. send response respecting Telegram 429/retry behavior;
10. mark job complete or schedule bounded retry.

If a worker dies after performing an external side effect but before marking the job done, retry must not repeat the effect. Use downstream idempotency keys/outbox patterns where needed.

## Session/flow state

Session locks are routing hints, not permanent authority. Provide:

- explicit `/cancel`/reset behavior where appropriate;
- expiry/idle behavior for abandoned flows;
- validation that locked agent still exists/is active;
- bounded flow state schema;
- migration/version handling when flow schemas change.

## Fallback

A fallback should be **bounded and safe**, not a universal super-agent with every tool.

Good fallback behavior:

- answer low-risk general questions within known scope;
- explain available capabilities;
- ask a clarifying question;
- escalate to a human when needed.

It should not gain privileged tools simply because classification failed.

## Routing analytics

Aggregate metadata rather than retaining raw user text indefinitely:

```sql
SELECT
  route_reason,
  target_agent,
  count(*) AS dispatches,
  avg(confidence) FILTER (WHERE confidence IS NOT NULL) AS avg_confidence,
  avg(latency_ms) AS avg_latency_ms,
  count(*) FILTER (WHERE NOT success) AS failures
FROM telegram_agent.dispatch_log
WHERE bot_id = $1
  AND created_at >= now() - interval '7 days'
GROUP BY route_reason, target_agent;
```

Use labeled samples/evals to calibrate rules; raw average confidence alone is not a routing-quality metric.

The pre-2026-08-15 document is preserved at `router-patterns.pre-2026-08-15.md`.
