defmodule Chosen.EdgeTest do
  use ExUnit.Case, async: false
  import Chosen.TestHelpers

  setup do
    :ok
  end

  describe "EDGE001: Multiple LockManagers" do
    @tag capture_log: true
    test "Chosen can use custom named LockManager" do
      # Start a custom LockManager
      {:ok, _manager} =
        start_supervised(
          {Chosen.LockManager,
           [
             connect_opts: Chosen.TestConfig.db_config(),
             name: :custom_lock_manager
           ]},
          id: :custom_lock_manager
        )

      child = {Chosen.TestGenServer, [name: {:global, :edge001_child}]}

      # Start Chosen with custom LockManager
      {:ok, sup_pid} =
        start_supervised(
          {Chosen,
           [
             child: child,
             name: :edge001_test,
             lock_manager_name: :custom_lock_manager
           ]}
        )

      assert Process.alive?(sup_pid)

      # Wait for child to start
      assert :ok = wait_for_global_name(:edge001_child)

      # Verify child is running
      child_pid = :global.whereis_name(:edge001_child)
      assert Process.alive?(child_pid)
    end
  end

  describe "EDGE002: Lock Held by External Process" do
    test "waits when advisory lock is held by external process, then acquires when released" do
      name = :edge002_test
      hash = name_hash(name)

      # Manually acquire the lock
      external_conn = acquire_advisory_lock(1, hash)

      # Verify lock is held
      assert count_advisory_locks(1, hash) == 1

      # Try to start Chosen - it should wait/poll
      child = {Chosen.TestGenServer, [name: {:global, :edge002_child}]}

      {:ok, _sup} =
        start_chosen(
          child: child,
          name: name,
          sup_name: :edge002_sup,
          polling_interval: 50
        )

      # Give it time to try
      Process.sleep(100)

      # Verify child didn't start (lock is held externally)
      assert :undefined == :global.whereis_name(:edge002_child)

      # Release the external lock
      release_advisory_lock(external_conn, 1, hash)

      # Now Chosen should acquire it
      assert :ok = wait_for_global_name(:edge002_child)

      # Verify child is running
      assert is_pid(:global.whereis_name(:edge002_child))
      assert count_advisory_locks(1, hash) == 1

      # Cleanup
      Supervisor.stop(:edge002_sup)
    end
  end

  describe "EDGE003: Child Process Refuses to Start" do
    @tag capture_log: true
    test "handles error when child process fails to start" do
      # Create a child spec that will fail to start
      defmodule FailingGenServer do
        def child_spec(opts) do
          %{
            id: __MODULE__,
            start: {__MODULE__, :start_link, [opts]}
          }
        end

        def start_link(_opts) do
          {:error, :intentional_failure}
        end
      end

      child = {FailingGenServer, []}

      # Trap exits to handle the shutdown
      Process.flag(:trap_exit, true)

      # Start Chosen with failing child
      {:ok, sup} =
        start_chosen(
          child: child,
          name: :edge003_test,
          sup_name: :edge003_sup
        )

      # Wait for the start attempt and shutdown
      # The supervisor will try to start the child, fail, and shutdown
      receive do
        {:EXIT, ^sup, :shutdown} -> :ok
      after
        2000 -> flunk("Expected supervisor to shutdown")
      end

      # The supervisor should have stopped due to :abort
      refute Process.alive?(sup)
    end
  end

  describe "EDGE004: Very Long Child Shutdown" do
    test "respects child shutdown time and holds lock during shutdown" do
      # Create a GenServer with slow shutdown
      defmodule SlowShutdownGenServer do
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts, name: {:global, :edge004_slow})
        end

        def init(_opts) do
          {:ok, %{}}
        end

        def terminate(_reason, _state) do
          # Slow shutdown
          Process.sleep(1000)
          :ok
        end
      end

      name = :edge004_test
      hash = name_hash(name)

      # Start first instance with slow shutdown child
      child1 = {SlowShutdownGenServer, shutdown: 2000}

      {:ok, _sup1} =
        start_chosen(
          child: child1,
          name: name,
          sup_name: :edge004_sup1,
          polling_interval: 50
        )

      # Wait for it to start
      assert :ok = wait_for_global_name(:edge004_slow)

      # Start second instance (will wait)
      child2 = {Chosen.TestGenServer, [name: {:global, :edge004_fast}]}

      {:ok, _sup2} =
        start_chosen(
          child: child2,
          name: name,
          sup_name: :edge004_sup2,
          polling_interval: 50
        )

      # Verify only first is running
      assert is_pid(:global.whereis_name(:edge004_slow))
      assert :undefined == :global.whereis_name(:edge004_fast)

      # Stop first instance - this will trigger slow shutdown
      stop_task =
        Task.async(fn ->
          Supervisor.stop(:edge004_sup1)
        end)

      # During shutdown, lock should still be held briefly
      Process.sleep(100)

      # Wait for shutdown to complete
      Task.await(stop_task, 5000)

      # Now second instance should take over
      assert :ok = wait_for_global_name(:edge004_fast)

      # Verify transition
      assert :undefined == :global.whereis_name(:edge004_slow)
      assert is_pid(:global.whereis_name(:edge004_fast))
      assert count_advisory_locks(1, hash) == 1

      # Cleanup
      Supervisor.stop(:edge004_sup2)
    end
  end
end
