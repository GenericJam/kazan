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

    headers = [{"Accept", "application/json"}]

    headers =
      headers ++
        case request.content_type do
          nil -> []
          type -> [{"Content-Type", type}]
        end

    headers =
      headers ++
        case server.auth do
          %Server.TokenAuth{token: token} ->
            [{"Authorization", "Bearer #{token}"}]

          %Server.ProviderAuth{token: token} when not is_nil(token) ->
            [{"Authorization", "Bearer #{token}"}]

          %Server.BasicAuth{token: token} when not is_nil(token) ->
            [{"Authorization", "Basic #{token}"}]

          %Server.ProviderAuth{} ->
            raise "Provider authentication needs resolved before use.  Please see Kazan.Server.resolve_auth/2 documentation for more details"

          _ ->
            []
        end

    stream_to = Keyword.get(options, :stream_to)

    request_options = [params: request.query_params, ssl: ssl_options(server)]

    case stream_to do
      nil ->
        res =
          Req.new(
            method: method(request.method),
            url: server.url <> request.path,
            headers: headers,
            body: request.body || "",
            params: request.query_params,
            connect_options: [
              transport_opts: [cacerts: ssl_options(server)[:cacerts]]
            ]
          )
          |> Req.request()

        with {:ok, response} <- res,
             {:ok, body} <- check_status(response),
             {:ok, content_type} <- get_content_type(response) do
          case content_type do
            "application/json" ->
              decode(body, request.response_model)

            "text/plain" ->
              {:ok, body}

            _ ->
              {:error, :unsupported_content_type}
          end
        end

      pid when is_pid(pid) ->
        req =
          Req.new(
            method: method(request.method),
            url: server.url <> request.path,
            headers: headers,
            body: request.body || "",
            json: request.query_params,
            connect_options: [
              transport_opts: [cacerts: ssl_options(server)[:cacerts]]
            ],
            recv_timeout:
              Keyword.get(
                options,
                :recv_timeout,
                request_options[:recv_timeout] || 15000
              ),
            into: fn
              {:data, data}, req_resp ->
                send(stream_to, {:data, data})
                {:cont, req_resp}
            end
          )
          |> Req.request()

        with {:ok, response} <- req do
          response
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

  @methods ~w"""
  get post put delete patch
  """
  @atom_methods ~w"""
  get post put delete patch
  """a

  @method_map Enum.zip(@methods, @atom_methods) |> Map.new()

  defp method(method), do: Map.get(@method_map, method)

  @spec check_status(Req.Response.t()) :: {:ok, String.t()}
  defp check_status(%{status: code, body: body}) when code in 200..299 do
    {:ok, body}
  end

  defp check_status(%{status: other, body: body}) do
    {:error, {:http_error, other, body}}
  end

  @spec get_content_type(Req.Response.t()) ::
          {:ok, String.t()} | {:error, :no_content_type}
  defp get_content_type(%{headers: headers}) do
    case Map.get(headers, "content-type", 0) do
      nil -> {:error, :no_content_type}
      [content_type] -> {:ok, content_type}
      _ -> {:error, :content_type_match_error}
    end
  end

  @spec ssl_options(Server.t()) :: Keyword.t()
  defp ssl_options(server) do
    auth_options = ssl_auth_options(server.auth)

    verify_options =
      case server.insecure_skip_tls_verify do
        true -> [verify: :verify_none]
        _ -> []
      end

    ca_options =
      case server.ca_cert do
        nil -> []
        cert -> [cacerts: [cert], verify: :verify_peer]
      end

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
