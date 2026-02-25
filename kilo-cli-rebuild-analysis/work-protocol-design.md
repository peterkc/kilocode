# Work Protocol Design: AHP Work Tracking on bdx/Dolt

**Beads**: acf-zqxv6
**Related**: `memory-design.md` (ckd — what we learned), this doc (bdx — what we're doing)

## Problem

Every agentic CLI treats sessions as the unit of work. Real work spans multiple sessions,
but all structured context is lost between them:

| CLI | Cross-Session State | Limitations |
|-----|-------------------|-------------|
| Claude Code | Compressed conversation summary (~4K tokens) | Lossy, no structure, no dependencies |
| Kilo Code | HistoryItem (cost/tokens, no semantic content) | No status, no relationships |
| OpenCode | None | No persistence at all |

None tracks: what was decided, what's blocked, what depends on what, what's next.

## Solution: bdx/Dolt as Work Backend

Persistent, queryable, versioned work items that survive sessions.

```
Memory (ckd) = what we learned
Work (bdx)   = what we're doing
```

## The work_item Tool

New agent tool for managing persistent work:

```typescript
interface WorkItemParams {
    action:
        | "create"     // New work item
        | "list"       // List items (filterable)
        | "show"       // Detail view
        | "update"     // Status, notes, assignee
        | "close"      // Mark complete
        | "depend"     // Add dependency
        | "ready"      // Items with no blockers
        | "handoff"    // Structured context for next session

    // For create:
    title?: string
    type?: "task" | "bug" | "feature" | "epic"
    priority?: number     // 0-4 (0=critical, 4=backlog)
    description?: string

    // For list/ready:
    status?: "open" | "in_progress" | "blocked" | "completed"
    labels?: string[]

    // For update/close/show:
    id?: string
    notes?: string        // append-only session notes
    design?: string       // technical approach

    // For depend:
    depends_on?: string   // this item depends on another
}
```

**System prompt description**:
```
Manage persistent work items that survive across sessions. Use this to
track what needs to be done, what's blocked, what depends on what, and
to create handoff context for the next session. Work items persist in
a versioned database — they are NOT ephemeral like todo lists.
```

## Comparison: Existing Todo vs bdx Work Items

| Dimension | Kilo UpdateTodoListTool | bdx work_item |
|-----------|------------------------|---------------|
| Persistence | Session-only (Task.todoList) | Dolt database (survives sessions) |
| Format | Markdown checklist | Structured fields (title, type, status, notes, design) |
| Dependencies | None | DAG (depends_on, blocks/blocked_by) |
| Status | pending/in_progress/completed | Same + blocked (auto from deps) |
| Cross-session | Lost on session end | handoff() generates structured context |
| Queryable | Grep through markdown | SQL queries |
| Versioned | No | Dolt (diff, log, branch, merge) |
| Notes | Overwrites each update | Append-only (session history preserved) |
| Team sharing | Not possible | dolt push/pull |

## Agent Behavior: Cross-Session Continuity

```
SESSION 1:
  Agent: work_item(create, "Fix auth token refresh", type=bug)
  → kilo-abc1

  Agent: work_item(create, "Add refresh token rotation", depends_on=kilo-abc1)
  → kilo-abc2 (blocked by kilo-abc1)

  Agent: work_item(update, kilo-abc1, status=in_progress,
         notes="Root cause: missing exp check in jwt.ts:45")
  [session ends]

SESSION 2:
  Agent: work_item(handoff)
  → "kilo-abc1 (in_progress): Fix auth token refresh
     Last session: missing exp check in jwt.ts:45
     kilo-abc2 (blocked): depends on kilo-abc1"

  Agent: [continues from exactly where session 1 left off]
  Agent: work_item(close, kilo-abc1)
  → kilo-abc2 automatically unblocked

  Agent: work_item(ready)
  → "kilo-abc2: Add refresh token rotation (now unblocked)"
```

## Membrane Interface

```typescript
interface WorkProvider {
    // CRUD
    create(item: WorkItemCreate): Promise<WorkItem>
    get(id: string): Promise<WorkItem>
    list(filters?: WorkFilters): Promise<WorkItem[]>
    update(id: string, changes: Partial<WorkItem>): Promise<void>
    close(id: string, reason?: string): Promise<void>

    // Dependencies
    addDependency(item: string, dependsOn: string): Promise<void>
    ready(): Promise<WorkItem[]>  // items with no open blockers
    blocked(): Promise<WorkItem[]>

    // Session lifecycle
    handoff(): Promise<HandoffContext>
    appendNotes(id: string, notes: string): Promise<void>
}
```

## AHP Work Protocol Layer

```
AHP Protocol Layers (revised):

1. Context loading      (.agents/rules/, skills/, AGENTS.md)
2. Lifecycle hooks      (.agents/hooks.json)
3. Tool protocol        (core tools + code_grep + code_inspect)
4. Subagent delegation  (SubAgent with model routing)
5. Memory protocol      (ckd/Dolt — what we learned)
6. Work protocol        (bdx/Dolt — what we're doing)     ← THIS
7. Tool catalog         (.agents/tools.json)
8. Permissions          (.agents/permissions.json)
```

## Dolt Stack (ckd + bdx)

```
Dolt Instance
├── memory tables (ckd)
│   ├── memory (knowledge with confidence)
│   ├── corrections (learning trajectory)
│   └── session_context (handoff state)
│
└── work tables (bdx)
    ├── issues (work items with status + deps)
    ├── dependencies (DAG edges)
    └── labels (categorization)
```

## Open Questions

- Q1: Should memory and work share one Dolt database or be separate?
- Q2: How does work_item interact with external PM tools (GitHub Issues, Linear)?
- Q3: Should handoff() merge data from both ckd (memory) and bdx (work)?
- Q4: Does the work_item tool replace Kilo's UpdateTodoListTool entirely, or coexist?
- Q5: Should session_context live in memory tables (ckd) or work tables (bdx)?
