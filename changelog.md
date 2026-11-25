# Change Log

This file documents all significant changes made to the Ballerina `ai.google.gemini` package across releases.

## [Un-released]

### Added
- OAuth 2.0 authentication. The `apiKey` parameter of `ModelProvider` and `EmbeddingProvider` also accepts an
  `OAuth2RefreshConfig` (a refresh token that the HTTP client exchanges for access tokens and refreshes, with an
  optional quota project sent in `x-goog-user-project`) or a `BearerTokenConfig` (an access token that is not
  refreshed, with the same optional quota project). A `string` is still an API key, sent in `x-goog-api-key`.
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
