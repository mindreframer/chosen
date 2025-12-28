defmodule Chosen.LockManager do
  @moduledoc """
  Centralized advisory lock coordination system for Chosen.

  Provides a shared PostgreSQL connection pool manager that handles all advisory 
  lock operations, significantly reducing database connection overhead by 
  consolidating N connections (one per Chosen instance) into a single connection 
  per VM.

  ## System Architecture

  The LockManager orchestrates:
  - Single persistent Postgrex database connection
  - Lock acquisition and release operations for multiple Chosen instances
  - Automatic process monitoring with lock cleanup on termination
  - Intelligent polling mechanism for lock contention scenarios
  - Centralized observability for distributed lock states

  ## State Persistence

  Lock ownership tracking includes process monitoring for automatic cleanup.
  Queued lock requests are maintained with configurable retry intervals.
  """

  use GenServer
  require Logger

  # Internal state representation
  defstruct [:conn, locks: %{}, pending: %{}]

  # Type definitions for internal lock tracking
  @type lock_key :: {integer(), integer()}
  @type lock_info :: %{
          owner: pid(),
          monitor_ref: reference(),
          name: term()
        }
  @type pending_request :: %{
          from: pid(),
          monitor_ref: reference(),
          timer_ref: reference() | nil,
          polling_interval: integer()
        }

  ## Public Client Interface

  @doc """
  Initializes and starts the LockManager GenServer.

  Configuration options:
  - `:connect_opts` - Direct Postgrex connection parameters (optional)
  - `:repo` - Ecto repository for extracting connection settings (optional)
  - `:name` - Process registration name (defaults to: __MODULE__)
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Requests acquisition of an advisory lock (asynchronous operation).

  The requesting process receives a `:got_lock` message upon successful acquisition.
  When a lock is contested, requests enter a queue with periodic retry attempts
  governed by the polling_interval parameter.

  Returns `:ok` immediately - actual lock acquisition happens asynchronously.
  """
  @spec request_lock(GenServer.server(), term(), integer()) :: :ok
  def request_lock(server \\ __MODULE__, name, polling_interval \\ 300) do
    GenServer.cast(server, {:request_lock, self(), name, polling_interval})
  end

  @doc """
  Releases a previously acquired advisory lock.

  Pending requests for the same lock are automatically processed in queue order.
  """
  @spec release_lock(GenServer.server(), term()) :: :ok
  def release_lock(server \\ __MODULE__, name) do
    GenServer.call(server, {:release_lock, name})
  end

  @doc """
  Retrieves all active locks for debugging and monitoring purposes.

  Returns a mapping from lock keys to their associated lock information.
  """
  @spec list_locks(GenServer.server()) :: %{lock_key() => lock_info()}
  def list_locks(server \\ __MODULE__) do
    GenServer.call(server, :list_locks)
  end

  @doc """
  Queries the database connection health status.

  Useful for system health checks and monitoring.
  """
  @spec connection_status(GenServer.server()) :: :connected | :disconnected
  def connection_status(server \\ __MODULE__) do
    GenServer.call(server, :connection_status)
  end

  ## GenServer Callback Implementation

  @impl GenServer
  def init(opts) do
    # Enable exit trapping for graceful shutdown with cleanup
    Process.flag(:trap_exit, true)

    # Extract database connection configuration
    repo = Keyword.get(opts, :repo, nil)
    connect_opts = Keyword.get(opts, :connect_opts, [])

    # Validate connection parameters
    if repo == nil and connect_opts == [] do
      raise ArgumentError, "expected one of `repo` or `connect_opts`, got neither"
    end

    # Determine final connection options
    connection_opts =
      if repo do
        repo.config()
      else
        connect_opts
      end

    state = %__MODULE__{}

    # Establish PostgreSQL connection
    case Postgrex.start_link(connection_opts) do
      {:ok, conn} ->
        {:ok, %{state | conn: conn}}

      {:error, reason} ->
        Logger.error("LockManager failed to connect to PostgreSQL: #{inspect(reason)}")
        {:stop, {:connection_failed, reason}}
    end
  end

  @impl GenServer
  def handle_cast({:request_lock, from_pid, name, polling_interval}, state) do
    lock_key = lock_key(name)

    case Map.get(state.locks, lock_key) do
      nil ->
        # Lock not currently tracked - check if we can acquire it
        # Note: We must check state.locks first because advisory locks are re-entrant
        # within a session, so pg_try_advisory_lock would succeed even if we already
        # hold the lock for a different Chosen instance
        case try_acquire_lock(state.conn, lock_key) do
          {:ok, true} ->
            # Successfully acquired lock
            monitor_ref = Process.monitor(from_pid)

            lock_info = %{
              owner: from_pid,
              monitor_ref: monitor_ref,
              name: name
            }

            # Notify requesting process
            send(from_pid, :got_lock)

            {:noreply, %{state | locks: Map.put(state.locks, lock_key, lock_info)}}

          {:ok, false} ->
            # Lock contested by external process - queue for retry
            state = add_pending_request(state, lock_key, from_pid, polling_interval)
            {:noreply, state}

          {:error, reason} ->
            Logger.error("Failed to acquire lock for #{inspect(name)}: #{inspect(reason)}")
            # Skip queueing on database error
            {:noreply, state}
        end

      _lock_info ->
        # Lock already held by another Chosen instance - add to pending queue
        state = add_pending_request(state, lock_key, from_pid, polling_interval)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call({:release_lock, name}, _from, state) do
    lock_key = lock_key(name)

    case Map.get(state.locks, lock_key) do
      nil ->
        # Lock not found - already released or never acquired
        {:reply, :ok, state}

      lock_info ->
        # Clean up process monitor
        Process.demonitor(lock_info.monitor_ref, [:flush])

        # Execute database unlock operation
        case release_lock_internal(state.conn, lock_key) do
          {:ok, _} ->
            state = %{state | locks: Map.delete(state.locks, lock_key)}
            # Trigger processing of queued requests
            state = process_next_pending(state, lock_key)
            {:reply, :ok, state}

          {:error, reason} ->
            Logger.error("Failed to release lock for #{inspect(name)}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:list_locks, _from, state) do
    {:reply, state.locks, state}
  end

  def handle_call(:connection_status, _from, state) do
    status = if Process.alive?(state.conn), do: :connected, else: :disconnected
    {:reply, status, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    # Automatic cleanup: release locks from terminated processes
    {released_keys, remaining_locks} =
      Enum.reduce(state.locks, {[], %{}}, fn {key, lock_info}, {released, remaining} ->
        if lock_info.monitor_ref == monitor_ref do
          # Identified lock owned by dead process - release it
          case release_lock_internal(state.conn, key) do
            {:ok, _} ->
              Logger.debug("Auto-released lock #{inspect(key)} for dead process #{inspect(pid)}")

              {[key | released], remaining}

            {:error, reason} ->
              Logger.error(
                "Failed to auto-release lock #{inspect(key)} for dead process: #{inspect(reason)}"
              )

              {released, Map.put(remaining, key, lock_info)}
          end
        else
          {released, Map.put(remaining, key, lock_info)}
        end
      end)

    # Clean up pending requests from terminated process
    {_pending_pids, remaining_pending} =
      Enum.reduce(state.pending, {[], %{}}, fn {key, requests}, {pids, remaining} ->
        updated_requests =
          Enum.filter(requests, fn req ->
            if req.monitor_ref == monitor_ref do
              # Cancel scheduled retry timer
              if req.timer_ref, do: Process.cancel_timer(req.timer_ref)
              false
            else
              true
            end
          end)

        new_remaining =
          if updated_requests == [] do
            remaining
          else
            Map.put(remaining, key, updated_requests)
          end

        {pids, new_remaining}
      end)

    state = %{state | locks: remaining_locks, pending: remaining_pending}

    # Activate next queued request for each newly available lock
    state =
      Enum.reduce(released_keys, state, fn key, acc ->
        process_next_pending(acc, key)
      end)

    {:noreply, state}
  end

  def handle_info({:retry_lock, lock_key, from_pid}, state) do
    # Validate request still exists in pending queue
    case Map.get(state.pending, lock_key) do
      nil ->
        # Lock released or request cancelled
        {:noreply, state}

      requests ->
        case Enum.find(requests, fn req -> req.from == from_pid end) do
          nil ->
            # Request no longer pending (process died or lock acquired)
            {:noreply, state}

          request ->
            # Check if lock is still held by another process
            case Map.get(state.locks, lock_key) do
              nil ->
                # Lock is free - attempt acquisition
                case try_acquire_lock(state.conn, lock_key) do
                  {:ok, true} ->
                    # Success! Transition from pending to active locks
                    remaining_requests = Enum.reject(requests, fn req -> req.from == from_pid end)

                    state =
                      if remaining_requests == [] do
                        %{state | pending: Map.delete(state.pending, lock_key)}
                      else
                        %{state | pending: Map.put(state.pending, lock_key, remaining_requests)}
                      end

                    # Reuse existing monitor reference from pending request
                    lock_info = %{
                      owner: from_pid,
                      monitor_ref: request.monitor_ref,
                      name: reverse_lock_key(lock_key)
                    }

                    send(from_pid, :got_lock)

                    {:noreply, %{state | locks: Map.put(state.locks, lock_key, lock_info)}}

                  {:ok, false} ->
                    # Lock still contested by external process - schedule next retry
                    timer_ref =
                      Process.send_after(
                        self(),
                        {:retry_lock, lock_key, from_pid},
                        request.polling_interval
                      )

                    updated_request = %{request | timer_ref: timer_ref}

                    updated_requests =
                      Enum.map(requests, fn req ->
                        if req.from == from_pid, do: updated_request, else: req
                      end)

                    {:noreply,
                     %{state | pending: Map.put(state.pending, lock_key, updated_requests)}}

                  {:error, reason} ->
                    Logger.error(
                      "Failed to retry lock acquisition for #{inspect(lock_key)}: #{inspect(reason)}"
                    )

                    {:noreply, state}
                end

              _lock_info ->
                # Lock still held by another Chosen instance - schedule retry
                timer_ref =
                  Process.send_after(
                    self(),
                    {:retry_lock, lock_key, from_pid},
                    request.polling_interval
                  )

                updated_request = %{request | timer_ref: timer_ref}

                updated_requests =
                  Enum.map(requests, fn req ->
                    if req.from == from_pid, do: updated_request, else: req
                  end)

                {:noreply, %{state | pending: Map.put(state.pending, lock_key, updated_requests)}}
            end
        end
    end
  end

  def handle_info({:EXIT, conn_pid, reason}, %{conn: conn_pid} = state) do
    Logger.error("PostgreSQL connection died: #{inspect(reason)}")
    {:stop, {:connection_lost, reason}, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Cleanup: release all active locks
    Enum.each(state.locks, fn {key, _info} ->
      release_lock_internal(state.conn, key)
    end)

    # Cleanup: cancel all pending retry timers
    Enum.each(state.pending, fn {_key, requests} ->
      Enum.each(requests, fn req ->
        if req.timer_ref, do: Process.cancel_timer(req.timer_ref)
      end)
    end)

    :ok
  end

  ## Internal Helper Functions

  # Generates a tuple-based lock key from arbitrary term
  # Uses consistent hashing for PostgreSQL advisory lock compatibility
  defp lock_key(name) do
    {1, :erlang.phash2(name)}
  end

  # Attempts reverse mapping of lock key (lossy due to hashing)
  # Actual name is preserved in lock_info structure
  defp reverse_lock_key({_classid, objid}) do
    # Hash reversal not possible - this is a placeholder
    # Real name stored in lock_info during acquisition
    {:hashed, objid}
  end

  # Attempts non-blocking lock acquisition via PostgreSQL advisory lock
  defp try_acquire_lock(conn, {classid, objid}) do
    query = "SELECT pg_try_advisory_lock($1, $2)"

    case Postgrex.query(conn, query, [classid, objid]) do
      {:ok, %{rows: [[result]]}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # Releases PostgreSQL advisory lock
  defp release_lock_internal(conn, {classid, objid}) do
    query = "SELECT pg_advisory_unlock($1, $2)"

    case Postgrex.query(conn, query, [classid, objid]) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # Adds a new lock request to the pending queue
  # Sets up process monitoring and schedules initial retry
  defp add_pending_request(state, lock_key, from_pid, polling_interval) do
    monitor_ref = Process.monitor(from_pid)

    timer_ref =
      Process.send_after(self(), {:retry_lock, lock_key, from_pid}, polling_interval)

    request = %{
      from: from_pid,
      monitor_ref: monitor_ref,
      timer_ref: timer_ref,
      polling_interval: polling_interval
    }

    current_requests = Map.get(state.pending, lock_key, [])
    updated_requests = [request | current_requests]

    %{state | pending: Map.put(state.pending, lock_key, updated_requests)}
  end

  # Processes the next pending request for a given lock key
  # Triggers immediate retry for queue head when lock becomes available
  defp process_next_pending(state, lock_key) do
    case Map.get(state.pending, lock_key) do
      nil ->
        # No pending requests for this lock
        state

      [] ->
        # Empty queue - remove entry
        %{state | pending: Map.delete(state.pending, lock_key)}

      [next_request | _rest] ->
        # Fast-track next request by cancelling timer and retrying immediately
        if next_request.timer_ref, do: Process.cancel_timer(next_request.timer_ref)

        # Trigger immediate retry attempt
        send(self(), {:retry_lock, lock_key, next_request.from})

        # Request remains in pending until successful
        state
    end
  end
end
