defmodule Expert.Provider.Handlers.SemanticTokens do
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Context
  alias Forge.CodeIntelligence.SyntacticTokens
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentSemanticTokensFull{
          params: %Structures.SemanticTokensParams{}
        },
        %Context{} = context
      ) do
    {:ok, SyntacticTokens.full(context.document)}
  end
end
