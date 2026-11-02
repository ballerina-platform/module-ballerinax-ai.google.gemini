# Change Log

This file documents all significant changes made to the Ballerina `ai.google.gemini` package across releases.

## [Un-released]

### Added
- Initial implementation of the Gemini connector for the `ballerina/ai` framework.
  - `ModelProvider` — `chat` and structured `generate` backed by Gemini's `:generateContent` REST API.
  - `EmbeddingProvider` — `embed` and `batchEmbed` backed by `:embedContent` / `:batchEmbedContents`.
  - Native function calling (tool use) and structured output through Gemini's standard-JSON-Schema
    fields (`parametersJsonSchema` / `responseJsonSchema`), which accept `$ref`, `$defs`,
    `additionalProperties` and `prefixItems` without modification.
  - Gemini 3 thought signatures preserved across tool-call round trips, including parallel calls,
    which the API requires when a model turn is replayed in the conversation history.
  - Multimodal input through `generate` — images, PDFs, and Gemini File API references.
  - API-key authentication via the `x-goog-api-key` header.
- Streaming support, completing the `ai:ModelProvider` contract.
  - `chatAsStream` — streams flat `ai:ChatMessageChunk` values over Gemini's
    `:streamGenerateContent?alt=sse` endpoint, normalizing text, reasoning, tool calls and
    finish reasons onto the provider-agnostic shape. `role` is set to `ai:ASSISTANT` on
    every chunk.
  - `generateAsStream` — streams the generated answer as text fragments only. Its request
    is built from the prompt the same way `generate`'s is, so — unlike `chatAsStream` — it
    may carry images, PDFs and `ai:FileId` insertions.
  - Gemini's `"STOP"` finish reason is reported as `tool_calls` when the turn ends in a
    function call, so an agent loop does not mistake a pending tool call for a final answer.
  - Thought signatures are preserved on streamed tool calls, so a streamed model turn can be
    replayed in the conversation history on Gemini 3 models.
  - Chain-of-thought parts are surfaced through `reasoning` rather than being folded into
    the answer text.
  - A failure the API reports mid-stream — an `{"error": ...}` frame on an already-2xx
    stream, a prompt rejected by the safety filters, or an unparseable frame — ends the
    stream with a typed `ai:Error` instead of being skipped, which would have truncated the
    answer and reported it as a normal completion.
  - Streamed calls open an `observe:ChatSpan`/`observe:GenerateContentSpan` like `chat`/
    `generate` do, carrying prompts, tools, token usage and the finish reason; the iterator
    closes it when the stream ends.
  - The SSE stream and its connection are released when a stream ends in failure, and a
    stream that has already ended is not read again.
