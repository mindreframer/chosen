defmodule Chosen.ErrorReporter do
  @moduledoc false
  # Internal error reporting utilities for Chosen supervisor

  require Logger

  @doc """
  Reports supervisor-style errors for child process failures.
  """
  def report_error(error, reason, child, sup_name) do
    Logger.error(
      %{
        label: {:supervisor, reason},
        report: [
          supervisor: sup_name,
          errorContext: error,
          reason: reason,
          offender: extract_child(child)
        ]
      },
      %{
        domain: [:otp, :sasl],
        report_cb: &:supervisor.format_log/2,
        logger_formatter: %{title: "CHOSEN REPORT"},
        error_logger: %{
          tag: :error_report,
          type: :supervisor_report,
          report_db: &:supervisor.format_log/1
        }
      }
    )
  end

  defp extract_child(child) when is_list(child.pid) do
    [
      nb_children: length(child.pid),
      id: child.id,
      mfargs: child.start,
      restart_type: :undefined,
      significant: false,
      shutdown: child.shutdown,
      child_type: child.type
    ]
  end

  defp extract_child(child) do
    [
      pid: child.pid,
      id: child.id,
      mfargs: child.start,
      restart_type: :undefined,
      significant: false,
      shutdown: child.shutdown,
      child_type: child.type
    ]
  end
end
