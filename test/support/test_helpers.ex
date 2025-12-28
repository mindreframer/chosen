defmodule Chosen.TestHelpers do
  @moduledoc """
  Helper functions for Chosen tests.
  """

  @doc """
  Queries Postgres for advisory locks.
  Returns list of advisory locks with their keys.
  """
  def query_advisory_locks(key1 \\ 1) do
    {:ok, pid} = Postgrex.start_link(Chosen.TestConfig.db_config())

    query = """
    SELECT classid, objid, granted
    FROM pg_locks
    WHERE locktype = 'advisory'
      AND classid = $1
    """

    result = Postgrex.query!(pid, query, [key1])
    GenServer.stop(pid)

    result.rows
  end

  @doc """
  Count advisory locks for a specific key.
  """
  def count_advisory_locks(key1 \\ 1, key2) do
    {:ok, pid} = Postgrex.start_link(Chosen.TestConfig.db_config())

    query = """
    SELECT COUNT(*)
    FROM pg_locks
    WHERE locktype = 'advisory'
      AND classid = $1
      AND objid = $2
      AND granted = true
    """

    result = Postgrex.query!(pid, query, [key1, key2])
    GenServer.stop(pid)

    [[count]] = result.rows
    count
  end

  @doc """
  Acquire an advisory lock directly (for testing external lock holders).
  Returns the connection pid (must be kept alive to hold lock).
  """
  def acquire_advisory_lock(key1 \\ 1, key2) do
    {:ok, pid} = Postgrex.start_link(Chosen.TestConfig.db_config())
    Postgrex.query!(pid, "SELECT pg_advisory_lock($1, $2)", [key1, key2])
    pid
  end

  @doc """
  Release an advisory lock.
  """
  def release_advisory_lock(conn_pid, key1 \\ 1, key2) do
    Postgrex.query!(conn_pid, "SELECT pg_advisory_unlock($1, $2)", [key1, key2])
    GenServer.stop(conn_pid)
  end

  @doc """
  Wait until a condition is true, with timeout.
  Uses exponential backoff for efficient polling.
  """
  def wait_until(fun, timeout \\ 2000, initial_interval \\ 1) do
    wait_until_impl(fun, timeout, initial_interval, System.monotonic_time(:millisecond))
  end

  defp wait_until_impl(fun, timeout, interval, start_time) do
    if fun.() do
      :ok
    else
      current_time = System.monotonic_time(:millisecond)
      elapsed = current_time - start_time

      if elapsed >= timeout do
        {:error, :timeout}
      else
        Process.sleep(interval)
        # Exponential backoff: 1ms -> 2ms -> 4ms -> 8ms -> max 50ms
        next_interval = min(interval * 2, 50)
        wait_until_impl(fun, timeout, next_interval, start_time)
      end
    end
  end

  @doc """
  Wait for a global name to be registered and alive.
  More efficient than polling.
  """
  def wait_for_global_name(name, timeout \\ 2000) do
    wait_until(
      fn ->
        case :global.whereis_name(name) do
          :undefined -> false
          pid -> Process.alive?(pid)
        end
      end,
      timeout
    )
  end

  @doc """
  Wait for an advisory lock to be acquired.
  """
  def wait_for_lock(key1 \\ 1, key2, timeout \\ 2000) do
    wait_until(fn -> count_advisory_locks(key1, key2) == 1 end, timeout)
  end

  @doc """
  Wait for an advisory lock to be released.
  """
  def wait_for_lock_release(key1 \\ 1, key2, timeout \\ 2000) do
    wait_until(fn -> count_advisory_locks(key1, key2) == 0 end, timeout)
  end

  @doc """
  Count processes matching a specific module.
  """
  def count_processes(module) do
    Process.list()
    |> Enum.count(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          case Keyword.get(dict, :"$initial_call") do
            {^module, :init, _} -> true
            _ -> false
          end

        _ ->
          false
      end
    end)
  end

  @doc """
  Get the hash used by Chosen for a name.
  """
  def name_hash(name) do
    :erlang.phash2(name)
  end

  @doc """
  Start a Chosen instance with common test configuration.
  Requires a LockManager to be running.
  """
  def start_chosen(opts \\ []) do
    name = Keyword.get(opts, :name, Chosen)
    child = Keyword.get(opts, :child)
    sup_name = Keyword.get(opts, :sup_name)
    polling_interval = Keyword.get(opts, :polling_interval, 100)
    lock_manager_name = Keyword.get(opts, :lock_manager_name, Chosen.LockManager)

    unless child do
      raise ArgumentError, "must provide :child option"
    end

    chosen_opts = [
      child: child,
      name: name,
      polling_interval: polling_interval,
      lock_manager_name: lock_manager_name
    ]

    chosen_opts =
      if sup_name do
        Keyword.put(chosen_opts, :sup_name, sup_name)
      else
        chosen_opts
      end

    Chosen.start_link(chosen_opts)
  end
end
