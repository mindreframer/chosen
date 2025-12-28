defmodule Chosen.ConfigTest do
  use ExUnit.Case, async: false
  import Chosen.TestHelpers

  setup do
    :ok
  end

  describe "CONFIG001: Custom Polling Interval" do
    test "custom polling interval is respected" do
      name = :config001_test
      hash = name_hash(name)

      # Start first instance to hold the lock
      child1 = {Chosen.TestGenServer, [name: {:global, :config001_winner}]}

      {:ok, _sup1} =
        start_chosen(
          child: child1,
          name: name,
          sup_name: :config001_sup1,
          polling_interval: 1000
        )

      # Wait for lock
      assert :ok = wait_for_lock(1, hash)

      # Start second with custom interval - it will poll
      child2 = {Chosen.TestGenServer, [name: {:global, :config001_loser}]}

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: name,
          sup_name: :config001_sup2,
          # Fast polling
          polling_interval: 100
        )

      assert %{specs: 1, active: 1, supervisors: 0, workers: 1} ==
               Chosen.count_children(:config001_sup1)

      assert %{active: 0, specs: 1, supervisors: 0, workers: 0} ==
               Chosen.count_children(:config001_sup2)

      # Verify it's polling (still only 1 lock after several poll cycles)
      Process.sleep(200)
      assert count_advisory_locks(1, hash) == 1
      assert :undefined == :global.whereis_name(:config001_loser)

      # Cleanup
      Supervisor.stop(:config001_sup1)
      Supervisor.stop(:config001_sup2)
    end
  end

  describe "CONFIG002: Basic Configuration" do
    test "Chosen works with default LockManager" do
      child = {Chosen.TestGenServer, [name: {:global, :config002_child}]}

      {:ok, sup} =
        start_chosen(
          child: child,
          name: :config002_test,
          sup_name: :config002_sup
        )

      # Verify it works
      assert :ok = wait_for_global_name(:config002_child)
      assert is_pid(:global.whereis_name(:config002_child))

      # Cleanup
      Supervisor.stop(sup)
    end
  end

  describe "CONFIG003: Custom Singleton Name" do
    test "custom name parameter creates different lock keys" do
      # Start two instances with different names
      child1 = {Chosen.TestGenServer, [name: {:global, :config003_a}]}
      child2 = {Chosen.TestGenServer, [name: {:global, :config003_b}]}

      {:ok, _sup1} =
        start_chosen(
          child: child1,
          name: :custom_name_1,
          sup_name: :config003_sup1
        )

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: :custom_name_2,
          sup_name: :config003_sup2
        )

      # Wait for both to start
      assert :ok = wait_for_global_name(:config003_a)
      assert :ok = wait_for_global_name(:config003_b)

      # Verify different lock keys
      hash1 = name_hash(:custom_name_1)
      hash2 = name_hash(:custom_name_2)

      assert hash1 != hash2
      assert count_advisory_locks(1, hash1) == 1
      assert count_advisory_locks(1, hash2) == 1

      # Cleanup
      Supervisor.stop(:config003_sup1)
      Supervisor.stop(:config003_sup2)
    end
  end

  describe "CONFIG004: Lock Manager Integration" do
    test "Chosen requires LockManager to be running" do
      child = {Chosen.TestGenServer, [name: {:global, :config004_child}]}

      # Start a Chosen instance using the default LockManager
      {:ok, sup_pid} =
        start_supervised(
          {Chosen,
           [
             child: child,
             name: :config004_test,
             lock_manager_name: Chosen.LockManager
           ]}
        )

      assert Process.alive?(sup_pid)

      # Wait for child to start
      assert :ok = wait_for_global_name(:config004_child)

      # Verify child is running
      child_pid = :global.whereis_name(:config004_child)
      assert Process.alive?(child_pid)
    end
  end
end
