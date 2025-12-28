defmodule Chosen.SingletonTest do
  use ExUnit.Case, async: false
  import Chosen.TestHelpers

  setup do
    :ok
  end

  describe "SINGLE001: Multiple Instances - Only One Wins" do
    test "only one child process starts when multiple instances compete" do
      name = :single001_test
      hash = name_hash(name)

      # Create tracking table
      table = :ets.new(:single001_tracking, [:public, :set])

      # Start 3 instances simultaneously
      child1 =
        {Chosen.TestGenServer, [name: {:global, :single001_child1}, track_table: table]}

      child2 =
        {Chosen.TestGenServer, [name: {:global, :single001_child2}, track_table: table]}

      child3 =
        {Chosen.TestGenServer, [name: {:global, :single001_child3}, track_table: table]}

      # Start all 3 - just start them directly, no need for Task.async
      {:ok, _sup1} =
        start_chosen(
          child: child1,
          name: name,
          sup_name: :single001_sup1,
          polling_interval: 50
        )

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: name,
          sup_name: :single001_sup2,
          polling_interval: 50
        )

      {:ok, _sup3} =
        start_chosen(
          child: child3,
          name: name,
          sup_name: :single001_sup3,
          polling_interval: 50
        )

      # Wait for lock acquisition and child to start
      assert :ok = wait_for_lock(1, hash), "No instance acquired advisory lock"

      # Wait for child to actually initialize
      assert :ok =
               wait_until(fn ->
                 case :ets.lookup(table, :start_count) do
                   [{:start_count, _}] -> true
                   [] -> false
                 end
               end),
             "Child never started (ETS entry not created)"

      [{:start_count, count}] = :ets.lookup(table, :start_count)
      assert count == 1, "Expected exactly 1 child to start, got #{count}"

      # Verify only 1 advisory lock
      assert count_advisory_locks(1, hash) == 1

      # Count globally registered children
      registered_count =
        [:single001_child1, :single001_child2, :single001_child3]
        |> Enum.count(fn name ->
          case :global.whereis_name(name) do
            :undefined -> false
            pid -> Process.alive?(pid)
          end
        end)

      assert registered_count == 1, "Expected 1 registered child, got #{registered_count}"

      # Cleanup
      Supervisor.stop(:single001_sup1)
      Supervisor.stop(:single001_sup2)
      Supervisor.stop(:single001_sup3)
      :ets.delete(table)
    end
  end

  describe "SINGLE002: Verify Loser Instances Keep Polling" do
    test "instances that don't acquire lock continue polling" do
      name = :single002_test
      hash = name_hash(name)

      # Start first instance - this will acquire the lock
      child1 = {Chosen.TestGenServer, [name: {:global, :single002_winner}]}

      {:ok, _sup1} =
        start_chosen(
          child: child1,
          name: name,
          sup_name: :single002_sup1,
          polling_interval: 100
        )

      # Wait for lock
      assert :ok = wait_for_lock(1, hash)

      # Start second instance - this should poll
      child2 = {Chosen.TestGenServer, [name: {:global, :single002_loser}]}

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: name,
          sup_name: :single002_sup2,
          polling_interval: 100
        )

      # Give it time to poll at least once
      Process.sleep(150)

      # Verify still only 1 lock
      assert count_advisory_locks(1, hash) == 1

      # Verify winner is running, loser is not
      assert is_pid(:global.whereis_name(:single002_winner))
      assert :undefined == :global.whereis_name(:single002_loser)

      # Cleanup
      Supervisor.stop(:single002_sup1)
      Supervisor.stop(:single002_sup2)
    end
  end

  describe "SINGLE003: Different Names Don't Interfere" do
    test "multiple Chosen instances with different names run simultaneously" do
      # Start 3 instances with different names
      child1 = {Chosen.TestGenServer, [name: {:global, :single003_a}]}
      child2 = {Chosen.TestGenServer, [name: {:global, :single003_b}]}
      child3 = {Chosen.TestGenServer, [name: {:global, :single003_c}]}

      {:ok, _sup1} =
        start_chosen(child: child1, name: :singleton_a, sup_name: :single003_sup1)

      {:ok, _sup2} =
        start_chosen(child: child2, name: :singleton_b, sup_name: :single003_sup2)

      {:ok, _sup3} =
        start_chosen(child: child3, name: :singleton_c, sup_name: :single003_sup3)

      # Wait for all to start
      assert :ok = wait_for_global_name(:single003_a)
      assert :ok = wait_for_global_name(:single003_b)
      assert :ok = wait_for_global_name(:single003_c)

      # Verify all 3 are running
      assert is_pid(:global.whereis_name(:single003_a))
      assert is_pid(:global.whereis_name(:single003_b))
      assert is_pid(:global.whereis_name(:single003_c))

      # Verify 3 different locks
      hash_a = name_hash(:singleton_a)
      hash_b = name_hash(:singleton_b)
      hash_c = name_hash(:singleton_c)

      assert count_advisory_locks(1, hash_a) == 1
      assert count_advisory_locks(1, hash_b) == 1
      assert count_advisory_locks(1, hash_c) == 1

      # Cleanup
      Supervisor.stop(:single003_sup1)
      Supervisor.stop(:single003_sup2)
      Supervisor.stop(:single003_sup3)
    end
  end
end
