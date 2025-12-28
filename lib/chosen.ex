defmodule Chosen do
  @moduledoc """
  Distributed singleton supervisor backed by PostgreSQL advisory locks.

  Ensures a child process or supervisor runs exactly once across your entire cluster.
  See README.md for usage examples and architecture details.
  """

  use GenServer, type: :supervisor

  alias Chosen.ErrorReporter

  defstruct [:child, :name, :polling_interval, :lock_manager_name, :has_lock]

  @type start_opt ::
          {:child, Supervisor.child_spec()}
          | {:name, term()}
          | {:sup_name, term()}
          | {:polling_interval, integer()}
          | {:lock_manager_name, GenServer.server()}

  @default_polling_interval 500

  @spec start_link([start_opt()]) :: Supervisor.on_start()
  @doc """
  Starts the Chosen supervisor.

  ## Options

  - `:child` - (required) Child spec to supervise as singleton
  - `:name` - (optional) Lock identifier, default: `Chosen`. Use unique names for multiple singletons
  - `:sup_name` - (optional) Supervisor name for `which_children/1` and `count_children/1`
  - `:polling_interval` - (optional) Lock retry interval in ms, default: #{@default_polling_interval}
  - `:lock_manager_name` - (optional) LockManager to use, default: `Chosen.LockManager`

  ## Example

      children = [
        {Chosen.LockManager, repo: MyApp.Repo},
        {Chosen, child: MyWorker, name: :my_singleton}
      ]

  See README.md for more examples.
  """
  def start_link(opts) do
    {child, opts} = Keyword.pop(opts, :child)

    {init_opts, start_opts} =
      gen_options(opts)

    GenServer.start_link(__MODULE__, {child, init_opts}, start_opts)
  end

  @spec which_children(Supervisor.supervisor()) :: [
          {term() | :undefined, Supervisor.child(), :worker | :supervisor, [module()] | :dynamic}
        ]
  @doc "Returns supervised children info (Supervisor.which_children/1 semantics)"
  def which_children(server) do
    GenServer.call(server, :which_children)
  end

  @spec count_children(Supervisor.supervisor()) :: %{
          specs: non_neg_integer(),
          active: non_neg_integer(),
          supervisors: non_neg_integer(),
          workers: non_neg_integer()
        }
  @doc "Returns supervised children count (Supervisor.count_children/1 semantics)"
  def count_children(server) do
    GenServer.call(server, :count_children)
  end

  defp gen_options(opts) do
    {_init_opts, _options} =
      case Keyword.pop(opts, :sup_name) do
        {nil, init_opts} -> {init_opts, []}
        {name, init_opts} -> {init_opts, [name: name]}
      end
  end

  @impl GenServer
  def init({child, init_opts}) do
    Process.flag(:trap_exit, true)

    polling_interval = Keyword.get(init_opts, :polling_interval, @default_polling_interval)
    lock_manager_name = Keyword.get(init_opts, :lock_manager_name, Chosen.LockManager)
    name = Keyword.get(init_opts, :name, __MODULE__)
    child = Chosen.Supervisor.handle_child_spec(child) |> Map.put(:pid, :undefined)

    state = %__MODULE__{
      child: child,
      name: name,
      polling_interval: polling_interval,
      lock_manager_name: lock_manager_name,
      has_lock: false
    }

    {:ok, state, {:continue, :init}}
  end

  @impl GenServer
  def handle_continue(:init, state) do
    {:ok, state} = connect(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:count_children, _ref, state) do
    reply =
      cond do
        state.child.pid == :undefined ->
          %{active: 0, supervisors: 0, workers: 0, specs: 1}

        state.child.type == :worker ->
          %{active: 1, supervisors: 0, workers: 1, specs: 1}

        state.child.type == :supervisor ->
          %{active: 1, supervisors: 1, workers: 0, specs: 1}
      end

    {:reply, reply, state}
  end

  def handle_call(:which_children, _ref, state) do
    modules =
      case state.child do
        %{modules: modules} -> modules
        %{start: {m, _f, _a}} -> [m]
      end

    children = [{state.child.id, state.child.pid, state.child.type, modules}]
    {:reply, children, state}
  end

  @impl GenServer
  def handle_info(:got_lock, state) do
    case start_child(state.child, state) do
      {:ok, child} ->
        {:noreply, %{state | child: child, has_lock: true}}

      :abort ->
        {:stop, :shutdown, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :shutdown, state}
  end

  defp connect(state) do
    Chosen.LockManager.request_lock(
      state.lock_manager_name,
      state.name,
      state.polling_interval
    )

    {:ok, state}
  end

  defp start_child(child, state) do
    {m, f, a} = child.start

    case apply(m, f, a) do
      {:ok, pid} when is_pid(pid) ->
        {:ok, Map.put(child, :pid, pid)}

      {:error, reason} ->
        ErrorReporter.report_error(:start_error, reason, child, state.name)
        :abort
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    Chosen.Supervisor.shutdown(state.child)

    if state.has_lock do
      try do
        Chosen.LockManager.release_lock(state.lock_manager_name, state.name)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
