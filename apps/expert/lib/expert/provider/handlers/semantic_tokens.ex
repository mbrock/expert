defmodule Expert.Provider.Handlers.SemanticTokens do
  @behaviour Expert.Provider.Handler

  alias Expert.CodeIntelligence.SemanticTokens
  alias Expert.Document.Context
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def handle(
        %Requests.TextDocumentSemanticTokensFull{
          params: %Structures.SemanticTokensParams{}
        },
        %Context{} = context
      ) do
    {:ok, SemanticTokens.full(context.document)}
  end
end
