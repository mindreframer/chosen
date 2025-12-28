defmodule Chosen.BasicTest do
  use ExUnit.Case, async: false
  import Chosen.TestHelpers

  setup do
    :ok
  end

  describe "BASIC001: Start and Stop Single Instance" do
    test "single instance starts and supervises child GenServer" do
      child = {Chosen.TestGenServer, [name: {:global, :basic001_child}]}

      {:ok, sup_pid} =
        start_chosen(
          child: child,
          name: :basic001_test,
          sup_name: :basic001_sup
        )

      assert Process.alive?(sup_pid)

      # Wait for child to start
      assert :ok = wait_for_global_name(:basic001_child)

      # Verify child responds
      child_pid = :global.whereis_name(:basic001_child)
      assert :pong = Chosen.TestGenServer.ping(child_pid)

      # Clean shutdown
      :ok = Supervisor.stop(sup_pid)
      refute Process.alive?(sup_pid)
    end
  end

  describe "BASIC002: Advisory Lock Acquired" do
    test "starting Chosen acquires advisory lock" do
      name = :basic002_test
      hash = name_hash(name)

      child = {Chosen.TestGenServer, []}

      {:ok, sup_pid} =
        start_chosen(
          child: child,
          name: name
        )

      # Wait for lock acquisition
      assert :ok = wait_for_lock(1, hash)

      # Verify lock exists
      locks = query_advisory_locks(1)

      assert Enum.any?(locks, fn [_classid, objid, granted] ->
               objid == hash and granted == true
             end)

      Supervisor.stop(sup_pid)
    end
  end

  describe "BASIC003: Advisory Lock Released on Shutdown" do
    test "stopping Chosen releases the advisory lock" do
      name = :basic003_test
      hash = name_hash(name)

      child = {Chosen.TestGenServer, []}

      {:ok, sup_pid} =
        start_chosen(
          child: child,
          name: name
        )

      # Wait for lock
      assert :ok = wait_for_lock(1, hash)

      # Stop supervisor
      :ok = Supervisor.stop(sup_pid)

      # Wait for lock release
      assert :ok = wait_for_lock_release(1, hash)

      # Verify no lock
      assert count_advisory_locks(1, hash) == 0
    end
  end

  describe "BASIC004: Supervisor Callback Functions" do
    test "which_children/1 and count_children/1 work correctly" do
      child = {Chosen.TestGenServer, [name: {:global, :basic004_child}]}

      {:ok, _sup_pid} =
        start_chosen(
          child: child,
          name: :basic004_test,
          sup_name: :basic004_sup
        )

      # Wait for child to start
      assert :ok = wait_for_global_name(:basic004_child)

      # Test which_children
      children = Chosen.which_children(:basic004_sup)
      assert is_list(children)
      assert length(children) == 1

      [{id, pid, type, modules}] = children
      assert id == Chosen.TestGenServer
      assert is_pid(pid)
      assert type == :worker
      assert modules == [Chosen.TestGenServer]

      # Test count_children
      counts = Chosen.count_children(:basic004_sup)
      assert counts.specs == 1
      assert counts.active == 1
      assert counts.workers == 1
      assert counts.supervisors == 0

      Supervisor.stop(:basic004_sup)
    end
  end
end
