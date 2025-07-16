defmodule KazanIntegrationTest do
  use ExUnit.Case, async: false
  import Kazan.TestHelpers

  alias Kazan.Apis.Core.V1, as: CoreV1
  alias Kazan.Apis.Apps.V1, as: AppsV1
  alias Kazan.Apis.Rbacauthorization.V1, as: RbacauthorizationV1
  alias Kazan.Apis.Core.V1.{Pod, PodStatus, PodSpec, Container}

  alias Kazan.Models.Apimachinery.Meta.V1.{
    ObjectMeta,
    DeleteOptions
  }

  @moduletag :integration

  setup_all do
    kubeconfig = System.get_env("KUBECONFIG")

    unless kubeconfig do
      raise "KUBECONFIG environment variable must be set to run integration tests"
    end

    server = Kazan.Server.from_kubeconfig(kubeconfig)

    # Clean up any leftover test namespaces from previous runs
    cleanup_test_namespaces(server)

    {:ok, %{server: server}}
  end

  setup %{server: server} do
    # Create unique namespace for this test
    namespace = create_test_namespace(server)

    # Ensure cleanup happens regardless of test outcome
    on_exit(fn ->
      delete_test_namespace(namespace, server)
    end)

    {:ok, %{namespace: namespace}}
  end

  test "can list namespaces on an actual server", %{server: server} do
    namespace_list =
      CoreV1.list_namespace!()
      |> Kazan.run!(server: server)

    # Check that there's a default namespace.
    assert Enum.find(namespace_list.items, fn namespace ->
             namespace.metadata.name == "default"
           end)
  end

  test "can list pods on an actual server", %{
    server: server,
    namespace: namespace
  } do
    CoreV1.list_namespaced_pod!(namespace)
    |> Kazan.run!(server: server)
  end

  test "can list deployments on an actual server", %{
    server: server,
    namespace: namespace
  } do
    AppsV1.list_namespaced_deployment!(namespace)
    |> Kazan.run!(server: server)
  end

  test "can create, patch and delete a pod", %{
    server: server,
    namespace: namespace
  } do
    created_pod = create_pod("kazan-test", namespace, server: server)

    read_pod =
      CoreV1.read_namespaced_pod!(namespace, "kazan-test")
      |> Kazan.run!(server: server)

    assert read_pod.spec == %{
             created_pod.spec
             | node_name: read_pod.spec.node_name
           }

    original_resource_version = read_pod.metadata.resource_version
    _patched_pod = patch_pod("kazan-test", namespace, server: server)

    # Wait for the patch to be fully applied
    wait_for_resource_update(
      fn ->
        CoreV1.read_namespaced_pod!(namespace, "kazan-test")
        |> Kazan.run(server: server)
      end,
      original_resource_version
    )

    # Now read the updated pod
    updated_pod =
      CoreV1.read_namespaced_pod!(namespace, "kazan-test")
      |> Kazan.run!(server: server)

    assert updated_pod.spec.active_deadline_seconds == 1

    delete_pod("kazan-test", namespace, server: server)
  end

  test "RBAC Authorization V1 API", %{server: server} do
    cluster_roles =
      RbacauthorizationV1.list_cluster_role!()
      |> Kazan.run!(server: server)

    assert cluster_roles.kind == "ClusterRoleList"
    assert is_list(cluster_roles.items)
  end

  test "Can listen for namespace changes", %{
    server: server,
    namespace: namespace
  } do
    pod_name = "watch-test-pod"

    # Start watcher for this specific namespace only
    {:ok, watcher_pid} =
      CoreV1.list_namespaced_pod!(namespace, timeout_seconds: 1)
      |> Kazan.Watcher.start_link(server: server, recv_timeout: 10500)

    # Create pod in our isolated namespace
    create_pod(pod_name, namespace, server: server)

    # Wait for pod ADDED event with eventually consistent pattern
    assert_eventually(
      fn ->
        receive do
          %Kazan.Watcher.Event{
            object: %Pod{metadata: %ObjectMeta{name: ^pod_name}},
            type: :added
          } ->
            true
        after
          100 -> false
        end
      end,
      timeout: 10_000
    )

    # Wait for pod to be scheduled (status update)
    assert_eventually(
      fn ->
        receive do
          %Kazan.Watcher.Event{
            object: %Pod{
              metadata: %ObjectMeta{name: ^pod_name},
              status: %PodStatus{phase: "Pending"}
            },
            type: :modified
          } ->
            true
        after
          100 -> false
        end
      end,
      timeout: 10_000
    )

    # Patch the pod
    patch_pod(pod_name, namespace, server: server)

    # Wait for patch to be reflected in watch events
    assert_eventually(
      fn ->
        receive do
          %Kazan.Watcher.Event{
            object: %Pod{
              metadata: %ObjectMeta{name: ^pod_name},
              spec: %PodSpec{active_deadline_seconds: 1}
            },
            type: :modified
          } ->
            true
        after
          100 -> false
        end
      end,
      timeout: 10_000
    )

    # Clean up pod
    delete_pod(pod_name, namespace, server: server)

    # Wait for delete event
    assert_eventually(
      fn ->
        receive do
          %Kazan.Watcher.Event{
            object: %Pod{metadata: %ObjectMeta{name: ^pod_name}},
            type: :deleted
          } ->
            true
        after
          100 -> false
        end
      end,
      timeout: 10_000
    )

    # Stop the watcher
    Kazan.Watcher.stop_watch(watcher_pid)
  end

  test "When consumer terminates so does watcher", %{
    server: server,
    namespace: namespace
  } do
    consumer = spawn(fn -> :timer.sleep(10_000) end)

    {:ok, watcher} =
      CoreV1.list_namespaced_pod!(namespace, timeout_seconds: 1)
      |> Kazan.Watcher.start_link(
        server: server,
        recv_timeout: 10500,
        send_to: consumer
      )

    Process.exit(consumer, :kill)
    # Give process time to die
    :timer.sleep(2000)
    refute Process.alive?(consumer)
    refute Process.alive?(watcher)
  end

  test "Can read pod logs", %{server: server, namespace: namespace} do
    CoreV1.create_namespaced_pod!(
      %Pod{
        metadata: %ObjectMeta{name: "read-logs-test"},
        spec: %PodSpec{
          containers: [
            %Container{
              args: [],
              image: "alpine",
              command: ["sh", "-c", "echo hello"],
              name: "main-process"
            }
          ]
        }
      },
      namespace
    )
    |> Kazan.run!(server: server)

    wait_for_pod_phase(namespace, "read-logs-test", "Running", server)

    log_lines =
      CoreV1.read_namespaced_pod_log!(namespace, "read-logs-test")
      |> Kazan.run!(server: server)

    assert log_lines == "hello\n"
  end

  describe "Custom Resources" do
    # Use raw requests to work with V1 CRD API (V1beta1 was removed in K8s 1.22+)

    setup %{server: server} do
      # Create CRD using raw V1 API request (V1beta1 no longer supported)
      crd_definition = %{
        "apiVersion" => "apiextensions.k8s.io/v1",
        "kind" => "CustomResourceDefinition",
        "metadata" => %{
          "name" => "foos.example.com"
        },
        "spec" => %{
          "group" => "example.com",
          "versions" => [
            %{
              "name" => "v1",
              "served" => true,
              "storage" => true,
              "schema" => %{
                "openAPIV3Schema" => %{
                  "type" => "object",
                  "properties" => %{
                    "a_string" => %{"type" => "string"},
                    "an_int" => %{"type" => "integer"},
                    "metadata" => %{
                      "type" => "object"
                    }
                  }
                }
              }
            }
          ],
          "scope" => "Namespaced",
          "names" => %{
            "plural" => "foos",
            "kind" => "Foo"
          }
        }
      }

      # Create CRD using client implementation directly (bypass model decoding)
      crd_request = %Kazan.Request{
        method: "post",
        path: "/apis/apiextensions.k8s.io/v1/customresourcedefinitions",
        query_params: %{},
        content_type: "application/json",
        body: Jason.encode!(crd_definition),
        response_model: nil
      }

      result = Kazan.Client.Imp.run(crd_request, server: server)

      case result do
        {:ok, _} -> :ok
        # CRD already exists, that's fine
        {:error, {:http_error, 409, _}} -> :ok
        {:error, reason} -> raise "Failed to create CRD: #{inspect(reason)}"
      end

      # Wait for the CRD to be created and established
      Process.sleep(2000)

      on_exit(fn ->
        # Delete CRD using raw request
        try do
          %Kazan.Request{
            method: "delete",
            path:
              "/apis/apiextensions.k8s.io/v1/customresourcedefinitions/foos.example.com",
            query_params: %{},
            content_type: "application/json",
            body: Jason.encode!(%{}),
            response_model: nil
          }
          |> Kazan.run!(server: server)
        rescue
          # Ignore cleanup errors
          _ -> :ok
        end
      end)
    end

    test "can create & query custom resources", %{
      server: server,
      namespace: namespace
    } do
      {:ok, body} =
        FooResource.encode(%FooResource{
          a_string: "test",
          an_int: 1,
          metadata: %ObjectMeta{name: "test-foo", namespace: namespace}
        })

      %Kazan.Request{
        method: "post",
        path: "/apis/example.com/v1/namespaces/#{namespace}/foos",
        query_params: %{},
        content_type: "application/json",
        body: Jason.encode!(body),
        response_model: FooResource
      }
      |> Kazan.run!(server: server)

      # Wait for the custom resource to be available
      wait_for_condition(
        fn ->
          case %Kazan.Request{
                 method: "get",
                 path: "/apis/example.com/v1/namespaces/#{namespace}/foos",
                 query_params: %{},
                 content_type: "application/json",
                 body: nil,
                 response_model: FooResourceList
               }
               |> Kazan.run(server: server) do
            {:ok, %FooResourceList{items: [_foo | _]}} -> true
            _ -> false
          end
        end,
        "Custom resource to be created"
      )

      %FooResourceList{items: [foo]} =
        %Kazan.Request{
          method: "get",
          path: "/apis/example.com/v1/namespaces/#{namespace}/foos",
          query_params: %{},
          content_type: "application/json",
          body: nil,
          response_model: FooResourceList
        }
        |> Kazan.run!(server: server)

      assert foo.a_string == "test"
      assert foo.an_int == 1
    end
  end

  defp create_pod(pod_name, namespace, opts) do
    CoreV1.create_namespaced_pod!(
      %Pod{
        metadata: %ObjectMeta{name: pod_name},
        spec: %PodSpec{
          containers: [
            %Container{
              args: [],
              image: "obmarg/health-proxy",
              name: "main-process"
            }
          ]
        }
      },
      namespace
    )
    |> Kazan.run!(opts)
  end

  defp patch_pod(pod_name, namespace, opts) do
    CoreV1.patch_namespaced_pod!(
      %Pod{
        metadata: %ObjectMeta{name: pod_name},
        spec: %PodSpec{
          active_deadline_seconds: 1
        }
      },
      namespace,
      pod_name
    )
    |> Kazan.run!(opts)
  end

  defp delete_pod(pod_name, namespace, opts) do
    CoreV1.delete_namespaced_pod!(
      %DeleteOptions{},
      namespace,
      pod_name
    )
    |> Kazan.run!(opts)
  end
end
