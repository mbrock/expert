defmodule Forge.CodeIntelligence.SyntacticTokens do
  @moduledoc """
  Builds a fast syntactic approximation of LSP semantic tokens for Elixir documents.

  This module classifies token spans from parser comments, AST shape, and a small amount of
  local syntactic context. It does not resolve symbols through project analysis, so its output
  is intentionally best-effort rather than fully semantic.

  In practice that means it can emit useful token kinds such as `namespace`, `function`,
  `parameter`, `string`, and `keyword`, but it cannot reliably answer questions that require
  name resolution or project knowledge. For example, a callable may be labeled as `function`
  even when it ultimately resolves to a macro, and no semantic modifiers are attached.

  The return type is still `GenLSP.Structures.SemanticTokens` because this module exists to feed
  the LSP semantic-tokens feature, even though the classification itself is syntactic.
  """

  alias Forge.Ast
  alias Forge.Ast.Range, as: AstRange
  alias Forge.CodeUnit
  alias Forge.Document
  import Forge.Document.Line
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias GenLSP.Structures

  @token_types ~w(
    namespace
    function
    type
    parameter
    variable
    property
    keyword
    decorator
    string
    regexp
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
  @spec_attrs MapSet.new([:callback, :macrocallback, :spec])
  @textual_operators MapSet.new([:and, :in, :not, :or, :when])
  @type_attrs MapSet.new([:opaque, :type, :typep])

  @type token :: %{
          line: non_neg_integer(),
          start: non_neg_integer(),
          length: pos_integer(),
          type: non_neg_integer(),
          modifiers: non_neg_integer()
        }

  @type token_tree :: token | [token_tree]

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
      [comment_tokens(comments, document), collect_tokens(ast, document)]
      |> flatten_tokens()
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
    Enum.map(comments, fn %{line: line, column: column, text: text} ->
      token(document, line, column, text, :comment)
    end)
  end

  defp collect_tokens(nil, _document), do: []

  defp collect_tokens(ast, %Document{} = document) do
    scan(ast, document, :default)
  end

  defp scan(list, %Document{} = document, context) when is_list(list) do
    Enum.map(list, &scan(&1, document, context))
  end

  defp scan(
         {:@, meta, [{name, _name_meta, value}]},
         %Document{} = document,
         _context
       )
       when is_atom(name) do
    decorator = "@" <> Atom.to_string(name)

    context =
      cond do
        MapSet.member?(@spec_attrs, name) -> :spec
        MapSet.member?(@type_attrs, name) -> :type_decl
        true -> :default
      end

    [
      token(document, meta[:line], meta[:column], decorator, :decorator),
      scan(value, document, context)
    ]
  end

  defp scan({:%, meta, [alias_ast, map_ast]}, %Document{} = document, _context) do
    [
      token(document, meta[:line], meta[:column], "%", :operator),
      scan(alias_ast, document, :default),
      scan(map_ast, document, :default)
    ]
  end

  defp scan(
         {form, meta, [{:<<>>, _, parts}, modifiers]} = ast,
         %Document{} = document,
         _context
       )
       when is_atom(form) and is_list(modifiers) do
    if is_binary(meta[:delimiter]) and sigil_form?(form) do
      type = if form == :sigil_r, do: :regexp, else: :string

      if Enum.any?(parts, &(not is_binary(&1))) do
        interpolated_literal_tokens(ast, parts, document, type)
      else
        range_tokens(ast, document, type)
      end
    else
      [
        token(document, meta[:line], meta[:column], Atom.to_string(form), :function),
        Enum.map([{:<<>>, meta, parts}, modifiers], &scan(&1, document, :default))
      ]
    end
  end

  defp scan({:&, meta, [capture]}, %Document{} = document, _context) do
    [
      token(document, meta[:line], meta[:column], "&", :operator),
      scan(capture, document, :capture)
    ]
  end

  defp scan(
         {{:., _, [:erlang, :binary_to_atom]}, meta, [{:<<>>, _, parts}, :utf8]} = ast,
         %Document{} = document,
         _context
       )
       when is_list(parts) do
    if is_binary(meta[:delimiter]) and Enum.any?(parts, &(not is_binary(&1))) do
      interpolated_literal_tokens(ast, parts, document, :enumMember)
    else
      []
    end
  end

  defp scan(
         {{:., _dot_meta, [Access, :get]}, meta, [receiver, key]},
         %Document{} = document,
         _context
       ) do
    if meta[:from_brackets] == true do
      [
        scan(receiver, document, :default),
        token(document, meta[:line], meta[:column], "[", :operator),
        scan(key, document, :default),
        closing_token(document, meta, "]", :operator)
      ]
    else
      [
        scan(receiver, document, :default),
        token(document, meta[:line], meta[:column], "get", :function),
        scan([key], document, :default)
      ]
    end
  end

  defp scan(
         {{:., dot_meta, [receiver, name]}, meta, args},
         %Document{} = document,
         :type
       )
       when is_atom(name) and is_list(args) do
    [
      scan(receiver, document, :default),
      token(document, dot_meta[:line], dot_meta[:column], ".", :operator),
      token(document, meta[:line], meta[:column], Atom.to_string(name), :type),
      Enum.map(args, &scan(&1, document, :type))
    ]
  end

  defp scan(
         {{:., dot_meta, [receiver, name]}, meta, []},
         %Document{} = document,
         :capture
       )
       when is_atom(name) do
    [
      scan(receiver, document, :default),
      token(document, dot_meta[:line], dot_meta[:column], ".", :operator),
      token(document, meta[:line], meta[:column], Atom.to_string(name), :function)
    ]
  end

  defp scan(
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

    [
      scan(receiver, document, :default),
      token(document, dot_meta[:line], dot_meta[:column], ".", :operator),
      token(document, meta[:line], meta[:column], name_text, name_type),
      scan(args, document, :default)
    ]
  end

  defp scan({:__aliases__, _, _} = ast, %Document{} = document, _context) do
    range_token(ast, document, :namespace)
  end

  defp scan(
         {{:__block__, meta, [keyword]} = left, value},
         %Document{} = document,
         :block
       )
       when is_atom(keyword) do
    if MapSet.member?(@block_keywords, keyword) do
      [
        token(document, meta[:line], meta[:column], Atom.to_string(keyword), :keyword),
        scan(value, document, :default)
      ]
    else
      [
        scan(left, document, :default),
        scan(value, document, :default)
      ]
    end
  end

  defp scan({:<<>>, meta, parts} = ast, %Document{} = document, _context)
       when is_list(parts) do
    if is_binary(meta[:delimiter]) do
      if Enum.any?(parts, &(not is_binary(&1))) do
        interpolated_literal_tokens(ast, parts, document, :string)
      else
        range_tokens(ast, document, :string)
      end
    else
      [
        token(document, meta[:line], meta[:column], "<<", :operator),
        Enum.map(parts, &scan(&1, document, :bitstring)),
        closing_token(document, meta, ">>", :operator)
      ]
    end
  end

  defp scan(
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

  defp scan({:__block__, meta, [_value]} = ast, %Document{} = document, _context) do
    cond do
      is_binary(meta[:delimiter]) ->
        range_token(ast, document, :string)

      is_binary(meta[:token]) and number_token?(meta[:token]) ->
        range_token(ast, document, :number)

      true ->
        ast
        |> elem(2)
        |> Enum.map(&scan(&1, document, :default))
    end
  end

  defp scan({:__block__, _meta, nodes}, %Document{} = document, context)
       when is_list(nodes) do
    Enum.map(nodes, &scan(&1, document, context))
  end

  defp scan({:"::", meta, [left, right]}, %Document{} = document, :spec) do
    [
      scan(left, document, :spec_head),
      token(document, meta[:line], meta[:column], "::", :operator),
      scan(right, document, :type)
    ]
  end

  defp scan({:"::", meta, [left, right]}, %Document{} = document, :type_decl) do
    [
      scan(left, document, :type),
      token(document, meta[:line], meta[:column], "::", :operator),
      scan(right, document, :type)
    ]
  end

  defp scan({:"::", meta, [left, right]}, %Document{} = document, :bitstring) do
    [
      scan(left, document, :default),
      token(document, meta[:line], meta[:column], "::", :operator),
      scan(right, document, :bitstring_spec)
    ]
  end

  defp scan({form, meta, [head | rest]}, %Document{} = document, _context)
       when form in @definition_forms do
    [
      token(document, meta[:line], meta[:column], Atom.to_string(form), :keyword),
      block_tokens(document, meta),
      definition_head_tokens(head, document),
      Enum.map(rest, &scan(&1, document, :block))
    ]
  end

  defp scan({:fn, meta, clauses}, %Document{} = document, _context) do
    [
      token(document, meta[:line], meta[:column], "fn", :keyword),
      Enum.map(clauses, &fn_clause_tokens(&1, document)),
      closing_token(document, meta, "end", :keyword)
    ]
  end

  defp scan({form, meta, args}, %Document{} = document, _context)
       when form in @keyword_forms and is_list(args) do
    [
      token(document, meta[:line], meta[:column], Atom.to_string(form), :keyword),
      block_tokens(document, meta),
      Enum.map(args, &scan(&1, document, :block))
    ]
  end

  defp scan({name, meta, nil}, %Document{} = document, :type)
       when is_atom(name) do
    token_type =
      if operator?(name) do
        :operator
      else
        :type
      end

    token(document, meta[:line], meta[:column], Atom.to_string(name), token_type)
  end

  defp scan({name, meta, args}, %Document{} = document, :type)
       when is_atom(name) and is_list(args) do
    token_type =
      if operator?(name) do
        :operator
      else
        :type
      end

    [
      token(document, meta[:line], meta[:column], Atom.to_string(name), token_type),
      Enum.map(args, &scan(&1, document, :type))
    ]
  end

  defp scan({name, meta, args}, %Document{} = document, :spec_head)
       when is_atom(name) and is_list(args) do
    [
      token(document, meta[:line], meta[:column], Atom.to_string(name), :function),
      Enum.map(args, &scan(&1, document, :type))
    ]
  end

  defp scan({:/, meta, [target, arity]}, %Document{} = document, :capture) do
    [
      scan(target, document, :capture),
      token(document, meta[:line], meta[:column], "/", :operator),
      scan(arity, document, :default)
    ]
  end

  defp scan({name, meta, args}, %Document{} = document, :capture)
       when is_atom(name) and is_list(args) do
    token_type =
      if operator?(name) do
        :operator
      else
        :function
      end

    [
      token(document, meta[:line], meta[:column], Atom.to_string(name), token_type),
      Enum.map(args, &scan(&1, document, :default))
    ]
  end

  defp scan({name, meta, args}, %Document{} = document, :bitstring_spec)
       when is_atom(name) and is_list(args) do
    token_type =
      if operator?(name) do
        :operator
      else
        :keyword
      end

    [
      token(document, meta[:line], meta[:column], Atom.to_string(name), token_type),
      Enum.map(args, &scan(&1, document, :default))
    ]
  end

  defp scan({name, meta, nil}, %Document{} = document, :bitstring_spec)
       when is_atom(name) do
    token_type =
      if operator?(name) do
        :operator
      else
        :keyword
      end

    token(document, meta[:line], meta[:column], Atom.to_string(name), token_type)
  end

  defp scan({name, meta, nil}, %Document{} = document, :parameter)
       when is_atom(name) do
    token(document, meta[:line], meta[:column], Atom.to_string(name), :parameter)
  end

  defp scan({name, meta, nil}, %Document{} = document, _context)
       when is_atom(name) do
    token(document, meta[:line], meta[:column], Atom.to_string(name), :variable)
  end

  defp scan({name, meta, args}, %Document{} = document, _context)
       when is_atom(name) and is_list(args) do
    token_type =
      if operator?(name) do
        :operator
      else
        :function
      end

    [
      token(document, meta[:line], meta[:column], Atom.to_string(name), token_type),
      Enum.map(args, &scan(&1, document, :default))
    ]
  end

  defp scan({left, right}, %Document{} = document, context) do
    [
      scan(left, document, context),
      scan(right, document, :default)
    ]
  end

  defp scan(_other, _document, _context), do: []

  defp definition_head_tokens({:when, meta, [head | guards]}, %Document{} = document) do
    [
      token(document, meta[:line], meta[:column], "when", :operator),
      definition_head_tokens(head, document),
      Enum.map(guards, &scan(&1, document, :default))
    ]
  end

  defp definition_head_tokens({name, meta, args}, %Document{} = document)
       when is_atom(name) and is_list(args) do
    [
      token(document, meta[:line], meta[:column], Atom.to_string(name), :function),
      Enum.map(args, &scan(&1, document, :parameter))
    ]
  end

  defp definition_head_tokens(other, %Document{} = document) do
    scan(other, document, :parameter)
  end

  defp fn_clause_tokens({:->, meta, [params, body]}, %Document{} = document) do
    [
      token(document, meta[:line], meta[:column], "->", :operator),
      scan(params, document, :parameter),
      scan(body, document, :default)
    ]
  end

  defp fn_clause_tokens(other, %Document{} = document) do
    scan(other, document, :default)
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

    [do_token, end_token]
  end

  defp interpolated_literal_tokens(ast, parts, %Document{} = document, type)
       when is_list(parts) do
    case AstRange.fetch(ast, document) do
      {:ok, %Range{start: start, end: finish}} ->
        {tokens, cursor} =
          Enum.reduce(parts, {[], start}, fn
            literal, {acc, cursor} when is_binary(literal) ->
              {acc, cursor}

            interpolation, {acc, cursor} ->
              case AstRange.fetch(interpolation, document) do
                {:ok, %Range{start: interpolation_start, end: interpolation_end}} ->
                  tokens = [
                    acc,
                    span_tokens(document, cursor, interpolation_start, type),
                    interpolation_tokens(interpolation, document)
                  ]

                  {tokens, interpolation_end}

                :error ->
                  {acc, cursor}
              end
          end)

        [tokens, span_tokens(document, cursor, finish, type)]

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
      [
        token(
          document,
          interpolation_meta[:line],
          interpolation_meta[:column],
          ~S(#{),
          :operator
        ),
        scan(value, document, :default),
        closing_token(document, interpolation_meta, "}", :operator)
      ]
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
         {:ok, lsp_position} <- to_lsp_position(start) do
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

    case {text, to_lsp_position(start)} do
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
         {:ok, lsp_position} <- to_lsp_position(position) do
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

  defp flatten_tokens(token_tree) when is_list(token_tree) do
    List.flatten(token_tree)
  end

  defp flatten_tokens(token), do: [token]

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

  defp sigil_form?(form) when is_atom(form) do
    form
    |> Atom.to_string()
    |> String.starts_with?("sigil_")
  end

  defp operator?(form) do
    MapSet.member?(@textual_operators, form) or
      Atom.to_string(form) =~ ~r/^[[:punct:]]+$/
  end

  defp to_lsp_position(%Position{valid?: false}) do
    {:error, :invalid_position}
  end

  defp to_lsp_position(%Position{context_line: line(ascii?: true, text: text)} = position) do
    {:ok,
     %{
       line: position.line - position.starting_index,
       character: min(position.character - 1, byte_size(text))
     }}
  end

  defp to_lsp_position(%Position{context_line: line(text: utf8_text)} = position) do
    character = CodeUnit.utf8_position_to_utf16_offset(utf8_text, position.character - 1)

    {:ok,
     %{
       line: position.line - position.starting_index,
       character: min(character, CodeUnit.count(:utf16, utf8_text))
     }}
  end

  defp token_type_index(type) do
    Map.fetch!(@token_type_indexes, Atom.to_string(type))
  end
end
