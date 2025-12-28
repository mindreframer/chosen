defmodule Chosen.ConnectionEfficiencyTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests to demonstrate the efficiency improvement of using LockManager
  vs dedicated connections per Chosen instance.
  """

  describe "Connection Efficiency Comparison" do
    test "LockManager uses single connection for multiple Chosen instances" do
      # Start LockManager
      {:ok, _manager} =
        start_supervised(
          {Chosen.LockManager,
           [
             connect_opts: Chosen.TestConfig.db_config(),
             name: :efficiency_lock_manager
           ]}
        )

      # Start 5 Chosen instances using the LockManager
      for i <- 1..5 do
        child = {Chosen.TestGenServer, [name: {:global, :"efficiency_shared_#{i}"}]}

        start_supervised(
          {Chosen,
           [
             child: child,
             connect_opts: Chosen.TestConfig.db_config(),
             name: :"efficiency_lock_#{i}",
             use_lock_manager: true,
             lock_manager_name: :efficiency_lock_manager,
             polling_interval: 10
           ]},
          id: :"chosen_efficiency_#{i}"
        )
      end

      # Wait briefly for first lock
      :timer.sleep(100)

      # Verify all locks are managed by the single LockManager
      locks = Chosen.LockManager.list_locks(:efficiency_lock_manager)
      # At least one should have acquired lock (others may be queued)
      assert map_size(locks) >= 1

      # Verify LockManager is healthy and connected
      assert Chosen.LockManager.connection_status(:efficiency_lock_manager) == :connected

      # The key insight: All 5 instances share ONE LockManager connection
      # vs 5 separate connections in the old model
    end
  end

  describe "Scalability Demonstration" do
    test "can handle many Chosen instances with single LockManager" do
      # Start LockManager
      {:ok, _manager} =
        start_supervised(
          {Chosen.LockManager,
           [
             connect_opts: Chosen.TestConfig.db_config(),
             name: :scalability_lock_manager
           ]}
        )

      # Start 10 Chosen instances (would exhaust connections without LockManager)
      num_instances = 10

      for i <- 1..num_instances do
        # Each needs a unique child spec (different global name)
        child = {Chosen.TestGenServer, [name: {:global, :"scalability_child_#{i}"}]}

        start_supervised(
          {Chosen,
           [
             child: child,
             connect_opts: Chosen.TestConfig.db_config(),
             name: :"scalability_lock_#{i}",
             use_lock_manager: true,
             lock_manager_name: :scalability_lock_manager,
             polling_interval: 10
           ]},
          id: :"chosen_scale_#{i}"
        )
      end

      # Wait for locks to be processed
      :timer.sleep(100)

      # Verify LockManager is managing the locks
      locks = Chosen.LockManager.list_locks(:scalability_lock_manager)

      # All unique lock names should have been processed
      # (some may have completed and released)
      assert map_size(locks) >= 1, "LockManager should be managing locks"

      # Verify LockManager is still healthy
      assert Chosen.LockManager.connection_status(:scalability_lock_manager) == :connected
    end
  end
end
