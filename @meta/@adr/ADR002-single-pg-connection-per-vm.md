# ADR002: Single PostgreSQL Connection Per VM

**Status:** Proposed  
**Date:** 2024-12-27  
**Authors:** Roman  
**Deciders:** Roman  

## Context

The current Chosen implementation creates a dedicated PostgreSQL connection for each Chosen GenServer instance. This connection is used exclusively for acquiring and holding PostgreSQL advisory locks that ensure global process uniqueness.

### Problem

When using Chosen with a DynamicSupervisor to manage many singleton processes (e.g., 50-100+ instances), the current architecture creates significant resource pressure:

- **Connection Exhaustion**: Each Chosen instance consumes one PostgreSQL connection
- **Scalability Limits**: PostgreSQL has a finite connection limit (often 100-200)
- **Resource Waste**: Each connection holds minimal state (just an advisory lock)
- **Operational Complexity**: Need to configure large connection pools

### Current Architecture

```
┌─────────────────────────────────────────┐
│         Application Supervisor          │
└─────────────────┬───────────────────────┘
                  │
                  │
            ┌─────▼─────────┐
            │DynamicSup     │
            └───────┬───────┘
                    │
        ┌───────────┼───────────┐
        │           │           │
   ┌────▼────┐ ┌───▼────┐ ┌───▼────┐
   │ H-PG #1 │ │ H-PG#2 │ │ H-PG#N │
   └────┬────┘ └────┬───┘ └────┬───┘
        │           │           │
   ┌────▼────┐ ┌───▼────┐ ┌───▼────┐
   │ PG Conn │ │PG Conn │ │PG Conn │
   │  (Lock) │ │ (Lock) │ │ (Lock) │
   └─────────┘ └────────┘ └────────┘

   N Chosen instances = N PostgreSQL connections
```

Each `Chosen` instance:
1. Creates a `Postgrex.SimpleConnection` on startup
2. Uses it to acquire advisory lock via `pg_try_advisory_lock(classid, objid)`
3. Holds connection open to maintain lock
4. Polls if lock not acquired (configurable interval)

## Decision

**We will refactor Chosen to use a single shared PostgreSQL connection per Erlang VM for all advisory lock operations.**

### Proposed Architecture

```
┌─────────────────────────────────────────┐
│         Application Supervisor          │
└─────────────────┬───────────────────────┘
                  │
      ┌───────────┴───────────┐
      │                       │
┌─────▼──────────┐    ┌──────▼───────────┐
│  LockManager   │    │ DynamicSupervisor│
│ (1 PG conn)    │    │                  │
└──────┬─────────┘    └────────┬─────────┘
       │                       │
       │              ┌────────┼─────────┐
       │              │        │         │
       │         ┌────▼───┐ ┌─▼─────┐ ┌─▼─────┐
       │         │H-PG #1 │ │H-PG#2 │ │H-PG#N │
       │         └────┬───┘ └───┬───┘ └───┬───┘
       │              │         │         │
    [Lock Req] ◄──────┴─────────┴─────────┘
    [Lock Notif] ────────────────────────►

   N Chosen instances = 1 PostgreSQL connection
```

### Components

#### 1. Chosen.LockManager (New)

A singleton GenServer that:
- Manages a single `Postgrex` connection
- Receives lock acquisition requests from Chosen instances
- Executes `pg_try_advisory_lock(classid, objid)` on the shared connection
- Monitors requesting processes and auto-releases locks on process death
- Handles lock release requests
- Implements periodic polling for contested locks

**State Structure:**
```elixir
%{
  conn: pid(),                    # Postgrex connection
  locks: %{                       # Currently held locks
    {classid, objid} => %{
      owner: pid(),
      monitor_ref: reference(),
      name: term()
    }
  },
  pending: %{                     # Pending lock requests
    {classid, objid} => [
      %{
        from: pid(),
        monitor_ref: reference(),
        timer_ref: reference()      # For polling retry
      }
    ]
  }
}
```

**API:**
```elixir
# Request a lock (async)
LockManager.request_lock(name, polling_interval)

# Release a lock
LockManager.release_lock(name)

# Check lock status (for debugging)
LockManager.list_locks()
```

#### 2. Chosen (Modified)

Instead of creating its own connection:
1. On startup, sends lock request to `LockManager`
2. Waits for `:got_lock` message from manager
3. Starts supervised child when lock acquired
4. On shutdown, releases lock via manager (or relies on automatic cleanup via monitoring)

**Changes to `Chosen.init/1`:**
- Remove direct `Postgrex.SimpleConnection` creation
- Replace with `LockManager.request_lock/2` call
- Remove `pg_child` from state (no longer needed)

#### 3. Chosen.DBLock (Deprecated/Removed)

This module becomes unnecessary as lock management moves to `LockManager`.

### Lock Acquisition Flow

**Successful Lock Acquisition:**
```
Chosen                LockManager              PostgreSQL
    │                            │                        │
    │ request_lock(name)         │                        │
    ├───────────────────────────►│                        │
    │                            │ pg_try_advisory_lock() │
    │                            ├───────────────────────►│
    │                            │         true           │
    │                            │◄───────────────────────┤
    │                            │ monitor(h_pg_pid)      │
    │       :got_lock            │                        │
    │◄───────────────────────────┤                        │
    │ start_child()              │                        │
    │                            │                        │
```

**Contested Lock (Polling):**
```
Chosen                LockManager              PostgreSQL
    │                            │                        │
    │ request_lock(name)         │                        │
    ├───────────────────────────►│                        │
    │                            │ pg_try_advisory_lock() │
    │                            ├───────────────────────►│
    │                            │         false          │
    │                            │◄───────────────────────┤
    │                            │ schedule_retry()       │
    │                            │                        │
    │                         [wait polling_interval]     │
    │                            │                        │
    │                            │ pg_try_advisory_lock() │
    │                            ├───────────────────────►│
    │                            │         true           │
    │                            │◄───────────────────────┤
    │       :got_lock            │                        │
    │◄───────────────────────────┤                        │
```

**Process Death (Auto-cleanup):**
```
Chosen                LockManager              PostgreSQL
    │                            │                        │
    │         [crash]            │                        │
    X                            │                        │
                                 │ handle_info(:DOWN)     │
                                 │ pg_advisory_unlock()   │
                                 ├───────────────────────►│
                                 │                        │
                      [notify next pending requester]     │
```

## Consequences

### Positive

✅ **Dramatic Connection Reduction**: N Chosen instances → 1 connection (N could be 100+)  
✅ **Better Resource Utilization**: Single connection serves all lock operations  
✅ **Maintains Guarantees**: All uniqueness and lock semantics preserved  
✅ **Automatic Cleanup**: Monitoring ensures locks released on process death  
✅ **Backward Compatible API**: No changes to user-facing `Chosen` interface  
✅ **Simplified Connection Management**: One connection pool configuration  
✅ **Better Observability**: Centralized lock state for debugging  

### Negative

⚠️ **Single Point of Failure**: If LockManager crashes, all locks lost (mitigated by supervision)  
⚠️ **Serialization Point**: All lock operations go through one process (acceptable for advisory locks)  
⚠️ **Migration Complexity**: Need to ensure backward compatibility during rollout  

### Neutral

ℹ️ **Additional GenServer**: One more process in supervision tree  
ℹ️ **Code Complexity**: Slight increase in overall codebase complexity  

## Implementation Plan

### Phase 1: Create LockManager
1. Implement `Chosen.LockManager` GenServer
2. Add to application supervision tree (optional, via config)
3. Implement lock acquisition, release, monitoring
4. Add comprehensive tests

### Phase 2: Integrate with Chosen
1. Modify `Chosen.init/1` to use LockManager
2. Remove `Chosen.DBLock` module
3. Update state management (remove `pg_child`)
4. Ensure all existing tests pass

### Phase 3: Testing & Documentation
1. Add connection pooling tests
2. Add LockManager-specific tests (crash recovery, etc.)
3. Update documentation
4. Add migration guide

### Phase 4: Deployment
1. Release as major version (2.0.0)
2. Provide migration path for existing users
3. Monitor production deployments

## Alternatives Considered

### Alternative 1: Keep Current Architecture
**Rejected**: Does not solve the connection exhaustion problem. Unacceptable for high-scale deployments.

### Alternative 2: Connection Pool with Checkout
Use a connection pool where Chosen instances check out connections temporarily.

**Rejected**: 
- Still requires large pool for many instances
- Advisory locks require connection to stay open
- Adds complexity of pool management

### Alternative 3: Database-Side Queueing
Use PostgreSQL LISTEN/NOTIFY to queue lock requests.

**Rejected**:
- More complex than centralized manager
- Requires additional database schema (channels)
- LISTEN/NOTIFY has limitations and edge cases

### Alternative 4: Separate Lock Database
Use a different backend (Redis, etc.) for lock management.

**Rejected**:
- Adds external dependency
- Current PostgreSQL solution works well
- Goal is to reduce connections, not add services

## References

- PostgreSQL Advisory Locks: https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS
- Current codebase: `lib/chosen.ex`, `lib/chosen/db_lock.ex`
- Issue: Connection exhaustion with DynamicSupervisor usage

## Notes

- LockManager should be robust against PostgreSQL connection failures
- Consider making LockManager optional (config flag) for backward compatibility
- Performance impact should be minimal (advisory locks are fast, GenServer call overhead acceptable)
- Monitor production metrics: lock acquisition latency, LockManager mailbox size
