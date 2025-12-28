# Start the test Repo
{:ok, _} = Chosen.TestRepo.start_link()

# Start a default LockManager for tests that need it
# Individual tests can start their own named LockManagers if needed
{:ok, _} =
  Chosen.LockManager.start_link(
    connect_opts: Chosen.TestConfig.db_config(),
    name: Chosen.LockManager
  )

# Start ExUnit
# By default, do NOT capture logs - we want to see unexpected errors
# Individual tests can use @tag capture_log: true for expected noisy output
ExUnit.start(
  capture_log: false,
  trace: false,
  max_cases: System.schedulers_online()
)
