# ADR 001: Initial Testing Strategy for Chosen

## Status
Accepted

## Date
2024-12-27

## Context
We need to create a comprehensive test suite for the Chosen library to verify that it correctly ensures only one instance of a supervised process runs globally across multiple Erlang VM instances.

The library uses Postgres advisory locks as the synchronization mechanism, not Erlang distribution or VM-to-VM communication.

## Decision

### Key Insight
Since Chosen synchronizes purely through Postgres advisory locks, we **do not need multiple Erlang VMs** to test the core functionality. From Postgres's perspective:
- Multiple Erlang VMs on different machines = Multiple database connections
- Multiple processes within same VM = Multiple database connections

The library doesn't distinguish between these scenarios - it only cares about database connections competing for advisory locks.

### Testing Approach
We will test with **multiple Chosen instances within a single Erlang VM**, each creating its own Postgres connection and competing for the same advisory lock.

### Test Scenarios

#### Scenario 1: Single Node - Basic Functionality
- Start a Chosen supervisor with a test GenServer
- Verify the GenServer starts and can respond to calls
- Verify the advisory lock is acquired in Postgres
- Stop Chosen and verify the lock is released

#### Scenario 2: Multiple Instances - Only One Winner
- Start 2-3 Chosen instances with the same `:name`
- Each creates its own Postgres connection
- **Assert**: Only ONE GenServer is actually running
- **Verification methods**:
  - Check which GenServer processes are alive
  - Query Postgres `pg_locks` table for advisory lock count
  - Use global registry to verify single instance

#### Scenario 3: Failover - Lock Transfer
- Start Instance A with Chosen (acquires lock)
- Start Instance B with Chosen (waits, polling)
- Kill Instance A's process or connection
- **Assert**: Instance B acquires the lock and starts its GenServer
- Verify seamless transition

#### Scenario 4: Race Condition - Simultaneous Startup
- Start multiple instances simultaneously
- All attempt to acquire the lock at the same time
- **Assert**: Still only one winner, no duplicates

#### Scenario 5: Lock Release on Crash
- Start Chosen with a GenServer that can be made to crash
- Verify lock is released when the supervised process crashes
- Verify another waiting instance can acquire it

#### Scenario 6: Multiple Independent Singletons
- Start multiple Chosen instances with different `:name` values
- **Assert**: Each different name runs exactly one instance
- Verify they don't interfere with each other

### Test Structure

```
test/
├── test_helper.exs                    # Setup test DB, connection config
├── support/
│   ├── test_repo.ex                   # Ecto repo for test DB (optional)
│   ├── test_genserver.ex              # Simple GenServer for testing
│   └── test_helpers.ex                # Utility functions
├── chosen_basic_test.exs       # Basic single-instance tests
└── chosen_singleton_test.exs   # Multi-instance singleton tests
```

### Database Setup
- Local Postgres server: `localhost:5432`
- Credentials: `postgres / postgres`
- Test database: `chosen_test`
- Create/clean database in `test_helper.exs`

### Verification Methods
1. **Process Check**: Count running GenServer processes
2. **Global Registry**: Register GenServer with `{:global, name}` and verify uniqueness
3. **Lock Query**: Query `pg_locks` table to verify advisory lock count
4. **State Tracking**: Have GenServer write to shared state (ETS/Agent) for verification

### Dependencies
Current dependencies are sufficient:
- `{:postgrex, "~> 0.16.1 or ..."}` - Already present
- `{:ecto_sql, "~> 3.0"}` - Already present (optional)

No need for:
- `local_cluster` - Not needed (single VM testing)
- Multi-node testing libraries - Not needed

## Consequences

### Positive
- Simpler test setup (no multi-node complexity)
- Faster test execution
- Easier to debug
- CI-friendly (no special networking setup)
- Tests the actual synchronization mechanism (Postgres locks)

### Negative
- Won't catch issues specific to distributed Erlang (but library doesn't use it)
- Won't test network partition scenarios (but Postgres is single source of truth)

### What We Test
✅ Lock acquisition and exclusivity  
✅ Polling behavior for waiting instances  
✅ Failover and lock transfer  
✅ Race conditions  
✅ Lock release on crash  
✅ Multiple independent singletons  

### What We Don't Test (and why it's okay)
❌ Network partitions between VMs - Not relevant, Postgres is the coordination point  
❌ Erlang clustering issues - Library doesn't use Erlang distribution  
❌ Cross-datacenter scenarios - Would just be testing Postgres, not Chosen  

## Notes
The key realization is that Chosen is fundamentally a **Postgres advisory lock wrapper**, not a distributed Erlang coordination system. Testing should focus on the lock acquisition and release behavior, which can be fully exercised within a single VM.
