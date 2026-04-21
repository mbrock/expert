defmodule Expert.CodeIntelligence.SemanticTokens do
  @moduledoc false

  alias Expert.Protocol.Conversions
  alias Forge.Ast
  alias Forge.Ast.Range, as: AstRange
  alias Forge.CodeUnit
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias GenLSP.Structures

  @token_types ~w(
    namespace
    function
    parameter
    variable
    property
    keyword
    decorator
    string
    number
    comment
    operator
    enumMember
  )

  @token_type_indexes @token_types
                      |> Enum.with_index()
                      |> Map.new()

  @token_modifiers []

  @definition_forms [
    :def,
    :defdelegate,
    :defguard,
    :defguardp,
    :defmacro,
    :defmacrop,
    :defp
  ]

  @keyword_forms [
    :alias,
    :case,
    :cond,
    :def,
    :defdelegate,
    :defguard,
    :defguardp,
    :defimpl,
    :defmacro,
    :defmacrop,
    :defmodule,
    :defp,
    :defprotocol,
    :fn,
    :for,
    :if,
    :import,
    :quote,
    :receive,
    :require,
    :try,
    :unless,
    :unquote,
    :use,
    :with
  ]

  @block_keywords MapSet.new([:after, :catch, :do, :else, :rescue])
  @textual_operators MapSet.new([:and, :in, :not, :or, :when])

  @type token :: %{
          line: non_neg_integer(),
          start: non_neg_integer(),
          length: pos_integer(),
          type: non_neg_integer(),
          modifiers: non_neg_integer()
        }

  @spec legend() :: Structures.SemanticTokensLegend.t()
  def legend do
    %Structures.SemanticTokensLegend{
      token_types: @token_types,
      token_modifiers: @token_modifiers
    }
  end

  @spec full(Document.t()) :: Structures.SemanticTokens.t()
  def full(%Document{} = document) do
    {ast, comments} = parse(document)

    tokens =
      comments
      |> comment_tokens(document)
      |> Kernel.++(collect_tokens(ast, document))
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.line, &1.start, &1.length, &1.type, &1.modifiers})

    %Structures.SemanticTokens{data: encode(tokens)}
  end

  defp parse(%Document{} = document) do
    case Ast.from(document) do
      {:ok, ast, comments} ->
        {ast, comments}

      {:error, ast, _parse_error, comments} ->
        {ast, comments}

      {:error, _parse_error} ->
        {nil, []}
    end
  end

  defp comment_tokens(comments, %Document{} = document) do
    Enum.flat_map(comments, fn %{line: line, column: column, text: text} ->
      token(document, line, column, text, :comment)
    end)
  end

  defp collect_tokens(nil, _document), do: []

  defp collect_tokens(ast, %Document{} = document) do
    do_collect_tokens(ast, document, :default)
  end

  defp do_collect_tokens(list, %Document{} = document, context) when is_list(list) do
    Enum.flat_map(list, &do_collect_tokens(&1, document, context))
  end

  defp do_collect_tokens(
         {:@, meta, [{name, _name_meta, value}]},
         %Document{} = document,
         _context
       )
       when is_atom(name) do
    decorator = "@" <> Atom.to_string(name)

    token(document, meta[:line], meta[:column], decorator, :decorator) ++
      do_collect_tokens(value, document, :default)
  end

  defp do_collect_tokens({:%, meta, [alias_ast, map_ast]}, %Document{} = document, _context) do
    token(document, meta[:line], meta[:column], "%", :operator) ++
      do_collect_tokens(alias_ast, document, :default) ++
      do_collect_tokens(map_ast, document, :default)
  end

  defp do_collect_tokens(
         {{:., _dot_meta, [Access, :get]}, meta, [receiver, key]},
         %Document{} = document,
         _context
       ) do
    if meta[:from_brackets] == true do
      do_collect_tokens(receiver, document, :default) ++
        token(document, meta[:line], meta[:column], "[", :operator) ++
        do_collect_tokens(key, document, :default) ++
        closing_token(document, meta, "]", :operator)
    else
      do_collect_tokens(receiver, document, :default) ++
        token(document, meta[:line], meta[:column], "get", :function) ++
        do_collect_tokens([key], document, :default)
    end
  end

  defp do_collect_tokens(
         {{:., dot_meta, [receiver, name]}, meta, args},
         %Document{} = document,
         _context
       )
       when is_atom(name) and is_list(args) do
    name_text = Atom.to_string(name)

    name_type =
      if meta[:no_parens] == true and args == [] do
        :property
      else
        :function
      end

    do_collect_tokens(receiver, document, :default) ++
      token(document, dot_meta[:line], dot_meta[:column], ".", :operator) ++
      token(document, meta[:line], meta[:column], name_text, name_type) ++
      do_collect_tokens(args, document, :default)
  end

  defp do_collect_tokens({:__aliases__, _, _} = ast, %Document{} = document, _context) do
    range_token(ast, document, :namespace)
  end

  defp do_collect_tokens({:<<>>, meta, parts} = ast, %Document{} = document, _context)
       when is_list(parts) do
    if is_binary(meta[:delimiter]) do
      if Enum.any?(parts, &(not is_binary(&1))) do
        interpolated_string_tokens(ast, parts, document)
      else
        range_tokens(ast, document, :string)
      end
    else
      token(document, meta[:line], meta[:column], "<<>>", :operator) ++
        Enum.flat_map(parts, &do_collect_tokens(&1, document, :default))
    end
  end

  defp do_collect_tokens(
         {:__block__, meta, [value]} = ast,
         %Document{} = document,
         _context
       )
       when is_atom(value) do
    cond do
      meta[:format] == :keyword and MapSet.member?(@block_keywords, value) ->
        token(document, meta[:line], meta[:column], Atom.to_string(value), :keyword)

      meta[:format] == :keyword ->
        token(document, meta[:line], meta[:column], Atom.to_string(value), :property)

      value in [true, false, nil] ->
        range_token(ast, document, :keyword)

      true ->
        range_token(ast, document, :enumMember)
    end
  end

  defp do_collect_tokens({:__block__, meta, [_value]} = ast, %Document{} = document, _context) do
    cond do
      is_binary(meta[:delimiter]) ->
        range_token(ast, document, :string)

      is_binary(meta[:token]) and number_token?(meta[:token]) ->
        range_token(ast, document, :number)

      true ->
        []
    end
  end

  defp do_collect_tokens({:__block__, _meta, nodes}, %Document{} = document, context)
       when is_list(nodes) do
    Enum.flat_map(nodes, &do_collect_tokens(&1, document, context))
  end

  defp do_collect_tokens({form, meta, [head | rest]}, %Document{} = document, _context)
       when form in @definition_forms do
    token(document, meta[:line], meta[:column], Atom.to_string(form), :keyword) ++
      block_tokens(document, meta) ++
      definition_head_tokens(head, document) ++
      Enum.flat_map(rest, &do_collect_tokens(&1, document, :default))
  end

  defp do_collect_tokens({:fn, meta, clauses}, %Document{} = document, _context) do
    token(document, meta[:line], meta[:column], "fn", :keyword) ++
      Enum.flat_map(clauses, &fn_clause_tokens(&1, document))
  end

  defp do_collect_tokens({form, meta, args}, %Document{} = document, _context)
       when form in @keyword_forms and is_list(args) do
    token(document, meta[:line], meta[:column], Atom.to_string(form), :keyword) ++
      block_tokens(document, meta) ++
      Enum.flat_map(args, &do_collect_tokens(&1, document, :default))
  end

  defp do_collect_tokens({name, meta, nil}, %Document{} = document, :parameter)
       when is_atom(name) do
    token(document, meta[:line], meta[:column], Atom.to_string(name), :parameter)
  end

  defp do_collect_tokens({name, meta, nil}, %Document{} = document, _context)
       when is_atom(name) do
    token(document, meta[:line], meta[:column], Atom.to_string(name), :variable)
  end

  defp do_collect_tokens({name, meta, args}, %Document{} = document, _context)
       when is_atom(name) and is_list(args) do
    token_type =
      if operator?(name) do
        :operator
      else
        :function
      end

    token(document, meta[:line], meta[:column], Atom.to_string(name), token_type) ++
      Enum.flat_map(args, &do_collect_tokens(&1, document, :default))
  end

  defp do_collect_tokens({left, right}, %Document{} = document, context) do
    do_collect_tokens(left, document, context) ++
      do_collect_tokens(right, document, :default)
  end

  defp do_collect_tokens(_other, _document, _context), do: []

  defp definition_head_tokens({:when, meta, [head | guards]}, %Document{} = document) do
    token(document, meta[:line], meta[:column], "when", :operator) ++
      definition_head_tokens(head, document) ++
      Enum.flat_map(guards, &do_collect_tokens(&1, document, :default))
  end

  defp definition_head_tokens({name, meta, args}, %Document{} = document)
       when is_atom(name) and is_list(args) do
    token(document, meta[:line], meta[:column], Atom.to_string(name), :function) ++
      Enum.flat_map(args, &do_collect_tokens(&1, document, :parameter))
  end

  defp definition_head_tokens(other, %Document{} = document) do
    do_collect_tokens(other, document, :parameter)
  end

  defp fn_clause_tokens({:->, meta, [params, body]}, %Document{} = document) do
    token(document, meta[:line], meta[:column], "->", :operator) ++
      do_collect_tokens(params, document, :parameter) ++
      do_collect_tokens(body, document, :default)
  end

  defp fn_clause_tokens(other, %Document{} = document) do
    do_collect_tokens(other, document, :default)
  end

  defp block_tokens(%Document{} = document, meta) do
    do_token =
      case meta[:do] do
        [line: line, column: column] -> token(document, line, column, "do", :keyword)
        _ -> []
      end

    end_token =
      case meta[:end] do
        [line: line, column: column] -> token(document, line, column, "end", :keyword)
        _ -> []
      end

    do_token ++ end_token
  end

  defp interpolated_string_tokens({:<<>>, _, parts} = ast, parts, %Document{} = document) do
    case AstRange.fetch(ast, document) do
      {:ok, %Range{start: start, end: finish}} ->
        {tokens, cursor} =
          Enum.reduce(parts, {[], start}, fn
            literal, {acc, cursor} when is_binary(literal) ->
              {acc, cursor}

            interpolation, {acc, cursor} ->
              case AstRange.fetch(interpolation, document) do
                {:ok, %Range{start: interpolation_start, end: interpolation_end}} ->
                  tokens =
                    acc ++
                      span_tokens(document, cursor, interpolation_start, :string) ++
                      interpolation_tokens(interpolation, document)

                  {tokens, interpolation_end}

                :error ->
                  {acc, cursor}
              end
          end)

        tokens ++ span_tokens(document, cursor, finish, :string)

      _ ->
        []
    end
  end

  defp interpolation_tokens(
         {:"::", _meta,
          [{{:., _, [Kernel, :to_string]}, interpolation_meta, [value]}, binary_ast]},
         %Document{} = document
       ) do
    if interpolation_meta[:from_interpolation] == true and match?({:binary, _, nil}, binary_ast) do
      token(document, interpolation_meta[:line], interpolation_meta[:column], ~S(#{), :operator) ++
        do_collect_tokens(value, document, :default) ++
        closing_token(document, interpolation_meta, "}", :operator)
    else
      []
    end
  end

  defp interpolation_tokens(interpolation, %Document{} = document) do
    range_tokens(interpolation, document, :string)
  end

  defp closing_token(%Document{} = document, meta, text, type) do
    case meta[:closing] do
      [line: line, column: column] -> token(document, line, column, text, type)
      _ -> []
    end
  end

  defp range_token(ast, %Document{} = document, type) do
    with {:ok, %Range{start: start, end: finish}} <- AstRange.fetch(ast, document),
         true <- start.line == finish.line,
         text when text != "" <- Document.fragment(document, start, finish),
         {:ok, lsp_position} <- Conversions.to_lsp(start) do
      [
        %{
          line: lsp_position.line,
          start: lsp_position.character,
          length: CodeUnit.count(:utf16, text),
          type: token_type_index(type),
          modifiers: 0
        }
      ]
    else
      _ -> []
    end
  end

  defp range_tokens(ast, %Document{} = document, type) do
    case AstRange.fetch(ast, document) do
      {:ok, %Range{start: start, end: finish}} -> span_tokens(document, start, finish, type)
      _ -> []
    end
  end

  defp span_tokens(%Document{} = document, %Position{} = start, %Position{} = finish, type) do
    case Position.compare(start, finish) do
      :lt ->
        Enum.flat_map(start.line..finish.line, fn line ->
          line_start =
            if line == start.line do
              start.character
            else
              1
            end

          line_finish =
            if line == finish.line do
              finish.character
            else
              case Document.fetch_text_at(document, line) do
                {:ok, text} -> String.length(text) + 1
                :error -> 1
              end
            end

          token_between(document, line, line_start, line_finish, type)
        end)

      _ ->
        []
    end
  end

  defp token_between(%Document{} = document, line, start_column, finish_column, type)
       when is_integer(line) and is_integer(start_column) and is_integer(finish_column) and
              start_column < finish_column do
    start = Position.new(document, line, start_column)
    finish = Position.new(document, line, finish_column)
    text = Document.fragment(document, start, finish)

    case {text, Conversions.to_lsp(start)} do
      {"", _} ->
        []

      {_, {:error, _}} ->
        []

      {text, {:ok, lsp_position}} ->
        [
          %{
            line: lsp_position.line,
            start: lsp_position.character,
            length: CodeUnit.count(:utf16, text),
            type: token_type_index(type),
            modifiers: 0
          }
        ]
    end
  end

  defp token_between(_document, _line, _start_column, _finish_column, _type), do: []

  defp token(%Document{} = document, line, column, text, type)
       when is_integer(line) and is_integer(column) and is_binary(text) and text != "" do
    with %Position{} = position <- Position.new(document, line, column),
         {:ok, lsp_position} <- Conversions.to_lsp(position) do
      [
        %{
          line: lsp_position.line,
          start: lsp_position.character,
          length: CodeUnit.count(:utf16, text),
          type: token_type_index(type),
          modifiers: 0
        }
      ]
    else
      _ -> []
    end
  end

  defp token(_document, _line, _column, _text, _type), do: []

  defp encode([]), do: []

  defp encode([first | rest]) do
    {encoded, _prev_line, _prev_start} =
      Enum.reduce(rest, {[encode_first(first)], first.line, first.start}, fn token,
                                                                             {acc, prev_line,
                                                                              prev_start} ->
        delta_line = token.line - prev_line

        delta_start =
          if delta_line == 0 do
            token.start - prev_start
          else
            token.start
          end

        encoded_token = [
          delta_line,
          delta_start,
          token.length,
          token.type,
          token.modifiers
        ]

        {[acc, encoded_token], token.line, token.start}
      end)

    List.flatten(encoded)
  end

  defp encode_first(token) do
    [token.line, token.start, token.length, token.type, token.modifiers]
  end

  defp number_token?(token) do
    String.match?(token, ~r/^\d/)
  end

  defp operator?(form) do
    MapSet.member?(@textual_operators, form) or
      Atom.to_string(form) =~ ~r/^[[:punct:]]+$/
  end

  defp token_type_index(type) do
    Map.fetch!(@token_type_indexes, Atom.to_string(type))
  end
end
