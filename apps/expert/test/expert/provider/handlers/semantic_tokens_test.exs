defmodule Expert.Provider.Handlers.SemanticTokensTest do
  use ExUnit.Case, async: false

  alias Expert.CodeIntelligence.SemanticTokens
  alias Expert.Document.Context
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Project
  alias GenLSP.Requests.TextDocumentSemanticTokensFull
  alias GenLSP.Structures

  setup_all do
    start_supervised!(Expert.Application.document_store_child_spec())
    :ok
  end

  test "emits semantic tokens for basic Elixir syntax" do
    text = """
    # note
    defmodule Foo do
      @attr 1

      def bar(value), do: value + 1
    end
    """

    uri = "file:///semantic_tokens_test.ex"
    :ok = Document.Store.open(uri, text, 1)

    on_exit(fn ->
      Document.Store.close(uri)
    end)

    {:ok, request} = build_request(uri)

    document = Document.Container.context_document(request, nil)
    context = Context.new(uri, document, Project.bare(uri))

    {:ok, %Structures.SemanticTokens{data: data}} =
      Handlers.SemanticTokens.handle(request, context)

    tokens = decode(data, SemanticTokens.legend())

    assert %{line: 0, start: 0, length: 6, type: "comment"} in tokens
    assert %{line: 1, start: 0, length: 9, type: "keyword"} in tokens
    assert %{line: 1, start: 10, length: 3, type: "namespace"} in tokens
    assert %{line: 1, start: 14, length: 2, type: "keyword"} in tokens
    assert %{line: 2, start: 2, length: 5, type: "decorator"} in tokens
    assert %{line: 2, start: 8, length: 1, type: "number"} in tokens
    assert %{line: 4, start: 2, length: 3, type: "keyword"} in tokens
    assert %{line: 4, start: 6, length: 3, type: "function"} in tokens
    assert %{line: 4, start: 10, length: 5, type: "parameter"} in tokens
    assert %{line: 4, start: 18, length: 2, type: "keyword"} in tokens
    assert %{line: 4, start: 22, length: 5, type: "variable"} in tokens
    assert %{line: 4, start: 28, length: 1, type: "operator"} in tokens
    assert %{line: 4, start: 30, length: 1, type: "number"} in tokens
    assert %{line: 5, start: 0, length: 3, type: "keyword"} in tokens
  end

  test "emits semantic tokens for interpolated strings and bracket access" do
    text = ~S"""
    "hello #{name} world"
    meta[:line]
    """

    uri = "file:///semantic_tokens_interpolation_test.ex"
    :ok = Document.Store.open(uri, text, 1)

    on_exit(fn ->
      Document.Store.close(uri)
    end)

    {:ok, request} = build_request(uri)

    document = Document.Container.context_document(request, nil)
    context = Context.new(uri, document, Project.bare(uri))

    {:ok, %Structures.SemanticTokens{data: data}} =
      Handlers.SemanticTokens.handle(request, context)

    tokens = decode(data, SemanticTokens.legend())

    assert %{line: 0, start: 0, length: 7, type: "string"} in tokens
    assert %{line: 0, start: 7, length: 2, type: "operator"} in tokens
    assert %{line: 0, start: 9, length: 4, type: "variable"} in tokens
    assert %{line: 0, start: 13, length: 1, type: "operator"} in tokens
    assert %{line: 0, start: 14, length: 7, type: "string"} in tokens

    assert %{line: 1, start: 0, length: 4, type: "variable"} in tokens
    assert %{line: 1, start: 4, length: 1, type: "operator"} in tokens
    assert %{line: 1, start: 5, length: 5, type: "enumMember"} in tokens
    assert %{line: 1, start: 10, length: 1, type: "operator"} in tokens
  end

  defp build_request(uri) do
    request = %TextDocumentSemanticTokensFull{
      id: 1,
      params: %Structures.SemanticTokensParams{
        text_document: %Structures.TextDocumentIdentifier{uri: uri}
      }
    }

    Convert.to_native(request)
  end

  defp decode(data, %Structures.SemanticTokensLegend{token_types: token_types}) do
    {tokens, _} =
      Enum.map_reduce(Enum.chunk_every(data, 5), {0, 0}, fn
        [delta_line, delta_start, length, token_type, _token_modifiers], {line, start} ->
          line = line + delta_line
          start = if delta_line == 0, do: start + delta_start, else: delta_start

          token = %{
            line: line,
            start: start,
            length: length,
            type: Enum.fetch!(token_types, token_type)
          }

          {token, {line, start}}
      end)

    tokens
  end
end
