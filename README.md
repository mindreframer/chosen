# Chosen

[![CI](https://github.com/mindreframer/chosen/actions/workflows/ci.yml/badge.svg)](https://github.com/mindreframer/chosen/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/chosen.svg)](https://hex.pm/packages/chosen)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/chosen)

**Distributed singleton supervisor backed by PostgreSQL advisory locks**

Chosen ensures a process or supervisor runs exactly once across your entire cluster—no BEAM clustering required.

## Quick Start

```elixir
# mix.exs
def deps do
  [{:chosen, "~> 0.1.0"}]
end
```

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Chosen.LockManager, repo: MyApp.Repo},
    {Chosen, child: MyApp.SingletonWorker, name: :my_singleton}
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

That's it. `MyApp.SingletonWorker` now runs once globally, even across multiple nodes.

## How It Works

Chosen uses PostgreSQL advisory locks to guarantee global uniqueness:

1. On startup, Chosen attempts to acquire a lock via the shared `LockManager`
2. The winner starts and supervises the child process
3. Losers wait for their turn, polling at configurable intervals
4. If the lock holder dies or loses connection, the lock is released automatically
5. The next instance immediately acquires the lock and starts the child

**Key guarantee:** Only one instance runs at a time, cluster-wide.

## Configuration

### Basic Usage

```elixir
{Chosen, child: MyWorker}
```

### With Options

```elixir
{Chosen, [
  child: {MyWorker, arg},              # Required: child spec
  name: :my_chosen,                     # Optional: lock identifier (default: Chosen)
  sup_name: :my_sup,                    # Optional: supervisor name for which_children/1
  polling_interval: 1000,               # Optional: retry interval in ms (default: 500)
  lock_manager_name: :my_lock_manager   # Optional: LockManager instance (default: Chosen.LockManager)
]}
```

### Multiple Singletons

```elixir
children = [
  {Chosen.LockManager, repo: MyApp.Repo},
  {Chosen, child: WorkerA, name: :singleton_a},
  {Chosen, child: WorkerB, name: :singleton_b},
  {Chosen, child: WorkerC, name: :singleton_c}
]
```

Each gets its own advisory lock. All share the same database connection via `LockManager`.

### Multiple LockManagers

```elixir
children = [
  {Chosen.LockManager, [repo: RepoA, name: :lock_mgr_a]},
  {Chosen.LockManager, [repo: RepoB, name: :lock_mgr_b]},
  {Chosen, [child: Worker1, lock_manager_name: :lock_mgr_a]},
  {Chosen, [child: Worker2, lock_manager_name: :lock_mgr_b]}
]
```

Use when you need singletons across different databases.

### Direct Connection Options

```elixir
{Chosen.LockManager, [
  connect_opts: [
    hostname: "localhost",
    username: "postgres",
    password: "postgres",
    database: "my_db"
  ]
]}
```

## Accessing Your Singleton

Use Erlang's `:global` registry to find your process:

```elixir
# When starting your worker
GenServer.start_link(MyWorker, args, name: {:global, :my_worker})

# From anywhere
pid = :global.whereis_name(:my_worker)
GenServer.call(pid, :get_state)
```

Or use Registry, Horde, or any other process registry.

## Supervisor Semantics

Chosen behaves like a supervisor:

```elixir
Chosen.which_children(:my_sup)
#=> [{:my_worker, #PID<0.123.0>, :worker, [MyWorker]}]

Chosen.count_children(:my_sup)
#=> %{active: 1, specs: 1, supervisors: 0, workers: 1}
```

## Why Chosen?

| Feature | `:global` + Clustering | Chosen |
|---------|----------------------|--------|
| Single instance guarantee | ✓ | ✓ |
| Requires BEAM clustering | ✓ | ✗ |
| Works on Heroku/Lambda | ✗ | ✓ |
| Network partition safety | ✗ | ✓ |
| Split-brain resilience | ✗ | ✓ |
| Connection efficiency | N/A | ✓ |

**Trade-off:** If PostgreSQL becomes unavailable, singletons shut down. This is by design—better zero instances than multiple instances.

## Architecture

- **Chosen** – The supervisor wrapper for your singleton process
- **Chosen.LockManager** – Shared connection pool that manages all advisory locks
- **Advisory Locks** – PostgreSQL's built-in distributed locking primitive

One `LockManager` per VM handles all Chosen instances, reducing connection count from N to 1.

## License

MIT

## Credits

Inspired by [HighlanderPG](https://github.com/derekkraan/highlander_pg)
