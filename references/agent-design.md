# Agent Design — Specialization Principles & Handoff Patterns

---

## WHEN TO CREATE A NEW AGENT (vs extend the router)

Create a new specialized agent when:

| Signal | Example |
|---|---|
| Distinct domain vocabulary | Finance agent needs accounting terms the others don't |
| Different system prompt length | Legal agent needs 2000-token prompt, others use 500 |
| Different tool access | Data agent needs DB query access, others don't |
| Different response format | Report agent outputs structured JSON, others output prose |
| User explicitly asks for separation | "Talk to the sales team" should mean a different agent |
| Routing creates confusion | Users get inconsistent answers from the same agent on different domains |

**Do NOT create a new agent when:**
- The difference is just tone (use prompt conditionals instead)
- You have < 5 distinct use cases total (one agent with few conditionals is simpler)
- The agent would handle < 10% of traffic (fold it into the orchestrator)

---

## AGENT SPECIALIZATION FRAMEWORK

Every agent needs these three elements precisely defined:

### 1. Scope Definition (what this agent handles AND what it doesn't)

```python
class SalesAgent(AgentBase):
    name = "sales"
    description = (
        "Handles: pricing inquiries, quotes, product comparisons, purchase decisions, "
        "discount requests, upsells. "
        "Does NOT handle: technical support, billing issues, account management."
    )
    # The description is given verbatim to the LLM orchestrator.
    # The 'Does NOT handle' section is critical — it tells the router when NOT to use this agent.
```

### 2. Context Requirements (what data the agent needs)

```python
@dataclass
class SalesAgentContext:
    # From session memory
    user_budget: Optional[str]       # 'enterprise' | 'smb' | 'startup'
    previous_quotes: list[dict]      # Past quotes this user received
    # From long-term memory
    company_size: Optional[str]
    industry: Optional[str]
    # Never include: other agents' conversation history, system internals
```

### 3. Typed Output Contract

```python
@dataclass
class SalesAgentResponse(AgentResponse):
    # Required: what every response must produce
    text: str
    # Optional: side effects
    memory_writes: list[dict]        # Facts learned about user
    quote_generated: Optional[dict]  # If a quote was produced
    escalation_needed: bool = False  # Should a human follow up?
```

---

## SYSTEM PROMPT ARCHITECTURE

A well-structured agent system prompt has exactly these sections, in this order:

```
IDENTITY (2-3 sentences)
Who you are, what you do, what you don't do.

CONTEXT (injected at runtime)
Current conversation history, user memory, session state.

CAPABILITIES (bullet list)
What tools/data you have access to.

CONSTRAINTS (bullet list — CRITICAL)
Hard rules that cannot be overridden by user instructions.
Examples:
- Never quote prices you're not sure about
- Always ask for budget before recommending
- Never discuss competitors by name

RESPONSE FORMAT
How to structure your output.
Be specific: "Respond in 2-4 paragraphs. Start with the direct answer.
If unsure, say so explicitly."

ESCALATION TRIGGERS
When to hand off to a human or another agent.
```

```python
SALES_SYSTEM_PROMPT = """
IDENTITY
You are a specialized sales assistant. You handle pricing, quotes, and purchase decisions.
You do NOT handle technical support, billing disputes, or account management — redirect
those to the appropriate team.

CONTEXT
User history: {recent_history}
Known facts about this user: {user_memory}

CAPABILITIES
- Quote generation for standard product tiers
- Discount authority up to 15% (request approval above that)
- Access to current pricing catalog

CONSTRAINTS
- Never commit to a price without checking the current catalog
- Always confirm budget range before presenting options
- Never quote a timeline shorter than the standard SLA

RESPONSE FORMAT
Respond in 1-3 paragraphs. Lead with the direct answer or question.
If you need more information, ask ONE question only — not multiple at once.
Use plain language, no jargon.

ESCALATION
If the user asks about contract terms, legal clauses, or payment disputes,
say: "Let me connect you with our contracts team for that."
"""
```

---

## HANDOFF PATTERNS

### Pattern 1: Hard Handoff (different agent takes over completely)

```python
# Agent A detects the message is out of its scope
async def handle(self, ctx: AgentContext) -> AgentResponse:
    if "invoice" in ctx.message.lower() and self.name == "sales":
        return AgentResponse(
            text="That sounds like a billing question — let me connect you "
                 "with the finance team. Just say /finance to reach them.",
            agent_name=self.name,
            memory_writes=[],
            unlock_session=True,   # Release lock so router can dispatch to finance
        )
```

### Pattern 2: Soft Handoff (orchestrator decides)

```python
# Agent signals it cannot fully answer, orchestrator adds context
async def handle(self, ctx: AgentContext) -> AgentResponse:
    response = await self.llm.generate(self.system_prompt, ctx.message)
    if "[NEEDS_EXPERT]" in response:   # Agent uses a sentinel in its prompt
        # Queue a job for the specialized agent
        return AgentResponse(
            text="Let me pull in a specialist for this one — give me a moment.",
            agent_name=self.name,
            follow_up_job={
                'agent': 'specialist',
                'context': ctx.__dict__,
                'priority': 1
            }
        )
```

### Pattern 3: Collaborative (agents contribute sequentially)

```python
# Orchestrator runs multiple agents and combines responses
async def collaborative_handle(self, ctx: AgentContext) -> AgentResponse:
    # Agent A: gets facts
    facts = await self.agents['data'].handle(ctx)
    # Agent B: turns facts into recommendation
    ctx_with_facts = replace(ctx, message=ctx.message + f"\n\nData: {facts.text}")
    recommendation = await self.agents['advisor'].handle(ctx_with_facts)

    return AgentResponse(
        text=recommendation.text,
        agent_name='orchestrator',
        memory_writes=facts.memory_writes + recommendation.memory_writes,
    )
```

---

## AGENT REGISTRY PATTERN

The registry is the single source of truth for what agents exist.
Never hardcode agent names in routing logic.

```python
class AgentRegistry:
    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool
        self._agents: dict[str, AgentBase] = {}

    def register(self, agent: AgentBase):
        """Call at startup for each agent."""
        self._agents[agent.name] = agent

    async def sync_to_db(self):
        """Persist current registry to PostgreSQL."""
        async with self.pool.acquire() as conn:
            for agent in self._agents.values():
                await conn.execute("""
                    INSERT INTO bot_agent_registry
                      (id, display_name, description, commands, intent_hints, is_active)
                    VALUES ($1, $2, $3, $4, $5, $6)
                    ON CONFLICT (id) DO UPDATE
                      SET display_name = EXCLUDED.display_name,
                          description  = EXCLUDED.description,
                          commands     = EXCLUDED.commands,
                          intent_hints = EXCLUDED.intent_hints,
                          updated_at   = NOW()
                """, agent.name, agent.display_name, agent.description,
                    agent.commands, agent.intent_keywords, True)

    def get_menu_text(self) -> str:
        """Generate help menu automatically from registry."""
        lines = ["*Available commands:*\n"]
        for agent in self._agents.values():
            if agent.commands:
                cmd = agent.commands[0]
                lines.append(f"{cmd} — {agent.description[:60]}")
        return "\n".join(lines)

    def all_active(self) -> list[AgentBase]:
        return [a for a in self._agents.values() if a.is_active]
```

---

## OBSERVABILITY — MAKING THE ROUTER DEBUGGABLE

Without this, you cannot improve routing quality over time.

```python
# After 1 week in production, run this query to find routing problems:
ROUTING_AUDIT_QUERY = """
SELECT
  input_text,
  detected_intent,
  confidence,
  target_agent,
  route_reason,
  COUNT(*) AS occurrences
FROM bot_dispatch_log
WHERE created_at > NOW() - INTERVAL '7 days'
  AND confidence < 0.7          -- Low-confidence dispatches
  AND route_reason = 'llm'      -- Not from fast-path
GROUP BY 1,2,3,4,5
ORDER BY occurrences DESC
LIMIT 20;
"""

# Use the results to:
# - Add these phrases to agent.intent_keywords (fast-path them next time)
# - Improve agent.description (make LLM classification more accurate)
# - Create new agents if a clear cluster emerges
```
