// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;

# Configurations for controlling the behaviours when communicating with a remote HTTP endpoint.
@display {label: "Connection Configuration"}
public type ConnectionConfig record {|

    # The HTTP version understood by the client
    @display {label: "HTTP Version"}
    http:HttpVersion httpVersion = http:HTTP_2_0;

    # Configurations related to HTTP/1.x protocol
    @display {label: "HTTP1 Settings"}
    http:ClientHttp1Settings http1Settings?;

    # Configurations related to HTTP/2 protocol
    @display {label: "HTTP2 Settings"}
    http:ClientHttp2Settings http2Settings?;

    # The maximum time to wait (in seconds) for a response before closing the connection
    @display {label: "Timeout"}
    decimal timeout = 60;

    # The choice of setting `forwarded`/`x-forwarded` header
    @display {label: "Forwarded"}
    string forwarded = "disable";

    # Configurations associated with request pooling
    @display {label: "Pool Configuration"}
    http:PoolConfiguration poolConfig?;

    # HTTP caching related configurations
    @display {label: "Cache Configuration"}
    http:CacheConfig cache?;

    # Specifies the way of handling compression (`accept-encoding`) header
    @display {label: "Compression"}
    http:Compression compression = http:COMPRESSION_AUTO;

    # Configurations associated with the behaviour of the Circuit Breaker
    @display {label: "Circuit Breaker Configuration"}
    http:CircuitBreakerConfig circuitBreaker?;

    # Configurations associated with retrying
    @display {label: "Retry Configuration"}
    http:RetryConfig retryConfig?;

    # Configurations associated with inbound response size limits
    @display {label: "Response Limit Configuration"}
    http:ResponseLimitConfigs responseLimits?;

    # SSL/TLS-related options
    @display {label: "Secure Socket Configuration"}
    http:ClientSecureSocket secureSocket?;

    # Proxy server related options
    @display {label: "Proxy Configuration"}
    http:ProxyConfig proxy?;

    # Enables the inbound payload validation functionality which provided by the constraint package. Enabled by default
    @display {label: "Payload Validation"}
    boolean validation = true;
|};

# Text-generation (`:generateContent`) model types for Gemini.
# Reference: https://ai.google.dev/gemini-api/docs/models
# NOTE: Gemini's model lineup changes frequently. Verify these IDs against the live
# `/v1beta/models` listing for your API version; older deployments may still expose
# the 2.x line, and newer ones may add models not listed here. Non-text models
# (TTS/audio, image/video generation, embeddings) are intentionally excluded.
@display {label: "Gemini Model Names"}
public enum GEMINI_MODEL_NAMES {
    # Generally available since 2026-07-21. The current flagship Flash model and the
    # recommended default for new integrations.
    GEMINI_3_6_FLASH = "gemini-3.6-flash",
    # Generally available since 2026-05-19.
    GEMINI_3_5_FLASH = "gemini-3.5-flash",
    # Generally available since 2026-07-21. The recommended low-cost tier.
    GEMINI_3_5_FLASH_LITE = "gemini-3.5-flash-lite",
    # Generally available since 2026-05-07. Scheduled for shutdown on 2027-05-07;
    # migrate to `GEMINI_3_5_FLASH_LITE`.
    GEMINI_3_1_FLASH_LITE = "gemini-3.1-flash-lite",
    # Preview model, available since 2026-02-19. Preview models may change or be
    # withdrawn at short notice; avoid depending on them in production.
    GEMINI_3_1_PRO_PREVIEW = "gemini-3.1-pro-preview",
    # Preview model, available since 2025-12-17. Superseded by `GEMINI_3_6_FLASH`,
    # though no shutdown date has been announced.
    GEMINI_3_FLASH_PREVIEW = "gemini-3-flash-preview",
    # Scheduled for shutdown on 2026-10-16; migrate to `GEMINI_3_1_PRO_PREVIEW`.
    # Note: thinking cannot be disabled on this model.
    GEMINI_2_5_PRO = "gemini-2.5-pro",
    # Scheduled for shutdown on 2026-10-16; migrate to `GEMINI_3_6_FLASH`.
    GEMINI_2_5_FLASH = "gemini-2.5-flash",
    # Scheduled for shutdown on 2026-10-16; migrate to `GEMINI_3_5_FLASH_LITE`.
    GEMINI_2_5_FLASH_LITE = "gemini-2.5-flash-lite"
}

# Embedding (`:embedContent`) model types for Gemini.
# Reference: https://ai.google.dev/gemini-api/docs/embeddings
# NOTE: Verify against the live `/v1beta/models` listing before relying on these.
@display {label: "Gemini Embedding Model Names"}
public enum GEMINI_EMBEDDING_MODEL_NAMES {
    # The current model and the first multimodal embedding model in the Gemini API,
    # mapping text, images, video, audio, and documents into a unified embedding space.
    # Recommended for new integrations. For text-only tasks, task instructions are given
    # directly in the prompt rather than through a task-type parameter.
    GEMINI_EMBEDDING_2 = "gemini-embedding-2",
    # Remains available and supported for text-only use cases. Uses an explicit task-type
    # parameter to optimise embeddings for the intended relationship.
    #
    # Note: the embedding spaces of the two models are incompatible. Switching between
    # them requires re-embedding all previously stored data.
    GEMINI_EMBEDDING_001 = "gemini-embedding-001"
}

// ── Gemini wire types (generateContent) ────────────────────────────────────
// Hand-written records modelling the subset of the Gemini `generateContent`
// REST API that this connector uses. Records consumed from responses are kept
// open (`record { }`) so that fields we do not model (e.g. safetyRatings,
// citationMetadata, avgLogprobs) are tolerated during binding rather than
// causing conversion failures.
// Reference: https://ai.google.dev/api/generate-content

# Inline binary data carried within a content part (e.g. an image), base64-encoded.
type InlineData record {
    # IANA media type of the data, e.g. "image/png"
    string mimeType;
    # Base64-encoded bytes of the data
    string data;
};

# A reference to a file the model should read, by URI. Used for content already
# uploaded via the Gemini File API (the URI returned by the upload). Gemini does
# not fetch arbitrary web URLs here, so ordinary image/document URLs are downloaded
# by the connector and sent as `InlineData` instead.
type FileData record {
    # IANA media type of the referenced file, e.g. "application/pdf". Optional;
    # Gemini can infer it for File API URIs
    string mimeType?;
    # URI of the file, e.g. a Gemini File API URI
    string fileUri;
};

# A function call requested by the model within a candidate part.
type FunctionCall record {
    # Correlation identifier for the call. Gemini emits this when several functions are
    # called in one turn, and the matching `FunctionResponse` must echo it back so results
    # can be attributed to the right call
    string id?;
    # Name of the function the model intends to call
    string name;
    # Structured arguments for the call, as a JSON object
    map<json> args?;
};

# The result of a tool/function execution, fed back to the model.
type FunctionResponse record {|
    # Correlation identifier echoed from the originating `FunctionCall`. Required to
    # disambiguate results when the model issued several parallel calls of the same name
    string id?;
    # Name of the function that was executed
    string name;
    # The function's result payload, as a JSON object
    map<json> response;
|};

# A single piece of content. A part holds exactly one of the optional members;
# the others are absent.
type Part record {
    # Plain text content
    string text?;
    # Inline binary data (e.g. an image or PDF)
    InlineData inlineData?;
    # A reference to a file by URI (e.g. a Gemini File API URI)
    FileData fileData?;
    # A function call requested by the model
    FunctionCall functionCall?;
    # A tool result supplied back to the model
    FunctionResponse functionResponse?;
};

# An ordered collection of parts attributed to a single role.
type Content record {
    # Author of the content: "user" (input) or "model" (model output). Omitted
    # for `systemInstruction`.
    string role?;
    # The ordered parts that make up this content
    Part[] parts;
};

# Declares a function the model may call, described with a JSON-schema parameter object.
type FunctionDeclaration record {|
    # Function name
    string name;
    # Natural-language description of what the function does
    string description?;
    # Function parameters described with Gemini's OpenAPI 3.0 schema subset. Mutually
    # exclusive with `parametersJsonSchema`.
    map<json> parameters?;
    # Function parameters described with standard JSON Schema. Supported on Gemini 2.5
    # models and later, and accepts keywords the `parameters` subset rejects, including
    # `$ref`, `$defs`, `additionalProperties`, and `prefixItems`. Mutually exclusive
    # with `parameters`.
    map<json> parametersJsonSchema?;
|};

# A group of tools made available to the model.
type Tool record {|
    # Function declarations the model may call
    FunctionDeclaration[] functionDeclarations?;
|};

# Controls how the model selects functions to call.
type FunctionCallingConfig record {|
    # Calling mode: "AUTO" (model decides), "ANY" (must call a function),
    # or "NONE" (never call)
    string mode?;
    # When mode is "ANY", restricts the model to these function names
    string[] allowedFunctionNames?;
|};

# Tool-related configuration for a request.
type ToolConfig record {|
    # Function-calling behaviour configuration
    FunctionCallingConfig functionCallingConfig?;
|};

# Generation parameters controlling sampling and output shape.
type GenerationConfig record {|
    # Sampling temperature
    decimal temperature?;
    # Upper bound on tokens generated in the response
    int maxOutputTokens?;
    # Sequences that, when produced, stop generation
    string[] stopSequences?;
    # Forces a response MIME type, e.g. "application/json" for structured output
    string responseMimeType?;
    # Structured-response schema in Gemini's OpenAPI 3.0 subset (used with
    # `responseMimeType` = "application/json"). Mutually exclusive with
    # `responseJsonSchema`.
    map<json> responseSchema?;
    # Structured-response schema in standard JSON Schema. Supported on Gemini 2.5 models
    # and later, and accepts keywords the `responseSchema` subset rejects, including
    # `$ref`, `$defs`, `additionalProperties`, and `prefixItems`. `responseMimeType` is
    # still required. Mutually exclusive with `responseSchema` — Gemini rejects requests
    # that set both.
    map<json> responseJsonSchema?;
|};

# A single safety category/threshold pairing.
type SafetySetting record {|
    # Harm category, e.g. "HARM_CATEGORY_HARASSMENT"
    string category;
    # Blocking threshold, e.g. "BLOCK_NONE"
    string threshold;
|};

# Request body for `:generateContent`.
type GenerateContentRequest record {|
    # The conversation contents, ordered oldest to newest
    Content[] contents;
    # System-level instruction applied to the whole request
    Content systemInstruction?;
    # Tools the model may use
    Tool[] tools?;
    # Tool-calling configuration
    ToolConfig toolConfig?;
    # Sampling and output configuration
    GenerationConfig generationConfig?;
    # Safety category thresholds
    SafetySetting[] safetySettings?;
|};

# A single generated candidate within a response.
type Candidate record {
    # The generated content
    Content content?;
    # Why generation stopped, e.g. "STOP", "MAX_TOKENS", "SAFETY"
    string finishReason?;
    # Index of this candidate in the list
    int index?;
};

# Token accounting for a request/response.
type UsageMetadata record {
    # Tokens counted in the prompt
    int promptTokenCount?;
    # Tokens counted across all generated candidates. Note this **excludes** tokens spent
    # on internal reasoning — see `thoughtsTokenCount`
    int candidatesTokenCount?;
    # Tokens spent on internal reasoning. Billed as output, but reported separately from
    # `candidatesTokenCount`, so output cost is under-reported if this is ignored — by a
    # wide margin on thinking models
    int thoughtsTokenCount?;
    # Tokens served from cached content, billed at a reduced rate
    int cachedContentTokenCount?;
    # Tokens consumed by tool-use prompts
    int toolUsePromptTokenCount?;
    # Total tokens across every category above
    int totalTokenCount?;
};

# A safety rating for a single harm category.
type SafetyRating record {
    # Harm category, e.g. "HARM_CATEGORY_HARASSMENT"
    string category?;
    # Assessed probability, e.g. "NEGLIGIBLE", "LOW", "MEDIUM", "HIGH"
    string probability?;
    # Whether the content was blocked due to this rating
    boolean blocked?;
};

# Feedback about the prompt itself, populated when Gemini returns no candidates
# because the prompt was blocked.
type PromptFeedback record {
    # Reason the prompt was blocked, e.g. "SAFETY", "OTHER", "BLOCKLIST",
    # "PROHIBITED_CONTENT", "IMAGE_SAFETY"
    string blockReason?;
    # Per-category safety ratings for the prompt
    SafetyRating[] safetyRatings?;
};

# Response body for `:generateContent`.
type GenerateContentResponse record {
    # Identifier for this response, useful for correlating traces with Gemini-side logs
    string responseId?;
    # Generated candidates; multiple only when more than one was requested
    Candidate[] candidates?;
    # Feedback about the prompt, including a block reason when the prompt is rejected
    PromptFeedback promptFeedback?;
    # Token accounting for the request
    UsageMetadata usageMetadata?;
    # The concrete model version that served the request
    string modelVersion?;
};

// ── Gemini embedding wire types (embedContent / batchEmbedContents) ─────────

# Request body for `:embedContent`.
type EmbedContentRequest record {|
    # The model resource name, e.g. "models/gemini-embedding-2"
    string model;
    # The content to embed
    Content content;
|};

# An embedding vector.
type ContentEmbedding record {
    # The embedding values
    float[] values;
};

# Response body for `:embedContent`.
type EmbedContentResponse record {
    # The generated embedding
    ContentEmbedding embedding;
    # Token accounting for the embedding request, when reported
    UsageMetadata usageMetadata?;
};

# Request body for `:batchEmbedContents`.
type BatchEmbedContentsRequest record {|
    # The individual embedding requests, one per input
    EmbedContentRequest[] requests;
|};

# Response body for `:batchEmbedContents`.
type BatchEmbedContentsResponse record {
    # The generated embeddings, in request order
    ContentEmbedding[] embeddings;
};
