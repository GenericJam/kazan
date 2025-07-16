defmodule Kazan.Watcher do
  @moduledoc """

  Watches for changes on a resource.  This works by creating a Req request with streaming.
  The request will eventually timeout, however the Watcher handles recreating the request
  when this occurs and requesting new events that have occurred since the last *resource_version*
  received.

  To use:

  1. Create a request in the normal way that supports the `watch` parameter.  Alternatively
  create a watch request.
  ```
  request = Kazan.Apis.Core.V1.list_namespace!() # No need to add watch: true
  ```
  or
  ```
  request = Kazan.Apis.Core.V1.watch_namespace_list!()
  ```
  2. Start a watcher using the request, and passing the initial resource version
  and a pid to which to send received messages.
  ```
  Kazan.Watcher.start_link(request, resource_version: rv, send_to: self())
  ```
  If no `resource_version` is passed then the watcher initially makes a normal
  request to get the starting value.  This will only work if a non `watch` request
  is used. i.e. `Kazan.Apis.Core.V1.list_namespace!()`
  rather than `Kazan.Apis.Core.V1.watch_namespace_list!()`

  3. In your client code you receive messages for each `%Watcher.Event{}`.
    You can pattern match on the object type if you have multiple watchers configured.
    For example, if the client is a `GenServer`
  ```
    # type is `:added`, `:deleted`, `:modified` or `:gone`
    def handle_info(%Watcher.Event{object: object, from: watcher_pid, type: type}, state) do
      case object do
        %Kazan.Apis.Core.V1.Namespace{} = namespace ->
          process_namespace_event(type, namespace)

        %Kazan.Apis.Batch.V1.Job{} = job ->
          process_job_event(type, job)
      end
      {:noreply, state}
    end
  ```

  4. In the case that a `%Watcher.Event{type: type}` is received, where `type` is either `:gone`
     or `:expired`, then this indicates that Kubernetes has sent a 410 error. In this case the
     Watcher will automatically terminate and the consumer must clear its cache, reload any
     cached resources and restart the watcher.

  A Watcher can be terminated by calling `stop_watch/1`.
  """

  use GenServer
  alias Kazan.LineBuffer
  require Logger

  defmodule State do
    @moduledoc """
    Stores the internal state of the watcher.

     Includes:

     resource_version:

     The K8S *resource_version* (RV) is used to version each change in the cluster.
     When we listen for events we need to specify the RV to start listening from.
     For each event received we also receive a new RV, which we store in state.
     When the watch eventually times-out (it is an HTTP request with a chunked response),
     we can then create a new request passing the latest RV that was received.

     buffer:

     Chunked HTTP responses are not always a complete line, so we must buffer them
     until we have a complete line before parsing.
    """

    defstruct id: nil,
              request: nil,
              send_to: nil,
              name: nil,
              buffer: nil,
              rv: nil,
              client_opts: [],
              log_level: false,
              request_ref: nil
  end

  defmodule Event do
    defstruct [:type, :object, :from]
  end

  @doc """
  Starts a watch request to the kube server

  The server should be set in the kazan config or provided in the options.

  ### Options

  * `send_to` - A `pid` to which events are sent.  Defaults to `self()`.
  * `resource_version` - The version from which to start watching.
  * `name` - An optional name for the watcher.  Displayed in logs.
  * `log` - the level to log. When false, disables watcher logging.
  * Other options are passed directly to `Kazan.Client.run/2`
  """
  def start_link(%Kazan.Request{} = request, opts) do
    {send_to, opts} = Keyword.pop(opts, :send_to, self())
    GenServer.start_link(__MODULE__, [request, send_to, opts])
  end

  @doc "Stops the watch and terminates the process"
  def stop_watch(pid) do
    try do
      GenServer.call(pid, :stop_watch)
    catch
      :exit, {:noproc, _} -> :already_stopped
    end
  end

  @impl GenServer
  def init([request, send_to, opts]) do
    {rv, opts} = Keyword.pop(opts, :resource_version)
    {name, opts} = Keyword.pop(opts, :name, inspect(self()))
    {log_level, opts} = Keyword.pop(opts, :log, false)

    state = %State{
      request: request,
      send_to: send_to,
      name: name,
      log_level: log_level,
      rv: rv,
      client_opts: opts,
      buffer: LineBuffer.new()
    }

    Process.monitor(send_to)

    # Start the streaming request
    send(self(), :start_stream)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:stop_watch, _from, %State{} = state) do
    log(state, "Stopping watch #{inspect(self())}")
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_info(:start_stream, %State{} = state) do
    case start_streaming_request(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        log(state, "Failed to start streaming: #{inspect(reason)}")
        # Retry after a delay
        Process.send_after(self(), :start_stream, 5000)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(
        {:req_async, _request_ref, {:data, data}},
        %State{} = state
      ) do
    # Process streaming data using correct LineBuffer API
    new_buffer = LineBuffer.add_chunk(state.buffer, data)
    {lines, final_buffer} = LineBuffer.get_lines(new_buffer)
    new_state = %{state | buffer: final_buffer}

    Enum.each(lines, fn line ->
      case decode_watch_event(line) do
        {:ok, event} ->
          send_event(state.send_to, event, self())
          # Update resource version if available
          case extract_rv(event.object) do
            rv when is_binary(rv) -> send(self(), {:set_rv, rv})
            _ -> :ok
          end

        {:error, reason} ->
          log(state, "Failed to decode event: #{inspect(reason)}")
      end
    end)

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(
        {:req_async, _request_ref, {:end, _headers}},
        %State{} = state
      ) do
    log(state, "Stream ended, restarting...")
    # Restart stream after brief delay
    Process.send_after(self(), :start_stream, 1000)
    {:noreply, %{state | buffer: LineBuffer.new(), request_ref: nil}}
  end

  @impl GenServer
  def handle_info(
        {:req_async, _request_ref, {:error, reason}},
        %State{} = state
      ) do
    log(state, "Stream error: #{inspect(reason)}")
    # Restart stream after brief delay
    Process.send_after(self(), :start_stream, 5000)
    {:noreply, %{state | buffer: LineBuffer.new(), request_ref: nil}}
  end

  @impl GenServer
  def handle_info({:set_rv, rv}, state) do
    {:noreply, %{state | rv: rv}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %State{} = state) do
    %State{name: name} = state

    log(
      state,
      "#{inspect(self())} - #{name} send_to process #{inspect(pid)} :DOWN reason: #{inspect(reason)}"
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Helper functions for streaming implementation

  defp start_streaming_request(%State{} = state) do
    %{request: request, rv: rv, client_opts: opts} = state

    # Add watch=true and resource version to query params
    query_params = Map.put(request.query_params, "watch", "true")

    query_params =
      case rv do
        nil -> query_params
        rv -> Map.put(query_params, "resourceVersion", rv)
      end

    streaming_request = %{request | query_params: query_params}

    # Use Kazan with async streaming
    case Kazan.run(streaming_request, [{:stream_to, self()} | opts]) do
      {:ok, :stream_started} ->
        log(state, "Started streaming watch request")
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_watch_event(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type, "object" => object}} ->
        decoded_object =
          case Kazan.Models.decode(object) do
            {:ok, model} -> model
            _ -> object
          end

        event_type =
          case type do
            "ADDED" -> :added
            "DELETED" -> :deleted
            "MODIFIED" -> :modified
            "ERROR" -> :error
            "GONE" -> :gone
            _ -> :unknown
          end

        {:ok, %Event{type: event_type, object: decoded_object}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_event(pid, event, from) do
    send(pid, %Event{event | from: from})
  end

  defp extract_rv(%{
         "code" => 410,
         "kind" => "Status",
         "reason" => "Gone",
         "status" => "Failure",
         "message" => message
       }),
       do: {:gone, message}

  defp extract_rv(%{
         "code" => 410,
         "kind" => "Status",
         "reason" => "Expired",
         "status" => "Failure",
         "message" => message
       }),
       do: {:expired, message}

  defp extract_rv(%{"metadata" => %{"resourceVersion" => rv}}), do: rv
  defp extract_rv(%{metadata: %{resource_version: rv}}), do: rv
  defp extract_rv(_), do: nil

  defp log(%State{log_level: log_level}, msg), do: log(log_level, msg)
  defp log(false, _), do: :ok

  defp log(log_level, msg) do
    Logger.log(log_level, fn -> msg end)
  end
end
