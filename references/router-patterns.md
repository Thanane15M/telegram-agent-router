# Router Patterns — Intent Classification & Dispatch Engine

The router is the brain. It receives every message and decides which agent handles it.
A bad router creates confused conversations. A good router is invisible.

---

## INTENT CLASSIFICATION — THREE STRATEGIES

### Strategy 1: Fast-Path (keyword + command matching)
Handles ~70% of traffic instantly, zero LLM cost.

```python
import re
from dataclasses import dataclass

@dataclass
class IntentResult:
    agent_id: str
    confidence: float
    reason: str           # For dispatch log

def fast_path_classify(text: str, agents: list) -> IntentResult | None:
    """Returns a result if confidence > 0.9, else None (fall through to LLM)."""
    text_lower = text.lower().strip()

    # 1. Command match (highest confidence)
    if text.startswith('/'):
        command = text.split()[0].split('@')[0].lower()   # handle /cmd@botname
        for agent in agents:
            if command in agent.commands:
                return IntentResult(agent.id, 1.0, f"command:{command}")
        return IntentResult('default', 0.5, 'unknown_command')

    # 2. Keyword density match
    for agent in sorted(agents, key=lambda a: a.priority, reverse=True):
        matches = sum(
            1 for kw in agent.intent_keywords
            if re.search(r'\b' + re.escape(kw) + r'\b', text_lower)
        )
        if matches >= 2:  # Require 2+ keyword hits for fast-path
            confidence = min(0.95, 0.7 + (matches * 0.05))
            return IntentResult(agent.id, confidence, f"keywords:{matches}")

    return None   # Fall through to LLM classification
```

### Strategy 2: LLM Classification (for ambiguous messages)

```python
CLASSIFIER_PROMPT = """You are a message router. Given a user message and a list of agents,
return the best matching agent ID and your confidence (0.0-1.0).

Agents:
{agent_descriptions}

Message: "{message}"

Respond with ONLY valid JSON:
{{"agent_id": "string", "confidence": 0.0-1.0, "reasoning": "one sentence"}}
"""

async def llm_classify(message: str, agents: list, llm) -> IntentResult:
    descriptions = "\n".join(
        f'- {a.id}: {a.description}'
        for a in agents if a.is_active
    )
    response = await llm.generate(
        CLASSIFIER_PROMPT.format(
            agent_descriptions=descriptions,
            message=message[:500]   # Truncate for classifier — it doesn't need the full message
        ),
        max_tokens=100,
        temperature=0.1             # Low temperature for consistent classification
    )
    try:
        result = json.loads(response)
        return IntentResult(
            result['agent_id'],
            result['confidence'],
            f"llm:{result.get('reasoning','')[:60]}"
        )
    except (json.JSONDecodeError, KeyError):
        return IntentResult('default', 0.0, 'llm_parse_error')
```

### Strategy 3: Hybrid (production-recommended)

```python
CONFIDENCE_THRESHOLD_DIRECT   = 0.80   # Route directly
CONFIDENCE_THRESHOLD_ASK      = 0.50   # Ask for clarification
# Below 0.50 → route to orchestrator/default agent

async def classify(
    message: str,
    session: dict,
    agents: list,
    llm
) -> IntentResult:

    # 1. Session lock takes absolute priority
    if session.get('locked_agent'):
        return IntentResult(
            session['locked_agent'],
            1.0,
            f"session_lock:{session.get('locked_flow','')}"
        )

    # 2. Fast path (no LLM cost)
    fast = fast_path_classify(message, agents)
    if fast and fast.confidence >= CONFIDENCE_THRESHOLD_DIRECT:
        return fast

    # 3. LLM classification for ambiguous cases
    llm_result = await llm_classify(message, agents, llm)

    # 4. Merge: take the higher confidence
    if fast and fast.confidence > llm_result.confidence:
        return fast
    return llm_result
```

---

## DISPATCH ENGINE — COMPLETE IMPLEMENTATION

```python
import asyncpg
import time
import logging

logger = logging.getLogger(__name__)

class Router:
    def __init__(self, pool: asyncpg.Pool, agents: dict, llm, telegram):
        self.pool = pool
        self.agents = agents       # {agent_id: AgentBase instance}
        self.llm = llm
        self.telegram = telegram

    async def handle_update(self, update: dict):
        """Main entry point. Called by the job worker."""
        message = update.get('message') or update.get('callback_query', {}).get('message')
        if not message:
            return

        user_id = message['from']['id']
        chat_id = message['chat']['id']
        text = message.get('text') or update.get('callback_query', {}).get('data', '')
        start_ms = time.monotonic()

        async with self.pool.acquire() as conn:
            # 1. Load or create session
            session = await self._get_or_create_session(conn, user_id, chat_id)

            # 2. Save incoming message
            msg_id = await self._save_message(conn, session['id'], user_id, chat_id,
                                               message.get('message_id'), 'user', text)

            # 3. Load context for agent
            ctx = await self._build_context(conn, user_id, chat_id, session, text)

            # 4. Classify intent
            agent_list = list(self.agents.values())
            intent = await classify(text, session, agent_list, self.llm)

            # 5. Clamp to known agents
            if intent.agent_id not in self.agents:
                intent = IntentResult('default', 0.0, 'unknown_agent_fallback')

            # 6. Route — ask for clarification if low confidence
            if intent.confidence < CONFIDENCE_THRESHOLD_ASK and not session.get('locked_agent'):
                response_text = await self._ask_clarification(intent, agent_list)
                agent_used = 'router'
            else:
                agent = self.agents[intent.agent_id]
                response = await agent.handle(ctx)
                response_text = response.text
                agent_used = response.agent_name

                # Apply agent side effects
                await self._apply_response_effects(conn, session, user_id, response)

            # 7. Send response
            await self.telegram.send_safe(chat_id, response_text)

            # 8. Log dispatch decision
            latency = int((time.monotonic() - start_ms) * 1000)
            await conn.execute("""
                INSERT INTO bot_dispatch_log
                  (session_id, user_id, message_id, input_text, detected_intent,
                   confidence, route_reason, target_agent, latency_ms)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
            """, session['id'], user_id, msg_id, text[:500], intent.agent_id,
                intent.confidence, intent.reason, agent_used, latency)

    async def _apply_response_effects(self, conn, session, user_id, response):
        """Apply agent side-effects: memory writes, session lock changes."""

        # Write long-term memories
        for mem in response.memory_writes:
            await conn.execute("""
                INSERT INTO bot_memory (user_id, key, value, confidence, source, agent_name)
                VALUES ($1, $2, $3, $4, 'agent', $5)
                ON CONFLICT (user_id, key) DO UPDATE
                  SET value = EXCLUDED.value, updated_at = NOW(), accessed_at = NOW()
                  WHERE EXCLUDED.confidence >= bot_memory.confidence
            """, user_id, mem['key'], mem['value'],
                mem.get('confidence', 0.9), response.agent_name)

        # Handle session lock
        if response.lock_session:
            await conn.execute("""
                UPDATE bot_sessions
                SET locked_agent = $2, locked_flow = $3
                WHERE id = $1
            """, session['id'], response.agent_name, response.lock_session)

        elif response.unlock_session:
            await conn.execute("""
                UPDATE bot_sessions
                SET locked_agent = NULL, locked_flow = NULL, flow_state = '{}'
                WHERE id = $1
            """, session['id'])

    async def _ask_clarification(self, intent: IntentResult, agents: list) -> str:
        """When confidence is low, ask the user to clarify."""
        agent_list = "\n".join(
            f"• /{a.commands[0].lstrip('/') if a.commands else a.id} — {a.description[:50]}"
            for a in agents if a.is_active and a.id != 'default'
        )
        return (
            f"I wasn't sure how to help with that (confidence: {intent.confidence:.0%}).\n\n"
            f"Here's what I can do:\n{agent_list}\n\n"
            f"Use a command above, or rephrase your question."
        )
```

---

## SESSION FINITE STATE MACHINE

```
States:
  NEW         → Session just created, no agent assigned
  FREE        → Active, routing based on intent each message
  LOCKED      → Locked to specific agent for multi-turn flow
  FLOW        → In a specific multi-step flow (form, wizard, etc.)
  IDLE        → No activity for > idle_timeout (will be closed)
  ENDED       → Explicitly closed

Transitions:
  NEW → FREE          : First message received
  FREE → LOCKED       : Agent sets lock_session in response
  FREE → FLOW         : Agent starts a flow (lock_session + locked_flow)
  LOCKED → FREE       : Agent sets unlock_session = True
  FLOW → FREE         : Flow completes or is cancelled
  FLOW → FLOW         : Flow advances to next step
  * → IDLE            : No message for idle_timeout duration
  IDLE → FREE         : New message received (session reactivated)
  * → ENDED           : /cancel command or session.end() called
```

```python
class SessionFSM:
    @staticmethod
    def get_state(session: dict) -> str:
        if session['ended_at']:
            return 'ENDED'
        if session['last_active_at'] < datetime.now() - session['idle_timeout']:
            return 'IDLE'
        if session['locked_flow']:
            return 'FLOW'
        if session['locked_agent']:
            return 'LOCKED'
        if session['message_count'] == 0:
            return 'NEW'
        return 'FREE'

    @staticmethod
    async def transition(conn, session_id: str, event: str, data: dict = None):
        """Apply a state transition."""
        transitions = {
            'lock':   "UPDATE bot_sessions SET locked_agent=$2, locked_flow=$3 WHERE id=$1",
            'unlock': "UPDATE bot_sessions SET locked_agent=NULL, locked_flow=NULL, flow_state='{}' WHERE id=$1",
            'advance_flow': "UPDATE bot_sessions SET flow_state=$2 WHERE id=$1",
            'end':    "UPDATE bot_sessions SET ended_at=NOW() WHERE id=$1",
        }
        if event in transitions:
            args = [session_id] + list((data or {}).values())
            await conn.execute(transitions[event], *args)
```

---

## MULTI-STEP FLOW EXAMPLE (form wizard)

```python
class OnboardingFlow:
    """Example: collect user info over multiple messages."""
    STEPS = ['name', 'company', 'role', 'goals']

    async def handle(self, ctx: AgentContext) -> AgentResponse:
        state = ctx.session.get('flow_state', {})
        step_index = state.get('step', 0)

        if step_index >= len(self.STEPS):
            # Flow complete
            return AgentResponse(
                text=f"Perfect! I've got everything I need. How can I help you today?",
                agent_name=self.name,
                memory_writes=[
                    {'key': k, 'value': state[k], 'confidence': 1.0}
                    for k in self.STEPS if k in state
                ],
                unlock_session=True,   # Release the session
                lock_session=None,
            )

        # Save previous answer, ask next question
        current_field = self.STEPS[step_index]
        if step_index > 0:
            prev_field = self.STEPS[step_index - 1]
            state[prev_field] = ctx.message

        state['step'] = step_index + 1
        questions = {
            'name': "What's your name?",
            'company': "What company do you work for?",
            'role': "What's your role?",
            'goals': "What are you hoping to achieve? (one sentence is fine)"
        }

        return AgentResponse(
            text=questions[current_field],
            agent_name=self.name,
            memory_writes=[],
            lock_session='onboarding',   # Stay locked until flow ends
            unlock_session=False,
            flow_state_update=state,
        )
```
