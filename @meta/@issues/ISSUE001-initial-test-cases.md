# ISSUE001: Initial Test Cases for Chosen

## Overview
Comprehensive test cases to verify Chosen correctly ensures singleton behavior across multiple instances using Postgres advisory locks.

---

## Basic Functionality Tests

### BASIC001: Start and Stop Single Instance
**Description**: Verify that a single Chosen instance can start and supervise a child GenServer successfully.

**Setup**:
- Single Chosen supervisor with a simple test GenServer

**Steps**:
1. Start Chosen with a test GenServer child
2. Verify the child GenServer is running (pid is alive)
3. Send a message to the GenServer and verify response
4. Stop Chosen

**Expected**:
- Child GenServer starts successfully
- GenServer responds to messages
- Clean shutdown

---

### BASIC002: Advisory Lock Acquired
**Description**: Verify that starting Chosen acquires a Postgres advisory lock.

**Setup**:
- Single Chosen supervisor
- Access to query Postgres `pg_locks` table

**Steps**:
1. Start Chosen with name `:test_singleton`
2. Query Postgres for advisory locks with the expected key
3. Verify lock exists and is held

**Expected**:
- Advisory lock with key `(1, hash(:test_singleton))` exists in `pg_locks`
- Lock type is `advisory`
- Lock is granted (not waiting)

---

### BASIC003: Advisory Lock Released on Shutdown
**Description**: Verify that stopping Chosen releases the advisory lock.

**Setup**:
- Single Chosen supervisor running

**Steps**:
1. Start Chosen
2. Verify lock is acquired (query `pg_locks`)
3. Stop Chosen
4. Query `pg_locks` again

**Expected**:
- Lock exists while running
- Lock is released (no longer in `pg_locks`) after shutdown

---

### BASIC004: Supervisor Callback Functions
**Description**: Verify that `which_children/1` and `count_children/1` work correctly.

**Setup**:
- Chosen with named supervisor (`:sup_name`)

**Steps**:
1. Start Chosen with `sup_name: :test_sup`
2. Call `Chosen.which_children(:test_sup)`
3. Call `Chosen.count_children(:test_sup)`
4. Verify results match expected structure

**Expected**:
- `which_children/1` returns list with child info
- `count_children/1` returns map with correct counts (1 active, 1 worker/supervisor)

---

## Singleton Behavior Tests

### SINGLE001: Multiple Instances - Only One Wins
**Description**: Verify that when multiple Chosen instances compete for the same singleton name, only one child process starts.

**Setup**:
- 3 Chosen supervisors with same `:name` value
- Each configured with its own test GenServer

**Steps**:
1. Start 3 Chosen instances simultaneously with `name: :my_singleton`
2. Wait for lock acquisition/polling to settle
3. Count how many child GenServers are actually running
4. Query `pg_locks` to verify only one lock

**Expected**:
- Exactly 1 child GenServer is running
- Exactly 1 advisory lock exists in Postgres
- Other 2 Chosen instances are waiting (polling)

---

### SINGLE002: Verify Loser Instances Keep Polling
**Description**: Verify that instances that don't acquire the lock continue polling.

**Setup**:
- 2 Chosen instances with same name
- Access to message tracing or logging

**Steps**:
1. Start Instance A (acquires lock)
2. Start Instance B (fails to acquire lock)
3. Monitor Instance B's behavior
4. Verify it's executing polling queries

**Expected**:
- Instance B sends periodic `pg_try_advisory_lock()` queries
- Polling interval matches configured value (default 300ms)
- Instance B does not start its child process

---

### SINGLE003: Different Names Don't Interfere
**Description**: Verify that multiple Chosen instances with different names can run simultaneously.

**Setup**:
- 3 Chosen instances with different `:name` values

**Steps**:
1. Start Chosen with `name: :singleton_a`
2. Start Chosen with `name: :singleton_b`
3. Start Chosen with `name: :singleton_c`
4. Verify all child GenServers are running
5. Query `pg_locks` for multiple advisory locks

**Expected**:
- 3 child GenServers running (one for each name)
- 3 different advisory locks in Postgres
- No interference between instances

---

## Failover Tests

### FAILOVER001: Lock Transfer on Winner Crash
**Description**: Verify that when the lock-holding instance crashes, another waiting instance acquires the lock.

**Setup**:
- 2 Chosen instances with same name
- Instance A holds the lock initially

**Steps**:
1. Start Instance A (acquires lock, child running)
2. Start Instance B (waiting, polling)
3. Verify only Instance A's child is running
4. Kill Instance A's Chosen supervisor
5. Wait for Instance B to acquire lock
6. Verify Instance B's child is now running

**Expected**:
- Initially: Only A's child running
- After crash: Only B's child running
- Lock transfers from A to B
- No period where both are running
- May have brief period where neither is running

---

### FAILOVER002: Lock Transfer on Connection Loss
**Description**: Verify failover when the winner's Postgres connection is lost.

**Setup**:
- 2 Chosen instances
- Ability to simulate connection loss

**Steps**:
1. Start Instance A (holds lock)
2. Start Instance B (waiting)
3. Terminate Instance A's Postgres connection (not the supervisor)
4. Verify Instance A's child is stopped
5. Verify Instance B acquires lock and starts child

**Expected**:
- Connection loss triggers lock release
- Instance A stops its child
- Instance B detects lock availability and acquires it
- Failover completes within reasonable time

---

### FAILOVER003: Lock Transfer on Child Process Crash
**Description**: Verify that when the supervised child crashes, the lock is released and another instance can acquire it.

**Setup**:
- 2 Chosen instances
- Child GenServer that can be instructed to crash

**Steps**:
1. Start Instance A with crashable child (holds lock)
2. Start Instance B (waiting)
3. Send message to A's child to make it crash with `raise "boom"`
4. Verify A's Chosen supervisor shuts down
5. Verify Instance B acquires lock

**Expected**:
- Child crash causes Chosen shutdown
- Lock is released
- Instance B takes over
- Chosen follows OTP supervision principles

---

### FAILOVER004: Multiple Waiting Instances Race
**Description**: When lock is released, verify that among multiple waiting instances, exactly one acquires it.

**Setup**:
- 4 Chosen instances with same name

**Steps**:
1. Start Instance A (holds lock)
2. Start Instances B, C, D (all waiting)
3. Kill Instance A
4. Wait for lock acquisition
5. Count running child processes

**Expected**:
- Exactly 1 of {B, C, D} acquires the lock
- Only 1 child GenServer is running
- Other 2 instances continue polling
- No race condition causes duplicates

---

## Race Condition Tests

### RACE001: Simultaneous Startup
**Description**: Verify correct behavior when multiple instances start at exactly the same time.

**Setup**:
- 5 Chosen instances to start simultaneously

**Steps**:
1. Prepare 5 Chosen child specs
2. Start all 5 using `Task.async_stream` or similar for true concurrency
3. Wait for all to complete startup
4. Count running child processes
5. Query `pg_locks`

**Expected**:
- Exactly 1 child process running
- Exactly 1 advisory lock held
- No errors or crashes
- 4 instances polling

---

### RACE002: Rapid Start/Stop Cycles
**Description**: Verify stability under rapid churn of instance starts and stops.

**Setup**:
- Ability to start/stop Chosen instances rapidly

**Steps**:
1. Start Instance A (holds lock)
2. Rapidly start and stop Instances B, C, D in quick succession
3. Throughout, verify at most 1 child is running
4. Query locks periodically

**Expected**:
- Always 0 or 1 child running (never 2+)
- No deadlocks or stuck states
- System remains stable
- Lock is always acquired by someone when instances are available

---

## Configuration Tests

### CONFIG001: Custom Polling Interval
**Description**: Verify that custom polling interval is respected.

**Setup**:
- Chosen with `polling_interval: 100` (ms)
- Instance that doesn't hold the lock

**Steps**:
1. Start Instance A (holds lock)
2. Start Instance B with `polling_interval: 100`
3. Monitor Instance B's query frequency to Postgres
4. Measure time between `pg_try_advisory_lock()` attempts

**Expected**:
- Instance B polls approximately every 100ms
- Interval is consistent
- Different from default 300ms

---

### CONFIG002: Using Repo vs Connect Opts
**Description**: Verify both configuration methods work (`:repo` and `:connect_opts`).

**Setup**:
- Test Ecto Repo configured
- Direct connection options

**Steps**:
1. Start Chosen with `repo: TestRepo`
2. Verify it works (child starts, lock acquired)
3. Stop and start with `connect_opts: [hostname: "localhost", ...]`
4. Verify it works the same way

**Expected**:
- Both methods successfully connect to Postgres
- Both acquire advisory locks
- Both supervise children correctly

---

### CONFIG003: Custom Singleton Name
**Description**: Verify custom `:name` parameter works correctly.

**Setup**:
- Multiple Chosen instances with different names

**Steps**:
1. Start with `name: :custom_name_1`
2. Start with `name: :custom_name_2`
3. Query `pg_locks` and verify different lock keys
4. Verify both children running

**Expected**:
- Lock keys are different: `hash(:custom_name_1)` vs `hash(:custom_name_2)`
- Both instances run independently
- Correct lock key calculation

---

### CONFIG004: Missing Required Options
**Description**: Verify appropriate error when neither `:repo` nor `:connect_opts` provided.

**Setup**:
- Invalid configuration

**Steps**:
1. Attempt to start Chosen without `:repo` or `:connect_opts`

**Expected**:
- Raises `ArgumentError` with message: "expected one of `repo` or `connect_ops`, got neither"
- Does not start
- Clear error message

---

## Edge Cases

### EDGE001: Postgres Unavailable on Startup
**Description**: Verify behavior when Postgres is unavailable at startup.

**Setup**:
- Connection config pointing to non-existent Postgres

**Steps**:
1. Configure Chosen with invalid connection details
2. Start Chosen
3. Observe behavior

**Expected**:
- Chosen does not start child process
- Supervisor handles connection failure gracefully
- Appropriate error logging
- No crash that brings down parent supervisor

---

### EDGE002: Lock Held by External Process
**Description**: Verify behavior when advisory lock is already held by an external (non-Chosen) process.

**Setup**:
- Manually acquire advisory lock via direct Postgres connection
- Chosen instance

**Steps**:
1. In a separate connection, run `SELECT pg_advisory_lock(1, <hash>)`
2. Start Chosen with matching name
3. Verify it waits/polls
4. Release the external lock
5. Verify Chosen acquires it

**Expected**:
- Chosen correctly waits while lock is held externally
- Polling behavior is correct
- Acquires lock when available
- Starts child process

---

### EDGE003: Child Process Refuses to Start
**Description**: Verify behavior when child process `start_link` returns error.

**Setup**:
- Child spec that returns `{:error, :some_reason}` on start

**Steps**:
1. Configure Chosen with a child that fails to start
2. Start Chosen
3. Observe behavior

**Expected**:
- Chosen logs error appropriately
- Chosen supervisor stops (`:abort`)
- Error follows OTP supervisor conventions
- Lock is released

---

### EDGE004: Very Long Child Shutdown
**Description**: Verify shutdown behavior when child has long shutdown time.

**Setup**:
- Child with `shutdown: 10_000` that takes time to stop

**Steps**:
1. Start Chosen with slow-shutdown child
2. Start second instance (waiting)
3. Stop first instance
4. Monitor shutdown process
5. Verify second instance waits appropriately

**Expected**:
- First instance waits for child shutdown (respects `:shutdown` value)
- Lock is held until shutdown completes
- Second instance acquires lock after first fully stops
- Clean transition

---

## Summary

**Total Test Cases**: 24

**Breakdown by Category**:
- Basic Functionality: 4 tests
- Singleton Behavior: 3 tests
- Failover: 4 tests
- Race Conditions: 2 tests
- Configuration: 4 tests
- Edge Cases: 4 tests

**Implementation Priority**:
1. BASIC001-004 (Foundation)
2. SINGLE001-003 (Core singleton behavior)
3. FAILOVER001-004 (Critical functionality)
4. CONFIG001-004 (Configuration validation)
5. RACE001-002 (Concurrency safety)
6. EDGE001-004 (Robustness)
