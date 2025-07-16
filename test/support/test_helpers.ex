defmodule Kazan.TestHelpers do
  @moduledoc """
  Helper functions for robust integration testing with namespace isolation
  and eventually consistent patterns.
  """

  alias Kazan.Apis.Core.V1, as: CoreV1
  alias Kazan.Models.Apimachinery.Meta.V1.{ObjectMeta, DeleteOptions}

  @doc """
  Creates a unique test namespace and ensures it's ready.
  Returns the namespace name.
  """
  def create_test_namespace(server) do
    namespace_name = "test-#{System.unique_integer([:positive])}"

    namespace = %Kazan.Apis.Core.V1.Namespace{
      metadata: %ObjectMeta{name: namespace_name}
    }

    CoreV1.create_namespace!(namespace)
    |> Kazan.run!(server: server)

    # Wait for namespace to be ready
    wait_for_condition(
      fn ->
        case CoreV1.read_namespace!(namespace_name)
             |> Kazan.run(server: server) do
          {:ok, %{status: %{phase: "Active"}}} -> true
          _ -> false
        end
      end,
      "Namespace #{namespace_name} to be ready"
    )

    namespace_name
  end

  @doc """
  Deletes a test namespace and all its resources.
  Waits for complete deletion to ensure clean state.
  """
  def delete_test_namespace(namespace_name, server) do
    # Delete the namespace (cascades to all resources within)
    try do
      CoreV1.delete_namespace!(%DeleteOptions{}, namespace_name)
      |> Kazan.run!(server: server)
    rescue
      # Already deleted
      Kazan.RemoteError -> :ok
    end

    # Wait for namespace to be completely gone
    wait_for_condition(
      fn ->
        case CoreV1.read_namespace!(namespace_name)
             |> Kazan.run(server: server) do
          {:error, {:http_error, 404, _}} -> true
          _ -> false
        end
      end,
      "Namespace #{namespace_name} to be deleted",
      timeout: 30_000
    )
  end

  @doc """
  Waits for a condition to be true with configurable timeout and retry interval.
  """
  def wait_for_condition(condition_fn, description, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    interval = Keyword.get(opts, :interval, 200)
    end_time = System.monotonic_time(:millisecond) + timeout

    wait_for_condition_loop(condition_fn, description, end_time, interval)
  end

  defp wait_for_condition_loop(condition_fn, description, end_time, interval) do
    if System.monotonic_time(:millisecond) > end_time do
      raise "Timeout waiting for #{description}"
    end

    if condition_fn.() do
      :ok
    else
      Process.sleep(interval)
      wait_for_condition_loop(condition_fn, description, end_time, interval)
    end
  end

  @doc """
  Eventually consistent assertion that retries until condition is met.
  """
  defmacro assert_eventually(condition, opts \\ []) do
    quote do
      timeout = Keyword.get(unquote(opts), :timeout, 5_000)
      interval = Keyword.get(unquote(opts), :interval, 100)

      Kazan.TestHelpers.wait_for_condition(
        fn ->
          try do
            unquote(condition)
          rescue
            _ -> false
          end
        end,
        "assertion condition",
        timeout: timeout,
        interval: interval
      )
    end
  end

  @doc """
  Waits for a pod to reach a specific phase.
  """
  def wait_for_pod_phase(
        namespace,
        pod_name,
        expected_phase,
        server,
        opts \\ []
      ) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    wait_for_condition(
      fn ->
        case CoreV1.read_namespaced_pod!(namespace, pod_name)
             |> Kazan.run(server: server) do
          {:ok, %{status: %{phase: ^expected_phase}}} ->
            true

          {:error, {:http_error, 404, _}} when expected_phase == "Deleted" ->
            true

          _ ->
            false
        end
      end,
      "Pod #{pod_name} to reach phase #{expected_phase}",
      timeout: timeout
    )
  end

  @doc """
  Waits for a resource to be fully updated after a patch operation.
  Compares resource versions to ensure we have the latest state.
  """
  def wait_for_resource_update(
        get_resource_fn,
        original_resource_version,
        opts \\ []
      ) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    wait_for_condition(
      fn ->
        case get_resource_fn.() do
          {:ok, resource} ->
            resource.metadata.resource_version != original_resource_version

          _ ->
            false
        end
      end,
      "Resource to be updated",
      timeout: timeout
    )
  end

  @doc """
  Cleans up any leftover test namespaces (in case of test failures).
  """
  def cleanup_test_namespaces(server) do
    case CoreV1.list_namespace!() |> Kazan.run(server: server) do
      {:ok, namespace_list} ->
        test_namespaces =
          namespace_list.items
          |> Enum.filter(fn ns ->
            String.starts_with?(ns.metadata.name, "test-")
          end)

        Enum.each(test_namespaces, fn ns ->
          delete_test_namespace(ns.metadata.name, server)
        end)

      _ ->
        :ok
    end
  end
end
