defmodule Chosen.FailoverTest do
  use ExUnit.Case, async: false
  import Chosen.TestHelpers

  setup do
    # Trap exits so we don't crash when killing supervisors
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "FAILOVER001: Lock Transfer on Winner Crash" do
    @tag capture_log: true
    test "when lock holder crashes, another waiting instance acquires the lock" do
      name = :failover001_test
      hash = name_hash(name)

      # Start first instance
      child1 = {Chosen.TestGenServer, [name: {:global, :failover001_a}]}

      {:ok, sup1} =
        start_chosen(
          child: child1,
          name: name,
          sup_name: :failover001_sup1,
          polling_interval: 100
        )

      # Wait for it to acquire lock
      assert :ok = wait_for_global_name(:failover001_a)

      # Start second instance (will wait/poll)
      child2 = {Chosen.TestGenServer, [name: {:global, :failover001_b}]}

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: name,
          sup_name: :failover001_sup2,
          polling_interval: 100
        )

      # Verify only first is running
      assert is_pid(:global.whereis_name(:failover001_a))
      assert :undefined == :global.whereis_name(:failover001_b)
      assert count_advisory_locks(1, hash) == 1

      # Kill first instance
      Process.exit(sup1, :kill)

      # Wait for second instance to acquire lock
      assert :ok = wait_for_global_name(:failover001_b)

      # Verify failover
      assert :undefined == :global.whereis_name(:failover001_a)
      assert is_pid(:global.whereis_name(:failover001_b))
      assert count_advisory_locks(1, hash) == 1

      # Cleanup
      Supervisor.stop(:failover001_sup2)
    end
  end

  describe "FAILOVER002: Lock Transfer on Connection Loss" do
    @tag capture_log: true
    test "when connection is lost, lock is released and another instance takes over" do
      name = :failover002_test
      hash = name_hash(name)

      # Start first instance
      child1 = {Chosen.TestGenServer, [name: {:global, :failover002_a}]}

      {:ok, sup1} =
        start_chosen(
          child: child1,
          name: name,
          sup_name: :failover002_sup1,
          polling_interval: 100
        )

      # Wait for lock
      assert :ok = wait_for_global_name(:failover002_a)

      # Start second instance
      child2 = {Chosen.TestGenServer, [name: {:global, :failover002_b}]}

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: name,
          sup_name: :failover002_sup2,
          polling_interval: 100
        )

      # Verify only first is running
      assert is_pid(:global.whereis_name(:failover002_a))
      assert :undefined == :global.whereis_name(:failover002_b)

      # Kill the supervisor (simulates connection loss leading to shutdown)
      Process.exit(sup1, :shutdown)

      # Wait for second to take over
      assert :ok = wait_for_global_name(:failover002_b)

      # Verify failover
      assert count_advisory_locks(1, hash) == 1
      assert is_pid(:global.whereis_name(:failover002_b))

      # Cleanup
      Supervisor.stop(:failover002_sup2)
    end
  end

  describe "FAILOVER003: Lock Transfer on Child Process Crash" do
    @tag capture_log: true
    test "when supervised child crashes, lock is released" do
      name = :failover003_test
      hash = name_hash(name)

      # Start first instance with crashable child
      child1 = {Chosen.TestGenServer, [name: {:global, :failover003_a}]}

      {:ok, _sup1} =
        start_chosen(
          child: child1,
          name: name,
          sup_name: :failover003_sup1,
          polling_interval: 100
        )

      # Wait for lock
      assert :ok = wait_for_global_name(:failover003_a)

      # Start second instance
      child2 = {Chosen.TestGenServer, [name: {:global, :failover003_b}]}

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: name,
          sup_name: :failover003_sup2,
          polling_interval: 100
        )

      # Get the child process
      child_pid = :global.whereis_name(:failover003_a)
      assert is_pid(child_pid)

      # Crash the child
      Process.exit(child_pid, :kill)

      # Chosen should shut down, releasing the lock
      # Second instance should take over
      assert :ok = wait_for_global_name(:failover003_b)

      # Verify failover
      assert count_advisory_locks(1, hash) == 1
      assert is_pid(:global.whereis_name(:failover003_b))

      # Cleanup
      Supervisor.stop(:failover003_sup2)
    end
  end

  describe "FAILOVER004: Multiple Waiting Instances Race" do
    @tag capture_log: true
    test "when lock released, exactly one of multiple waiting instances acquires it" do
      name = :failover004_test
      hash = name_hash(name)

      table = :ets.new(:failover004_tracking, [:public, :set])

      # Start first instance
      child1 = {Chosen.TestGenServer, [name: {:global, :failover004_a}, track_table: table]}

      {:ok, sup1} =
        start_chosen(
          child: child1,
          name: name,
          sup_name: :failover004_sup1,
          polling_interval: 50
        )

      # Wait for lock
      assert :ok = wait_for_global_name(:failover004_a)

      # Start 3 more instances (all will wait)
      child2 = {Chosen.TestGenServer, [name: {:global, :failover004_b}, track_table: table]}
      child3 = {Chosen.TestGenServer, [name: {:global, :failover004_c}, track_table: table]}
      child4 = {Chosen.TestGenServer, [name: {:global, :failover004_d}, track_table: table]}

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: name,
          sup_name: :failover004_sup2,
          polling_interval: 50
        )

      {:ok, _sup3} =
        start_chosen(
          child: child3,
          name: name,
          sup_name: :failover004_sup3,
          polling_interval: 50
        )

      {:ok, _sup4} =
        start_chosen(
          child: child4,
          name: name,
          sup_name: :failover004_sup4,
          polling_interval: 50
        )

      # Give them time to start polling
      Process.sleep(100)

      # Kill first instance
      Process.exit(sup1, :kill)

      # Wait for one of the others to acquire
      assert :ok = wait_for_lock(1, hash)

      # Give a bit more time for any race conditions to manifest
      Process.sleep(200)

      # Verify exactly 1 new child started (total 2 starts including first)
      [{:start_count, count}] = :ets.lookup(table, :start_count)
      assert count == 2, "Expected exactly 2 total starts (1 original + 1 failover), got #{count}"

      # Verify exactly 1 lock
      assert count_advisory_locks(1, hash) == 1

      # Cleanup
      Supervisor.stop(:failover004_sup2)
      Supervisor.stop(:failover004_sup3)
      Supervisor.stop(:failover004_sup4)
      :ets.delete(table)
    end
  end
end
