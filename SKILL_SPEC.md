# ChatBot Agent Architecture

> Version 4.0 · 2026-05-08
> Product goal: a personal schedule and todo agent for macOS.

This document is the source of truth for future agent work in this app. Keep it short, strict, and implementation-facing.

---

## 1. Product Goal

ChatBot is not a generic multi-agent playground. Its primary job is:

1. Understand the user's schedule, todos, courses, assignments, and important school messages.
2. Help the user query, plan, create, update, complete, and clean up those items.
3. Maintain a compact long-running memory of useful information.
4. Surface today's important work clearly.
5. Leave room for future proactive features such as notifications and a resident desktop companion.

The architecture has two core agents:

- **Main Agent**: user-facing schedule and todo agent.
- **Memory Agent**: background information extraction and memory maintenance agent.

Future agents may be added, but only when they own a distinct loop, state, or safety boundary.

---

## 2. Agent Roster

| Agent | Trigger | Primary Role | Writes | User Visible |
| --- | --- | --- | --- | --- |
| Main Agent | User message | Plan, answer, gather info, call tools, mutate user data after confirmation | Reminders, Calendar, confirmed course edits | Yes |
| Memory Agent | Background fetch, quick capture, periodic sweep | Extract useful facts, merge memory, compact/sweep/clean stale data | Memory files and sync state | Indirect |
| Focus Agent | Sidebar/today refresh | Summarize today and near-term priorities | Today summary cache | Yes |
| Notification Agent | Future feature | Decide when to notify and draft notification text | Notification queue only | Yes |
| Companion Agent | Future feature | Drive resident desktop pet mood, idle prompts, lightweight coaching | Companion state only | Yes |

### Agent Boundary Rule

Create a new top-level agent only if it has at least one of:

- A different trigger loop.
- A different persistent state file.
- A different user safety boundary.
- A different output channel.

Otherwise, use a harness profile or a sub-agent under an existing agent.

---

## 3. Harness Engineering

All LLM-driven work must go through a harness.

The harness owns:

- System prompt construction.
- Tool registry and tool filtering.
- Iteration limits.
- Context trimming.
- Sub-agent depth limits.
- Thinking budget inheritance.
- Tool result truncation.
- JSON validation and retry policy.
- Latency policy for when to use local deterministic code, a small LLM call, or a sub-agent.

Business modules own:

- Durable state.
- Deduplication.
- Permission checks.
- Final writes.
- UI mapping.

LLMs should do semantic work often, but they must not own irreversible state transitions.

Performance target:

- Use deterministic local code for identity, deduplication, state commits, and cheap filters.
- Use small/cheap LLM calls for extraction, classification, compaction proposals, and UI wording.
- Use sub-agents only when the task needs multiple semantic steps or cross-source comparison.
- Prefer cached memory over repeated network fetches.
- Prefer bounded background refresh over blocking the user's foreground Main Agent turn.

---

## 4. Harness Profiles

| Profile | Parent Agent | Tools | Max Turns | Output |
| --- | --- | --- | --- | --- |
| `main_schedule` | Main Agent | Schedule tools + memory read + delegation | 8 | Final user reply + optional UI payload |
| `main_subtask` | Main Agent | Same as parent minus delegation | 4 | Plain text, <= 3000 chars |
| `memory_extract` | Memory Agent | Read-only snapshots, no writes | 2 | Strict JSON insights |
| `memory_reduce_review` | Memory Agent | No external tools | 2 | Merge/sweep recommendations |
| `focus_summary` | Focus Agent | No tools | 1 | 90-120 char summary |
| `notification_policy` | Notification Agent | Memory/read-only schedule snapshots | 2 | Notification candidates |
| `companion_mood` | Companion Agent | Today focus + recent activity snapshots | 1 | Small state delta |

### Sub-Agent Rules

1. Maximum depth is 1.
2. Child agents cannot call `delegate_to_subagent`.
3. Child output is capped at 3000 characters.
4. Child thinking budget is `min(requested, parentBudget)`.
5. Sub-agents should be used for bounded semantic work:
   - classify a batch of messages;
   - compare memory entries;
   - summarize cross-domain task state;
   - propose cleanup actions.

Do not use sub-agents for simple single-tool lookups.

---

## 5. Main Agent

The Main Agent is the only user-facing agent that can change user schedule data.

It is also the highest-level decision maker for user-visible schedule UI. It may use memory to annotate or reshape interface state such as course cards, today focus, and schedule warnings. If current memory is missing, stale, contradictory, or too vague, the Main Agent may ask the Memory Agent to refresh, extract, compact, or re-check the relevant evidence before acting.

It handles:

- User questions about todos, reminders, calendar events, courses, assignments, and important messages.
- Creating reminders and calendar events.
- Updating, completing, and deleting items.
- Planning across Reminders, Calendar, local courses, Chaoxing assignments, and active memory.
- Delegating bounded analysis to sub-agents.
- Requesting Memory Agent refresh/review/delete when memory quality is insufficient or user explicitly marks a memory as unimportant.
- Applying memory-derived UI annotations, especially course-change warnings.

### Main Agent Tools

Allowed by default:

- Reminders read/write tools.
- Calendar read/write tools.
- Local course read tools.
- Chaoxing assignment read tool.
- Memory read tool.
- `delete_message_memory`.
- `delegate_to_subagent`.

Restricted:

- Raw Chaoxing message tool is only for explicit user requests such as "show the original message" or diagnostics.
- Local course write tools require confirmation and should be added only when the UI supports safe review.

### Memory Authority

The Main Agent may:

- Read active memory as first-class context.
- Decide that memory is insufficient.
- Trigger a Memory Agent extraction/review job for a bounded topic.
- Use memory entries to annotate UI elements.
- Ask the user to confirm if a memory-derived annotation should become a durable schedule edit.

The Main Agent must not:

- Let memory silently overwrite Reminders, Calendar, or local course data.
- Trust low-confidence memory for destructive or durable mutations.
- Display raw noisy evidence when a compact memory entry is enough.

### Mutation Rule

All user-visible writes require app-side confirmation:

- Create reminder/event/course.
- Update reminder/event/course.
- Complete reminder.
- Delete reminder/event/course.

Memory writes and sync-state writes do not require confirmation because they are internal state.

### Final Reply Rule

Default final reply is one concise Chinese sentence. Structured UI payloads should carry lists and cards.

---

## 6. Memory Agent

The Memory Agent is a background agent. It exists to keep information usable over time.

It owns:

- Extracting important facts from noisy inputs.
- Maintaining memory files.
- Compacting duplicate or verbose memories.
- Sweeping expired entries.
- Cleaning low-value entries.
- Producing derived signals for Today Focus and Course UI annotations.

It must not:

- Modify Reminders or Calendar.
- Modify the local course schedule.
- Show raw message lists in the sidebar.
- Let an LLM directly rewrite the final memory file.

### Memory Agent Inputs

Initial inputs:

- Chaoxing messages.
- Chaoxing assignments.
- Local course schedule.
- Existing active memory.
- Quick captures, later if needed.

Future inputs may include:

- User email summaries.
- Browser captures.
- Manual notes.
- Notification feedback.

All inputs should be normalized before LLM extraction.

---

## 6.5 Runtime Chaoxing Sync

Runtime sync is low-power and adaptive.

It uses two levels:

- Cheap conversation probe: checks recent conversation signatures without OCR or LLM.
- Full fetch: runs only when probe changes, when an important window is active, or when periodic freshness requires overlap.

Rules:

- Probe must never call OCR or LLM.
- Full fetch must use overlap and strict sync-state deduplication.
- Memory Agent receives only normalized, filtered candidates.
- Important windows may temporarily increase frequency:
  - assignment due within 24 hours;
  - course starts within 2 hours;
  - active high/medium memory highlights;
  - user explicitly asks for latest Chaoxing updates.
- No-change runs back off toward 10 minutes.

Current implementation:

- `ChaoxingRuntimeSyncStatus` tracks probe/full-fetch timestamps, errors, no-change count, and next refresh.
- `ChatViewModel` owns a runtime sync loop while the app is running.
- `ChaoxingService.fetchMessageConversationProbes` is the cheap probe.
- Changed conversations trigger targeted `fetchRecentMessages(forConversationIDs:)`.

---

## 7. Memory Files

Memory is split by durability and purpose.

```text
ApplicationSupport/ChatBot/
  chaoxing_memory.json
  chaoxing_sync_state.json
  memory_debug_trace.jsonl
```

### `chaoxing_memory.json`

Stores active useful facts.

Required fields per entry:

```json
{
  "id": "uuid",
  "dedupe_key": "course_change:calculus:2026-05-12",
  "category": "course_change",
  "importance": "high",
  "title": "Short title",
  "summary": "Concrete useful fact with time/place when available",
  "action_hint": "Optional next action",
  "content_time": "ISO-8601 or null",
  "expires_at": "ISO-8601",
  "source_ids": ["..."],
  "source_fingerprints": ["..."],
  "linked_assignment_key": null,
  "linked_course_key": "course:calculus",
  "confidence": 0.86,
  "created_at": "ISO-8601",
  "updated_at": "ISO-8601"
}
```

Allowed categories:

- `course_change`
- `exam`
- `assignment_notice`
- `assignment_note`
- `event`
- `deadline`
- `notice`
- `other`

Only `high` and `medium` importance entries are stored.

### `chaoxing_sync_state.json`

Tracks what has already been processed.

It must store:

- Initialized timestamp.
- Last successful fetch timestamp.
- Processed source IDs.
- Processed fingerprints.
- Per-conversation recent IDs and fingerprints.
- Assignment snapshot hash.
- Assignment keys.

### `memory_debug_trace.jsonl`

Append-only diagnostic log for pipeline decisions.

Each record:

```json
{
  "source_id": "...",
  "stage": "filter|extract|reduce|sweep",
  "decision": "keep|drop|merge|error",
  "reason": "duplicate_assignment",
  "created_at": "ISO-8601"
}
```

This file is not normal UI.

---

## 8. Memory Pipeline

The Memory Agent pipeline is:

```text
fetch assignments
fetch recent messages with overlap
load sync state
normalize messages
deterministic filter
OCR candidate images
LLM extract insights
code reducer validates and merges
write memory + sync state atomically
derive UI signals
periodic compact/sweep/clean
```

### New Message Detection

Never rely on `sentAt` alone.

A message is already processed if any identity matches:

- Source message ID.
- Fingerprint.
- Recent per-conversation ID.
- Recent per-conversation fingerprint.

Fingerprint:

```text
sha256(
  conversationID.lowercased()
  + senderID.lowercased()
  + sentAt rounded to minute
  + normalizedText
  + sorted(imageURLs).joined()
)
```

Always fetch with an overlap window. Only advance sync state after the full pipeline commits successfully.

### First Fetch Bootstrap

If no sync state exists:

1. Load existing memory, if any, and seed processed IDs/fingerprints from it.
2. Fetch recent messages.
3. Process only:
   - messages from the last 7 days; or
   - messages from the last 30 days with explicit future content time.
4. Cap bootstrap candidates at 80 messages.
5. Store only high/medium, non-expired entries.
6. Do not show historical raw messages in the UI.

### Deterministic Filter

Drop before LLM:

- Already processed messages.
- Muted conversations.
- `READ_ACK`, `DELIVER_ACK`, `RECALL`.
- Empty text with no image.
- Pure acknowledgements, greetings, emoji-only chatter.
- Messages older than 30 days with no future content time.
- Assignment notifications duplicated by the assignment snapshot.

Send to LLM:

- Course changes.
- Exams.
- Deadlines.
- Events.
- Teacher/TA action notices.
- Candidate image messages.
- Messages that match course schedule context.

### OCR

OCR only candidate image messages after filtering.

Keep OCR text separate from message text:

```swift
text
ocrText
combinedText
```

---

## 9. LLM Extraction

Memory extraction is the right place to use LLMs heavily.

The extractor receives:

- Current time.
- Candidate messages.
- Assignment snapshot.
- Future 14-day course snapshot.
- Active memory summary.

It returns strict JSON only:

```json
{
  "insights": [
    {
      "decision": "keep",
      "drop_reason": null,
      "category": "course_change",
      "importance": "high",
      "confidence": 0.88,
      "dedupe_key_hint": "course_change:calculus:2026-05-12",
      "title": "Course changed",
      "summary": "Concrete fact with time/place",
      "action_hint": "Verify local course schedule",
      "content_time": "ISO-8601 or null",
      "expires_at": "ISO-8601",
      "course_name_hint": "Calculus",
      "assignment_key_hint": null,
      "source_ids": ["..."]
    }
  ]
}
```

LLM constraints:

- No Markdown.
- No final memory JSON.
- No state writes.
- Drop uncertain facts with confidence below 0.6.
- Do not keep generic chat.
- Do not keep assignment notices already represented by assignment data.

---

## 10. Reducer

The reducer is deterministic Swift code.

It:

1. Validates extractor JSON.
2. Drops non-keep insights.
3. Drops confidence below 0.6.
4. Recomputes canonical `dedupe_key`.
5. Deduplicates against assignments.
6. Merges with existing memory by `dedupe_key`.
7. Merges source IDs and fingerprints.
8. Updates timestamps.
9. Sweeps expired entries.
10. Enforces the 100-entry cap.
11. Writes memory and sync state atomically.

### Assignment Deduplication

Chaoxing assignments are the source of truth for homework.

Assignment key:

```text
assignment:
  normalize(courseName)
  + normalize(title)
  + dueDate rounded to minute
```

If a message only says a homework item was posted or is due, and the assignment snapshot already contains it, drop the message.

If a message adds extra information not present in the assignment item, store it as `assignment_note` with `linked_assignment_key`.

If a message appears before the assignment item, store it temporarily as `assignment_notice`. On the next assignment snapshot match, delete it or downgrade it.

---

## 11. Compact, Sweep, Clean

The Memory Agent runs maintenance in three modes.

### Sweep

Fast deterministic pass. Run on every memory read/write.

Remove:

- Expired entries.
- Completed linked assignments with no extra note.
- Course-change entries more than 24 hours after the relevant course ends.

### Compact

LLM-assisted pass. Run periodically or when memory exceeds 80 entries.

Use `memory_reduce_review` to propose:

- Duplicate groups.
- Overly verbose summaries.
- Conflicting entries.
- Entries that should be merged.

Reducer applies only validated proposals.

### Clean

Stronger maintenance. Run manually or weekly.

Use LLM to classify stale low-value entries, then reducer deletes only entries that pass deterministic safety checks.

---

## 12. UI Contract

### Sidebar

Chaoxing sidebar shows assignments only.

No raw Chaoxing message list.

### Today Focus

Today Focus must consider:

- Today's due assignments.
- This week's upcoming assignments.
- Today's reminders.
- Today's calendar events.
- Today's courses.
- Active memory for exams, course changes, events, deadlines, and assignment notes.

Focus Agent output is short Chinese text, no Markdown.

Implemented:

- The Today widget includes high/medium active memory highlights.
- Course-change, exam, deadline, event, and assignment-note memory entries can affect the summary hash and generated text.
- Memory highlights are shown as compact visible rows below the summary.

### Course UI

Course UI reacts to memory annotations.

`course_change` entries may create badges:

- Possible reschedule.
- Possible cancellation.
- Possible makeup class.
- Possible room change.

Memory annotations do not overwrite local course data. Course edits require user confirmation.

Implemented:

- Course and event rows ask the ViewModel for memory annotations.
- Matching is deterministic, based on course title tokens, linked course keys, content date, and course-change keywords.
- Warnings are displayed as badges only; they do not mutate the local course schedule.

### Companion

The Companion Agent is a lightweight resident desktop UI channel.

It may read:

- Today Focus.
- Active memory.
- Runtime sync status.
- Upcoming assignments and important items.

It must not:

- Modify Reminders, Calendar, courses, memory, or sync state.
- Call raw Chaoxing tools.
- Interrupt the user repeatedly.

Current implementation:

- `CompanionEngine` creates deterministic mood, pose, bubble, urgency, action, and suggestions.
- Cheap LLM feedback may rewrite only the short bubble text.
- LLM feedback is cached by source hash and skipped when there is no meaningful change.
- The UI renders a resident desktop pet (常驻桌面) companion with smart suggestions, upcoming items, sync status, and a one-hour quiet action.

---

## 13. Future Agents

### Notification Agent

Add this when proactive alerts are implemented.

It should own:

- Notification queue.
- Notification suppression rules.
- Quiet hours.
- Re-notify policy.
- Notification wording.

It should consume:

- Today Focus.
- Active memory.
- Reminders/Calendar snapshots.
- User preferences.

It must not directly mutate schedule data.

### Companion Agent

Add this when the desktop pet is implemented.

It should own:

- Companion mood/state.
- Lightweight prompts.
- Idle behavior.
- Small coaching messages.

It should consume:

- Today Focus.
- User activity state.
- Notification state.

It must not create, update, or delete schedule data.

The companion should use existing Main Agent and Notification Agent outputs instead of building its own planning stack.

---

## 14. Tool Strategy

### Main Agent

Default tools:

- `list_reminders`
- `create_reminder`
- `update_reminder`
- `complete_reminder`
- `delete_reminder`
- `list_calendar_events`
- `create_calendar_event`
- `update_calendar_event`
- `delete_calendar_event`
- `list_courses`
- `get_chaoxing_assignments`
- `read_message_memory`
- `refresh_message_memory`
- `delete_message_memory`
- `delegate_to_subagent`

Raw message tool:

- `get_chaoxing_messages` is diagnostic or explicit-user-request only.
- `write_message_memory` is not exposed to the Main Agent. Memory writes go through the Memory Agent reducer.

### Memory Agent

Memory Agent should prefer internal modules over exposed user tools:

- Assignment snapshot provider.
- Message snapshot provider.
- Normalizer.
- Filter.
- OCR.
- Extraction harness.
- Reducer.
- Memory store.
- Sync state store.

---

## 15. Time Rules

Every harness prompt includes current local time.

Preferred format:

```text
Current time: yyyy-MM-dd HH:mm:ss UTC+08:00
```

Tool date arguments must be ISO-8601 with timezone offset.

User-facing deadline text should be relative when possible:

- Today HH:mm
- Tomorrow HH:mm
- Weekday HH:mm
- M/d HH:mm
- Overdue since M/d

---

## 16. Implementation Order

1. Build Memory models and v1-to-v2 migration. Done.
2. Build sync state store and bootstrap logic. Done.
3. Extract deterministic filter and debug trace. Done.
4. Move OCR after filtering. Done.
5. Build `memory_extract` harness profile. Done as `ChaoxingMemoryAgent`.
6. Build reducer with assignment deduplication. Done.
7. Remove raw Chaoxing messages from sidebar. Done.
8. Feed active memory into Today Focus. Done.
9. Add course UI annotations from memory. Done.
10. Add compact/sweep/clean maintenance. Done.
11. Later: add Notification Agent.
12. Later: add Companion Agent.

---

## 17. Hard Rules

| Never | Use Instead |
| --- | --- |
| Let LLM directly rewrite memory files | LLM extracts insights; reducer writes |
| Use `sentAt` alone for new-message detection | Source ID + fingerprint + overlap |
| Import all history on first fetch | Bootstrap scan with strict limits |
| Show raw Chaoxing messages in sidebar | Show assignments only |
| Show duplicate homework notices | Assignment snapshot dedup |
| Silently modify local courses from messages | Memory annotation + confirmation |
| Let a skill call LLM directly | Harness profile or sub-agent |
| Let sub-agents recurse | Depth guard and tool filtering |
| Skip confirmation for user data writes | App-side confirmation |
