defmodule Chosen.LockManagerTest do
  use ExUnit.Case, async: false
  import Chosen.TestHelpers

  setup do
    # Start a LockManager for each test
    {:ok, manager_pid} =
      start_supervised(
        {Chosen.LockManager,
         [
           connect_opts: Chosen.TestConfig.db_config(),
           name: :test_lock_manager
         ]},
        id: :test_lock_manager
      )

    {:ok, manager: manager_pid}
  end

  describe "LockManager Basic Functionality" do
    test "can acquire a lock", %{manager: _manager} do
      name = :lock_manager_test_1
      hash = name_hash(name)

      # Request lock
      :ok = Chosen.LockManager.request_lock(:test_lock_manager, name, 100)

      # Wait for lock acquisition
      assert_receive :got_lock, 1000

      # Verify lock exists in DB
      assert count_advisory_locks(1, hash) == 1

      # Verify lock tracked by manager
      locks = Chosen.LockManager.list_locks(:test_lock_manager)
      assert map_size(locks) == 1
    end

    test "can release a lock", %{manager: _manager} do
      name = :lock_manager_test_2
      hash = name_hash(name)

      # Acquire lock
      :ok = Chosen.LockManager.request_lock(:test_lock_manager, name, 100)
      assert_receive :got_lock, 1000

      # Release lock
      :ok = Chosen.LockManager.release_lock(:test_lock_manager, name)

      # Verify lock released in DB
      assert :ok = wait_for_lock_release(1, hash)
      assert count_advisory_locks(1, hash) == 0

      # Verify lock removed from manager
      locks = Chosen.LockManager.list_locks(:test_lock_manager)
      assert map_size(locks) == 0
    end

    test "reports connection status", %{manager: _manager} do
      status = Chosen.LockManager.connection_status(:test_lock_manager)
      assert status == :connected
    end
  end

  describe "LockManager Queueing and Polling" do
    test "queues contested lock requests", %{manager: _manager} do
      name = :lock_manager_queue_test
      hash = name_hash(name)

      # First process acquires lock and holds it
      pid1 =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name, 10)

          receive do
            :got_lock -> send(:test_process, :first_got_lock)
          end

          receive do
            :release -> :ok
          end
        end)

      Process.register(self(), :test_process)

      # Wait for first lock
      assert_receive :first_got_lock, 200
      assert count_advisory_locks(1, hash) == 1

      # Second process requests same lock (should be queued)
      pid2 =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name, 10)

          receive do
            :got_lock -> send(:test_process, :second_acquired)
          after
            500 -> send(:test_process, :timeout)
          end

          # Keep alive until explicitly killed
          receive do
            :done -> :ok
          end
        end)

      # Verify still only one lock (second request queued)
      :timer.sleep(20)
      assert count_advisory_locks(1, hash) == 1

      # Now release the first lock
      send(pid1, :release)

      # Second process should get the lock quickly
      assert_receive :second_acquired, 200
      assert count_advisory_locks(1, hash) == 1

      # Cleanup
      send(pid2, :done)
      Process.unregister(:test_process)
    end

    test "handles multiple queued requests", %{manager: _manager} do
      name = :lock_manager_multi_queue
      hash = name_hash(name)

      # Acquire lock externally
      lock_holder = acquire_advisory_lock(1, hash)
      assert count_advisory_locks(1, hash) == 1

      Process.register(self(), :test_process_multi)

      # Create 3 processes requesting the same lock
      pids =
        for i <- 1..3 do
          spawn(fn ->
            Chosen.LockManager.request_lock(:test_lock_manager, name, 10)

            receive do
              :got_lock -> send(:test_process_multi, {:acquired, i})
            after
              500 -> send(:test_process_multi, {:timeout, i})
            end

            # Keep process alive to hold lock
            receive do
              :die -> :ok
            end
          end)
        end

      # Give them time to queue (minimal)
      :timer.sleep(20)

      # Release external lock
      release_advisory_lock(lock_holder, 1, hash)

      # Wait for exactly one to acquire
      assert_receive {:acquired, _winner_id}, 200

      # Verify exactly one lock in DB
      assert count_advisory_locks(1, hash) == 1

      # Cleanup
      Enum.each(pids, &Process.exit(&1, :kill))
      Process.unregister(:test_process_multi)
    end
  end

  describe "LockManager Process Death Handling" do
    test "auto-releases lock when owner process dies", %{manager: _manager} do
      name = :lock_manager_death_test
      hash = name_hash(name)

      # Spawn a process that acquires lock then dies
      pid =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name, 10)

          receive do
            :got_lock -> send(:test_proc, :got_it)
          end

          receive do
            :die -> :ok
          end
        end)

      Process.register(self(), :test_proc)

      # Wait for lock acquisition
      assert_receive :got_it, 200
      assert count_advisory_locks(1, hash) == 1

      # Kill the process
      send(pid, :die)

      # Verify lock auto-released
      assert :ok = wait_for_lock_release(1, hash, 200)
      assert count_advisory_locks(1, hash) == 0

      Process.unregister(:test_proc)
    end

    test "next queued request gets lock after owner dies", %{manager: _manager} do
      name = :lock_manager_death_queue
      hash = name_hash(name)

      # First process acquires and holds
      pid1 =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name, 10)

          receive do
            :got_lock -> send(:test_proc2, :first_got_it)
          end

          receive do
            :die -> :ok
          end
        end)

      Process.register(self(), :test_proc2)
      assert_receive :first_got_it, 200
      assert count_advisory_locks(1, hash) == 1

      # Second process requests (queued)
      pid2 =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name, 10)

          receive do
            :got_lock -> send(:test_proc2, :second_got_it)
          after
            500 -> send(:test_proc2, :timeout)
          end

          # Keep alive
          receive do
            :done -> :ok
          end
        end)

      :timer.sleep(20)

      # Kill first process
      send(pid1, :die)

      # Second process should get lock quickly
      assert_receive :second_got_it, 500
      assert count_advisory_locks(1, hash) == 1

      # Cleanup
      send(pid2, :done)
      Process.unregister(:test_proc2)
    end

    test "removes pending requests when requesting process dies", %{manager: _manager} do
      name = :lock_manager_pending_death
      hash = name_hash(name)

      # Hold lock externally
      lock_holder = acquire_advisory_lock(1, hash)

      # Spawn a process that requests but then dies
      pid =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name, 10)

          receive do
            :die -> :ok
          after
            100 -> :ok
          end
        end)

      :timer.sleep(10)
      send(pid, :die)
      :timer.sleep(20)

      # Release external lock
      release_advisory_lock(lock_holder, 1, hash)
      :timer.sleep(30)

      # Verify no one got the lock (dead process was removed from queue)
      assert count_advisory_locks(1, hash) == 0
    end
  end

  describe "LockManager with Multiple Locks" do
    test "can manage multiple independent locks", %{manager: _manager} do
      name1 = :lock_manager_multi_1
      name2 = :lock_manager_multi_2
      hash1 = name_hash(name1)
      hash2 = name_hash(name2)

      Process.register(self(), :test_multi)

      # Acquire two different locks (keep processes alive)
      pid1 =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name1, 10)

          receive do
            :got_lock -> send(:test_multi, :lock1_acquired)
          end

          receive do
            :die -> :ok
          end
        end)

      pid2 =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name2, 10)

          receive do
            :got_lock -> send(:test_multi, :lock2_acquired)
          end

          receive do
            :die -> :ok
          end
        end)

      # Wait for both locks
      assert_receive :lock1_acquired, 200
      assert_receive :lock2_acquired, 200

      # Verify both locks exist
      assert count_advisory_locks(1, hash1) == 1
      assert count_advisory_locks(1, hash2) == 1

      # Verify manager tracks both
      locks = Chosen.LockManager.list_locks(:test_lock_manager)
      assert map_size(locks) == 2

      # Cleanup
      send(pid1, :die)
      send(pid2, :die)
      :timer.sleep(20)
      Process.unregister(:test_multi)
    end

    test "independent locks don't interfere with each other", %{manager: _manager} do
      name1 = :lock_manager_indep_1
      name2 = :lock_manager_indep_2
      hash1 = name_hash(name1)
      hash2 = name_hash(name2)

      Process.register(self(), :test_indep)

      # Hold lock1 in a separate process
      pid1 =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name1, 10)

          receive do
            :got_lock -> send(:test_indep, :indep1)
          end

          receive do
            :die -> :ok
          end
        end)

      assert_receive :indep1, 200

      # Request lock2 (different lock, should succeed immediately)
      pid2 =
        spawn(fn ->
          Chosen.LockManager.request_lock(:test_lock_manager, name2, 10)

          receive do
            :got_lock -> send(:test_indep, :indep2)
          end

          receive do
            :die -> :ok
          end
        end)

      assert_receive :indep2, 200

      # Both locks held
      assert count_advisory_locks(1, hash1) == 1
      assert count_advisory_locks(1, hash2) == 1

      # Cleanup
      send(pid1, :die)
      send(pid2, :die)
      :timer.sleep(20)
      Process.unregister(:test_indep)
    end
  end

  describe "LockManager Integration with Chosen" do
    test "Chosen can use LockManager", %{manager: _manager} do
      child = {Chosen.TestGenServer, [name: {:global, :lock_mgr_integration}]}

      {:ok, sup_pid} =
        start_supervised(
          {Chosen,
           [
             child: child,
             connect_opts: Chosen.TestConfig.db_config(),
             name: :lock_mgr_integration_test,
             use_lock_manager: true,
             lock_manager_name: :test_lock_manager,
             polling_interval: 100
           ]}
        )

      # Wait for child to start
      assert :ok = wait_for_global_name(:lock_mgr_integration)

      # Verify child responds
      child_pid = :global.whereis_name(:lock_mgr_integration)
      assert :pong = Chosen.TestGenServer.ping(child_pid)

      # Verify lock held via manager
      locks = Chosen.LockManager.list_locks(:test_lock_manager)
      assert map_size(locks) == 1

      # Clean shutdown
      assert Process.alive?(sup_pid)
      stop_supervised(Chosen)
    end

    test "multiple Chosen instances share same LockManager", %{manager: _manager} do
      child1 = {Chosen.TestGenServer, [name: {:global, :shared_mgr_1}]}
      child2 = {Chosen.TestGenServer, [name: {:global, :shared_mgr_2}]}

      # Start first instance
      {:ok, _sup1} =
        start_supervised(
          {Chosen,
           [
             child: child1,
             connect_opts: Chosen.TestConfig.db_config(),
             name: :shared_lock_1,
             use_lock_manager: true,
             lock_manager_name: :test_lock_manager,
             polling_interval: 100
           ]},
          id: :chosen_1
        )

      # Start second instance with different lock name
      {:ok, _sup2} =
        start_supervised(
          {Chosen,
           [
             child: child2,
             connect_opts: Chosen.TestConfig.db_config(),
             name: :shared_lock_2,
             use_lock_manager: true,
             lock_manager_name: :test_lock_manager,
             polling_interval: 100
           ]},
          id: :chosen_2
        )

      # Wait for both children to start
      assert :ok = wait_for_global_name(:shared_mgr_1)
      assert :ok = wait_for_global_name(:shared_mgr_2)

      # Verify both locks managed by same LockManager
      locks = Chosen.LockManager.list_locks(:test_lock_manager)
      assert map_size(locks) == 2

      # Verify only one DB connection (the LockManager's)
      # We can't easily test this without introspection, but we can verify functionality
      assert is_pid(:global.whereis_name(:shared_mgr_1))
      assert is_pid(:global.whereis_name(:shared_mgr_2))
    end
  end
end
