ExUnit.start()
ExUnit.configure(capture_log: true, exclude: [:integration])

# Start required applications for testing
Application.ensure_all_started(:cowboy)
Application.ensure_all_started(:plug_cowboy)
{:ok, _} = Application.ensure_all_started(:bypass)
