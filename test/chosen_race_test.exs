defmodule Chosen.RaceTest do
  use ExUnit.Case, async: false
  import Chosen.TestHelpers

  setup do
    :ok
  end

  describe "RACE001: Simultaneous Startup" do
    test "correct behavior when multiple instances start simultaneously" do
      name = :race001_test
      hash = name_hash(name)

      table = :ets.new(:race001_tracking, [:public, :set])

      # Create 5 child specs
      children =
        for i <- 1..5 do
          {Chosen.TestGenServer,
           [
             name: {:global, :"race001_child_#{i}"},
             track_table: table
           ]}
        end

      # Start all 5
      for {child, i} <- Enum.with_index(children, 1) do
        {:ok, _sup} =
          start_chosen(
            child: child,
            name: name,
            sup_name: :"race001_sup#{i}",
            polling_interval: 50
          )
      end

      # Wait for lock acquisition
      assert :ok = wait_for_lock(1, hash), "No instance acquired lock"

      # Wait for child to start
      assert :ok =
               wait_until(fn ->
                 case :ets.lookup(table, :start_count) do
                   [{:start_count, _}] -> true
                   [] -> false
                 end
               end),
             "Child never started"

      # Verify exactly 1 child started
      [{:start_count, count}] = :ets.lookup(table, :start_count)
      assert count == 1, "Expected exactly 1 child to start, got #{count}"

      # Verify exactly 1 lock
      assert count_advisory_locks(1, hash) == 1

      # Count how many children are actually registered
      registered_count =
        1..5
        |> Enum.count(fn i ->
          case :global.whereis_name(:"race001_child_#{i}") do
            :undefined -> false
            pid -> Process.alive?(pid)
          end
        end)

      assert registered_count == 1, "Expected 1 registered child, got #{registered_count}"

      # Cleanup
      for i <- 1..5 do
        Supervisor.stop(:"race001_sup#{i}")
      end

      :ets.delete(table)
    end
  end

  describe "RACE002: Rapid Start/Stop Cycles" do
    test "system remains stable under rapid churn" do
      name = :race002_test
      hash = name_hash(name)

      # Start a stable instance
      child_stable = {Chosen.TestGenServer, [name: {:global, :race002_stable}]}

      {:ok, _sup_stable} =
        start_chosen(
          child: child_stable,
          name: name,
          sup_name: :race002_sup_stable,
          polling_interval: 50
        )

      # Wait for it to acquire lock
      assert :ok = wait_for_lock(1, hash)

      # Rapidly start and stop churning instances
      for i <- 1..10 do
        child = {Chosen.TestGenServer, [name: {:global, :"race002_churn_#{i}"}]}

        {:ok, sup} =
          start_chosen(
            child: child,
            name: name,
            sup_name: :"race002_sup_churn_#{i}",
            polling_interval: 50
          )

        # Let it run briefly
        Process.sleep(20)

        # Stop it
        Supervisor.stop(sup)

        # Verify still only 1 lock (stable instance)
        lock_count = count_advisory_locks(1, hash)
        assert lock_count == 1, "Expected 1 lock during churn iteration #{i}, got #{lock_count}"

        # Verify stable instance still running
        assert is_pid(:global.whereis_name(:race002_stable)),
               "Stable instance died during iteration #{i}"
      end

      # Final verification
      assert count_advisory_locks(1, hash) == 1
      assert is_pid(:global.whereis_name(:race002_stable))

      # Cleanup
      Supervisor.stop(:race002_sup_stable)
    end
  end
end
