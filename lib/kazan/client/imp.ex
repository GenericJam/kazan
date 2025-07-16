defmodule Kazan.Client.Imp do
  @moduledoc false
  # Kazan.Client sends requests to a kubernetes server.
  # These requests should be built using the functions in the `Kazan.Apis` module.

  alias Kazan.{Request, Server}

  @type run_result :: {:ok, struct} | {:error, term}

  @doc """
  Makes a request against a kube server.

  The server should be set in the kazan config or provided in the options.

  ### Options

  * `server` - A `Kazan.Server` struct that defines which server we should send
  this request to. This will override any server provided in the Application
  config.
  """
  @spec run(Request.t(), Keyword.t()) :: run_result
  def run(%Request{} = request, options \\ []) do
    server = find_server(options)
    stream_to = Keyword.get(options, :stream_to)

    headers = build_headers(request, server)
    req_options = build_req_options(server, request, stream_to, options)

    # Build the Req request with proper options
    req_request =
      Req.new(
        method: method(request.method),
        url: server.url <> request.path,
        body: request.body || "",
        headers: headers,
        params: request.query_params
      )
      |> apply_req_options(req_options)

    case stream_to do
      nil ->
        # Non-streaming request
        res = Req.request(req_request)

        with {:ok, result} <- res,
             {:ok, body} <- check_status(result),
             {:ok, content_type} <- get_content_type(result) do
          case content_type do
            ["application/json"] ->
              with {:ok, model} <- decode(body, request.response_model),
                   do: {:ok, model}

            ["text/plain"] ->
              {:ok, body}

            _other ->
              {:error, :unsupported_content_type}
          end
        end

      pid when is_pid(pid) ->
        # Streaming request - the into callback handles streaming automatically
        case Req.request(req_request) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            {:ok, :stream_started}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Like `run`, but raises on Error.  See `run/2` for more details.
  """
  @spec run!(Request.t(), Keyword.t()) :: struct | no_return
  def run!(%Request{} = request, options \\ []) do
    case run(request, options) do
      {:ok, result} -> result
      {:error, reason} -> raise Kazan.RemoteError, reason: reason
    end
  end

  # Figures out which server we should use.  In order of preference:
  # - A server specified in the keyword arguments
  # - A server specified in the kazan config
  @spec find_server(Keyword.t()) :: Server.t()
  defp find_server(options) do
    case Keyword.get(options, :server) do
      nil ->
        Server.from_env!()

      server ->
        server
    end
  end

  defp method("get"), do: :get
  defp method("post"), do: :post
  defp method("put"), do: :put
  defp method("delete"), do: :delete
  defp method("patch"), do: :patch

  @spec check_status(%Req.Response{}) :: {:ok, String.t()} | {:error, term}
  defp check_status(%Req.Response{status: code, body: body})
       when code in 200..299 do
    {:ok, body}
  end

  defp check_status(%Req.Response{status: other, body: body}) do
    {:error, {:http_error, other, body}}
  end

  @spec get_content_type(%Req.Response{}) ::
          {:ok, String.t()} | {:error, :no_content_type}
  defp get_content_type(%Req.Response{headers: headers}) do
    # Req headers are case-insensitive maps
    case Map.get(headers, "content-type") || Map.get(headers, "Content-Type") do
      nil -> {:error, :no_content_type}
      content_type -> {:ok, content_type}
    end
  end

  defp build_req_options(server, _request, stream_to, options) do
    ssl_opts = ssl_options(server)

    base_opts = [
      connect_options: ssl_opts,
      receive_timeout: Keyword.get(options, :recv_timeout, 15000)
    ]

    case stream_to do
      nil ->
        base_opts

      pid when is_pid(pid) ->
        # Use proper Req streaming with callback function
        ref = make_ref()

        into_fun = fn
          {:data, data}, acc ->
            send(pid, {:req_async, ref, {:data, data}})
            {:cont, acc}

          :done, acc ->
            send(pid, {:req_async, ref, {:end, []}})
            {:cont, acc}

          {:error, reason}, acc ->
            send(pid, {:req_async, ref, {:error, reason}})
            {:halt, acc}
        end

        base_opts ++ [into: into_fun, request_ref: ref]
    end
  end

  # New helper function to build headers
  defp build_headers(request, server) do
    headers = [{"Accept", "application/json"}]

    headers =
      headers ++
        case request.content_type do
          nil -> []
          type -> [{"Content-Type", type}]
        end

    headers ++
      case server.auth do
        %Server.TokenAuth{token: token} ->
          [{"Authorization", "Bearer #{token}"}]

        %Server.ProviderAuth{token: token} when not is_nil(token) ->
          [{"Authorization", "Bearer #{token}"}]

        %Server.BasicAuth{token: token} when not is_nil(token) ->
          [{"Authorization", "Basic #{token}"}]

        %Server.ProviderAuth{} ->
          raise "Provider authentication needs resolved before use. Please see Kazan.Server.resolve_auth/2 documentation for more details"

        _ ->
          []
      end
  end

  # New function to properly apply Req options
  defp apply_req_options(req, options) do
    Enum.reduce(options, req, fn
      {:connect_options, ssl_opts}, acc ->
        # Apply SSL options to Req through transport_opts under connect_options
        Req.merge(acc, connect_options: [transport_opts: ssl_opts])

      {:receive_timeout, timeout}, acc ->
        Req.merge(acc, receive_timeout: timeout)

      {:async, true}, acc ->
        # Req doesn't support async the same way - we'll handle streaming differently
        acc

      {:into, into_fn}, acc ->
        Req.merge(acc, into: into_fn)

      _other, acc ->
        acc
    end)
  end

  @spec ssl_options(Server.t()) :: Keyword.t()
  defp ssl_options(server) do
    auth_options = ssl_auth_options(server.auth)

    verify_options =
      case server.insecure_skip_tls_verify do
        true ->
          [
            verify: :verify_none,
            verify_fun: {fn _, _, _ -> {:valid, nil} end, nil},
            check_hostname: false
          ]

        _ ->
          [verify: :verify_peer]
      end

    ca_options =
      case server.ca_cert do
        nil ->
          []

        cert when is_binary(cert) ->
          # cert should already be in DER format from Kazan.Server
          [
            cacerts: [cert],
            verify: :verify_peer,
            depth: 10
          ]
      end

    # Combine all SSL options
    auth_options ++ verify_options ++ ca_options
  end

  defp ssl_auth_options(%Server.CertificateAuth{certificate: cert, key: key}) do
    [cert: cert, key: key]
  end

  defp ssl_auth_options(_), do: []

  # Decode helpers: if we know what model we're expecting, use that.
  # Otherwise defer to Kazan.Models.decode which will try to guess the model
  # from the kind provided in the response.
  defp decode(data, nil), do: Kazan.Models.decode(data, nil)
  defp decode(data, response_model), do: response_model.decode(data)
end
