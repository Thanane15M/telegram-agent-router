# Agent design — specialization, permissions and handoffs

Specialization is useful when it creates a **real boundary**, not merely because traffic crossed an arbitrary percentage.

## When a specialist is justified

Separate a specialist when one or more of these materially differ:

- allowed tools or data scope;
- policy/compliance constraints;
- domain knowledge/context that would otherwise pollute unrelated tasks;
- output contract or validation rules;
- human escalation/approval path;
- ownership/SLO/observability requirements;
- eval dataset and failure modes.

Do not create a new specialist only for tone, branding, or a fixed traffic threshold. Prefer the simplest architecture that keeps policy and behavior clear.

## Required agent definition

Every registered agent should have:

```text
id / display name
scope: handles / does-not-handle
input contract
output contract
allowed tools
forbidden capabilities
memory read/write policy
side-effect policy
human-approval rules
fallback/escalation rules
eval cases
```

Prompts describe behavior; **runtime permissions enforce authority**.

## Typed context

Pass the minimum context required for the selected task.

```python
from dataclasses import dataclass
from typing import Any

@dataclass(frozen=True)
class AgentContext:
    bot_id: str
    user_id: int
    chat_id: int
    session_id: str
    message: str
    recent_history: tuple[dict[str, Any], ...] = ()
    user_memory: tuple[dict[str, Any], ...] = ()
    active_flow: str | None = None
```

Do not pass other agents' hidden prompts, credentials, unrestricted tool handles, or unrelated personal data.

## Handoff invariant

A handoff transfers **task context**, not authority.

```text
Agent A recommends handoff
→ router validates target agent exists/is active
→ runtime constructs a new target-specific context
→ target agent receives only its allowed tools/data
→ sensitive side effects still pass target policy/human gates
```

Never serialize `ctx.__dict__` wholesale into a follow-up job when it can include data the target does not need.

## Side effects

Agent output should propose structured effects; a policy layer validates them before execution.

```python
@dataclass
class ProposedAction:
    action_type: str
    arguments: dict
    idempotency_key: str | None = None
    requires_human_approval: bool = False
```

A model saying “refund approved” is not the same as an authorized refund operation.

## Registry

The registry is the source of truth for routable specialists. In multi-bot deployments, identity is `(bot_id, agent_id)`.

The application may construct in-process handlers at startup, but registry synchronization must not silently activate an agent with broader permissions than the runtime policy grants.

## Memory writes

Memory is deliberate output, not automatic transcript ingestion.

For each write, define:

- key/value or structured schema;
- source (`explicit`, `inferred`, `system`);
- confidence when inferred;
- purpose and expiry;
- whether the target agent may read it later.

Never store passwords, full payment credentials, authentication tokens or other secrets in conversational memory.

## Prompt structure

Use the structure that makes the target agent reliable; there is no universal requirement for an exact number/order of prompt sections.

At minimum, prompts should make clear:

- scope and exclusions;
- relevant context;
- output format;
- uncertainty behavior;
- escalation/handoff rules.

Capabilities and security constraints must also exist in runtime policy, not only prompt prose.

## Handoff patterns

### Redirect

Use when the current agent can safely tell the user which specialist owns the task; the next user message is routed normally.

### Router-controlled handoff

The current agent emits a structured `handoff_request`; the router validates the destination and reconstructs minimal context.

### Collaborative workflow

Use multiple specialists only when each step has a clear contract and adds measurable value. Keep intermediate artifacts structured, validate them, and avoid concatenating untrusted free text directly into another system prompt.

## Observability

Track at least:

- route reason and target;
- classifier confidence (when used);
- success/failure/error class;
- latency and retry count;
- handoff count;
- clarification rate;
- human escalation rate.

Use these metrics plus labeled evals to decide whether a scope/description/routing rule should change.

The pre-2026-08-15 document is preserved at `agent-design.pre-2026-08-15.md`.
