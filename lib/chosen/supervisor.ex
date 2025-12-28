defmodule Chosen.Supervisor do
  @moduledoc false

  # Default child specification settings
  @default_child_spec %{type: :worker, restart: :permanent}

  # Normalizes and enriches child specifications with defaults
  # Ensures proper shutdown timeouts based on process type
  def handle_child_spec(child_spec) do
    # Convert to standard supervisor child spec format
    child_spec = Supervisor.child_spec(child_spec, [])

    # Apply default values for unspecified fields
    child_spec = Map.merge(@default_child_spec, child_spec)

    # Determine appropriate shutdown timeout
    shutdown =
      case child_spec do
        %{shutdown: shutdown} -> shutdown
        %{type: :worker} -> 5000
        %{type: :supervisor} -> :infinity
      end

    Map.put(child_spec, :shutdown, shutdown)
  end

  # Terminates a child process using brutal kill strategy
  def shutdown(%{pid: pid, shutdown: :brutal_kill}) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    end
  end

  # Terminates a child process with graceful shutdown timeout
  # Falls back to brutal kill if timeout expires
  def shutdown(%{pid: pid, shutdown: time}) when is_pid(pid) do
    monitor = Process.monitor(pid)
    # Attempt graceful shutdown
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    after
      time ->
        # Timeout expired - force kill
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} ->
            :ok
        end
    end
  end

  # No-op for undefined or already terminated processes
  def shutdown(_), do: :ok
end
