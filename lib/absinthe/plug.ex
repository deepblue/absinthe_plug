defmodule Absinthe.Plug do
  @moduledoc """
  A plug for using Absinthe

  See [The Guides](http://absinthe-graphql.org/guides/plug-phoenix/) for usage details
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @type function_name :: atom

  @type opts :: [
    schema: atom,
    adapter: atom,
    path: binary,
    context: map,
    json_codec: atom | {atom, Keyword.t},
    pipeline: {Module.t, function_name},
    no_query_message: binary,
  ]

  @doc """
  Sets up and validates the Absinthe schema
  """
  @spec init(opts :: opts) :: map
  def init(opts) do
    adapter = Keyword.get(opts, :adapter)
    context = Keyword.get(opts, :context, %{})

    no_query_message = Keyword.get(opts, :no_query_message, "No query document supplied")

    pipeline = Keyword.get(opts, :pipeline, {__MODULE__, :default_pipeline})

    json_codec = case Keyword.get(opts, :json_codec, Poison) do
      module when is_atom(module) -> %{module: module, opts: []}
      other -> other
    end

    schema_mod = opts |> get_schema

    %{adapter: adapter, schema_mod: schema_mod, context: context, json_codec: json_codec,
      pipeline: pipeline, no_query_message: no_query_message}
  end

  defp get_schema(opts) do
    default = Application.get_env(:absinthe, :schema)
    schema = Keyword.get(opts, :schema, default)
    try do
      Absinthe.Schema.types(schema)
    rescue
      UndefinedFunctionError ->
        raise ArgumentError, "The supplied schema: #{inspect schema} is not a valid Absinthe Schema"
    end
    schema
  end

  @doc """
  Parses, validates, resolves, and executes the given Graphql Document
  """
  def call(conn, %{json_codec: json_codec} = config) do
    {conn, result} = conn |> execute(config)

    case result do
      {:input_error, msg} ->
        conn
        |> send_resp(400, msg)

      {:ok, %{data: _} = result} ->
        conn
        |> json(200, result, json_codec)

      {:ok, %{errors: _} = result} ->
        conn
        |> json(400, result, json_codec)

      {:ok, result} when is_list(result) ->
        conn
        |> json(200, result, json_codec)

      {:error, {:http_method, text}, _} ->
        conn
        |> send_resp(405, text)

      {:error, error, _} when is_binary(error) ->
        conn
        |> send_resp(500, error)

    end
  end

  @doc false
  def execute(conn, config)do
    {conn, body} = load_body_and_params(conn)

    result = case batched_request(conn) do
      nil -> execute_pipeline(conn, conn.params, body, config)
      batch -> execute_batch(conn, batch, body, config)
    end

    {conn, result}
  end

  def execute_pipeline(conn, params, body, config) do
    with {:ok, input, opts} <- prepare(conn, params, body, config),
    {:ok, input} <- validate_input(input, config.no_query_message),
    pipeline <- setup_pipeline(conn, config, opts),
    {:ok, absinthe_result, _} <- Absinthe.Pipeline.run(input, pipeline) do
      {:ok, absinthe_result}
    end
  end

  def setup_pipeline(conn, config, opts) do
    private = conn.private[:absinthe] || %{}
    private = Map.put(private, :http_method, conn.method)
    config = Map.put(config, :conn_private, private)

    {module, fun} = config.pipeline
    apply(module, fun, [config, opts])
  end

  def default_pipeline(config, opts) do
    config.schema_mod
    |> Absinthe.Pipeline.for_document(opts)
    |> Absinthe.Pipeline.insert_after(Absinthe.Phase.Document.CurrentOperation,
      {Absinthe.Plug.Validation.HTTPMethod, method: config.conn_private.http_method}
    )
  end

  @doc false
  def prepare(conn, params, body, %{json_codec: json_codec} = config) do
    raw_input = Map.get(params, "query", body)

    Logger.debug("""
    GraphQL Document:
    #{raw_input}
    """)

    variables = Map.get(params, "variables") || "{}"
    operation_name = params["operationName"] |> decode_operation_name

    with {:ok, variables} <- decode_variables(variables, json_codec) do
        absinthe_opts = [
          variables: variables,
          context: Map.merge(config.context, conn.private[:absinthe][:context] || %{}),
          operation_name: operation_name
        ]
        {:ok, raw_input, absinthe_opts}
    end
  end

  defp validate_input(nil, no_query_message), do: {:input_error, no_query_message}
  defp validate_input("", no_query_message), do: {:input_error, no_query_message}
  defp validate_input(doc, _), do: {:ok, doc}

  # GraphQL.js treats an empty operation name as no operation name.
  defp decode_operation_name(""), do: nil
  defp decode_operation_name(name), do: name

  defp decode_variables(%{} = variables, _), do: {:ok, variables}
  defp decode_variables("", _), do: {:ok, %{}}
  defp decode_variables("null", _), do: {:ok, %{}}
  defp decode_variables(nil, _), do: {:ok, %{}}
  defp decode_variables(variables, codec) do
    case codec.module.decode(variables) do
      {:ok, results} ->
        {:ok, results}
      _ ->
        {:input_error, "The variable values could not be decoded"}
    end
  end

  def load_body_and_params(%{body_params: %{"query" => _}}=conn) do
    {fetch_query_params(conn), ""}
  end
  def load_body_and_params(conn) do
    case get_req_header(conn, "content-type") do
      ["application/graphql"] ->
        {:ok, body, conn} = read_body(conn)
        {fetch_query_params(conn), body}
      _ ->
        {conn, ""}
    end
  end

  @doc false
  def json(conn, status, body, json_codec) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, json_codec.module.encode!(body, json_codec.opts))
  end

  def batched_request(%{params: %{"_json" => batch}}) when is_list(batch), do: batch
  def batched_request(_), do: nil

  def execute_batch(conn, batch, body, config) do
    ret = batch
    |> Enum.map(fn(params) ->
        {_ok, ret} = execute_pipeline(conn, params, body, config)
        ret
      end)

    {:ok, ret}
  end
end
