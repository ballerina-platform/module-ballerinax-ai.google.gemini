## Overview

[Google Gemini](https://ai.google.dev/) is a family of multimodal large language models that support text generation, reasoning, function calling, and embeddings.

The `ai.google.gemini` connector plugs Gemini into the Ballerina [`ai`](https://central.ballerina.io/ballerina/ai) agent framework. It implements the framework's `ModelProvider` and `EmbeddingProvider` interfaces, so any agent built on `ballerina/ai` can use Gemini for chat, structured generation, and embeddings.

### Key features

- Connect and interact with Gemini large language models
- Native tool/function calling
- Structured output via Gemini's native JSON mode (`responseJsonSchema`)
- Multimodal input — images, PDFs, and Gemini File API references, through `generate`
- Text and embedding model support (`embed` / `batchEmbed`)
- Secure communication using API-key authentication

### Scope and limitations

- **`chat` accepts text only.** Images, PDFs, and other documents are supported through `generate` (see [Multimodal input](#multimodal-input)); passing a non-text `ai:Document` to `chat` returns an error.
- **Streaming is not available.** The `ai:ModelProvider` interface defines only `chat` and `generate`, so there is no streaming API to implement.
- **Gemini Developer API only.** Vertex AI endpoints (`{location}-aiplatform.googleapis.com`, OAuth bearer credentials, `publishers/google/models/...` paths) are not supported.
- **Document URLs are fetched by the connector.** Gemini cannot fetch arbitrary web URLs, so an `ai:Url` in a prompt is downloaded locally and sent inline. Only `http` and `https` are accepted. Internal destinations (loopback, private, link-local, carrier-grade-NAT) are permitted by default, so documents served from an internal host work out of the box. If document URLs may come from an untrusted source, set `allowPrivateDocumentHosts` to `false` — the connector then rejects those destinations on the initial request and on every redirect. Note the check applies to the literal host in the URL: a public DNS name that resolves to an internal address is not detected, so deployments handling untrusted URLs should also enforce an egress policy at the network layer.

## Prerequisites

Before using this module, obtain the configuration required to engage the LLM.

- Create a Google account and sign in to [Google AI Studio](https://aistudio.google.com/).
- Generate an API key from [Google AI Studio](https://aistudio.google.com/app/apikey).

## Quickstart

To use the `ai.google.gemini` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

```ballerina
import ballerinax/ai.google.gemini;
```

### Step 2: Initialize the Model Provider

```ballerina
import ballerina/ai;
import ballerinax/ai.google.gemini;

final ai:ModelProvider geminiModel = check new gemini:ModelProvider("<API_KEY>", gemini:GEMINI_3_6_FLASH);
```

### Step 3: Invoke the model

```ballerina
import ballerina/ai;
import ballerina/io;
import ballerinax/ai.google.gemini;

public function main() returns error? {
    ai:ChatAssistantMessage response = check geminiModel->chat(
        [{role: ai:USER, content: "Explain Ballerina in one sentence."}], []);
    io:println(response.content);
}
```

### Using the Embedding Provider

```ballerina
import ballerina/ai;
import ballerinax/ai.google.gemini;

final ai:EmbeddingProvider embeddingModel =
    check new gemini:EmbeddingProvider("<API_KEY>", gemini:GEMINI_EMBEDDING_2);

public function main() returns error? {
    ai:TextChunk chunk = {content: "Ballerina is a cloud-native language."};
    ai:Embedding embedding = check embeddingModel->embed(chunk);
}
```

## Multimodal input

Images, PDFs, and files already uploaded to the Gemini File API can be sent through `generate`:

```ballerina
import ballerina/ai;
import ballerinax/ai.google.gemini;

public function main() returns error? {
    ai:ImageDocument image = {content: "https://example.com/chart.png"};
    string description = check geminiModel->generate(`Describe this image: ${image}`);
}
```

When a document is supplied as a URL, **the connector downloads it and forwards the bytes inline** — Gemini does not fetch arbitrary web URLs itself. Two consequences:

- The download is an outbound request from your service to a caller-influenced address. Treat prompt-supplied URLs as untrusted input.
- Documents larger than 20 MiB are rejected, matching Gemini's inline-request ceiling.

To avoid the download entirely, upload via the Gemini File API and pass the resulting `ai:FileId`.

## Model selection

`GEMINI_3_6_FLASH` is the current flagship Flash model and the recommended default. The `GEMINI_MODEL_NAMES` enum documents the status of every supported model, including shutdown dates for those scheduled for retirement — the `gemini-2.5` line retires on 2026-10-16.

For embeddings, `GEMINI_EMBEDDING_2` is the current model. `GEMINI_EMBEDDING_001` remains supported for text-only use cases.

> **Note:** the embedding spaces of the two embedding models are **not compatible**. Switching between them requires re-embedding all previously stored data.

## Generation settings

### Thinking tokens and `maxTokens`

Gemini 2.5 models and later perform internal reasoning by default, and **reasoning tokens are billed against `maxOutputTokens`**. A small token cap can therefore be consumed entirely by reasoning, returning a response with `finishReason` `MAX_TOKENS` and no text at all.

`maxTokens` defaults to 65,536 — the models' own maximum output limit — so this does not happen out of the box. It is a ceiling, not a target: billing follows the tokens actually produced.

### Temperature

`temperature` is **unset by default**, so the model's own default applies. Google [strongly recommends](https://ai.google.dev/gemini-api/docs/gemini-3) leaving it at the default of `1.0` for Gemini 3 models — lowering it "may lead to unexpected behavior, such as looping or degraded performance, particularly in complex mathematical or reasoning tasks."

### Schemas

Tool parameters and structured-output schemas are sent through Gemini's standard-JSON-Schema fields (`parametersJsonSchema` and `responseJsonSchema`), which accept `$ref`, `$defs`, `additionalProperties`, `title`, and `prefixItems`. Only the `oneOf` and `allOf` combinators are rewritten, to the documented `anyOf`.

## Authentication

Requests are authenticated with the Gemini API key, sent automatically as the `x-goog-api-key` header. Pass the key when constructing the provider.

> **Note:** because Gemini uses a custom API-key header rather than a standard scheme, the key cannot be supplied through `http:ClientAuthConfig`. Enabling HTTP trace or access logging will therefore record the key. Avoid trace logging in production.

## Rate limits and retries

Gemini enforces [per-model rate limits](https://ai.google.dev/gemini-api/docs/rate-limits); exceeding them returns a 429 with status `RESOURCE_EXHAUSTED`, which the connector surfaces as an error naming that status.

No retry policy is applied by default, because `generateContent` is a billed, non-idempotent request and silent retries could duplicate a charged generation. To opt in, supply a `retryConfig` through the connection configuration:

```ballerina
final ai:ModelProvider geminiModel = check new gemini:ModelProvider(
    "<API_KEY>",
    gemini:GEMINI_3_6_FLASH,
    retryConfig = {count: 3, interval: 2, statusCodes: [429, 503]}
);
```

## Report issues

To report bugs, request new features, start new discussions, view project roadmaps, and track issues, go to the [Ballerina library parent repository](https://github.com/ballerina-platform/ballerina-library).

## Useful links

- Chat live with us on our [Discord server](https://discord.gg/ballerinalang).
- Post technical questions on Stack Overflow with the [#ballerina](https://stackoverflow.com/questions/tagged/ballerina) tag.
- For more information go to the [`ai.google.gemini` package](https://central.ballerina.io/ballerinax/ai.google.gemini/latest).
