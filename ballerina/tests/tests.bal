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

import ballerina/ai;
import ballerina/test;

const SERVICE_URL = "http://localhost:8080/llm";
const API_KEY = "not-a-real-api-key";
const UNSUPPORTED_DOC_ERROR = "Only text, image and file documents are supported.";
// Served by the mock asset endpoint so the URL-download path can be exercised.
const IMAGE_URL = "http://localhost:8080/llm/assets/sample.png";
const PDF_URL = "http://localhost:8080/llm/assets/sample.pdf";
// 302s to IMAGE_URL, for the manual redirect loop.
const REDIRECT_IMAGE_URL = "http://localhost:8080/llm/redirect/sample.png";

// The mock serves document assets from loopback, which the default (`true`) permits.
final ModelProvider provider = check new (API_KEY, GEMINI_2_5_FLASH, SERVICE_URL);
// Opted out, so the destination check itself can be exercised.
final ModelProvider strictProvider = check new (API_KEY, GEMINI_2_5_FLASH, SERVICE_URL,
        allowPrivateDocumentHosts = false);
final EmbeddingProvider embeddingProvider = check new (API_KEY, GEMINI_EMBEDDING_2, SERVICE_URL);

// ── chat ───────────────────────────────────────────────────────────────────

@test:Config
function testChatWithTextResponse() returns ai:Error? {
    ai:ChatAssistantMessage result = check provider->chat([{role: ai:USER, content: "Say hello"}], []);
    test:assertEquals(result.content, "Hello there!");
}

@test:Config
function testChatWithNonTextDocumentReturnsError() {
    // README: "passing a non-text `ai:Document` to `chat` returns an error". This must be
    // a returned `ai:Error`, not a panic — the telemetry conversion in `chat` runs before
    // the request is built, so an error escaping it as a panic would crash the caller.
    ai:ImageDocument image = {content: sampleBinaryData, metadata: {mimeType: "image/png"}};
    ai:ChatAssistantMessage|ai:Error result = provider->chat([
        {role: ai:USER, content: "Say hello"},
        {role: ai:USER, content: `describe ${image}`}
    ], []);
    test:assertTrue(result is ai:Error, "expected an ai:Error for a non-text document in chat");
    test:assertEquals((<ai:Error>result).message(), "Only Text Documents are currently supported.");
}

@test:Config
function testChatWithToolCall() returns ai:Error? {
    ai:ChatCompletionFunctions weatherTool = {
        name: "getWeather",
        description: "Get the weather for a city",
        parameters: {"type": "object", "properties": {"city": {"type": "string"}}}
    };
    ai:ChatAssistantMessage result =
        check provider->chat([{role: ai:USER, content: "What's the weather in Colombo?"}], [weatherTool]);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[], "expected tool calls in the response");
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "getWeather");
}

@test:Config
function testChatWithoutTools() returns ai:Error? {
    // `tools` defaults to [] when omitted (no tools passed).
    ai:ChatAssistantMessage result = check provider->chat([{role: ai:USER, content: "Say hello"}]);
    test:assertEquals(result.content, "Hello there!");
    test:assertTrue(result.toolCalls is (), "expected no tool calls when no tools are provided");
}

@test:Config
function testChatWithMultipleTools() returns ai:Error? {
    ai:ChatCompletionFunctions weatherTool = {
        name: "getWeather",
        description: "Get the weather for a city",
        parameters: {"type": "object", "properties": {"city": {"type": "string"}}}
    };
    ai:ChatCompletionFunctions timeTool = {
        name: "getTime",
        description: "Get the current time for a city",
        parameters: {"type": "object", "properties": {"city": {"type": "string"}}}
    };
    ai:ChatAssistantMessage result =
        check provider->chat([{role: ai:USER, content: "What's the weather using two tools in Colombo?"}],
            [weatherTool, timeTool]);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[], "expected a tool call in the response");
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "getWeather");
}

@test:Config
function testChatWithSystemMessage() returns ai:Error? {
    ai:ChatAssistantMessage result = check provider->chat([
        {role: ai:SYSTEM, content: "You are a helpful assistant."},
        {role: ai:USER, content: "System check please"}
    ], []);
    test:assertEquals(result.content, "System instruction received.");
}

@test:Config
function testChatMultiTurnToolConversation() returns ai:Error? {
    ai:ChatMessage[] messages = [
        {role: ai:USER, content: "Weather follow-up for Paris"},
        {role: ai:ASSISTANT, toolCalls: [{name: "getWeather", arguments: {city: "Paris"}}]},
        {role: "function", name: "getWeather", content: "{\"temperature\": 20}"}
    ];
    ai:ChatAssistantMessage result = check provider->chat(messages, []);
    test:assertEquals(result.content, "It is 20 degrees in Paris.");
}

@test:Config
function testChatSendsToolSchemaAsJsonSchema() returns ai:Error? {
    ai:ChatCompletionFunctions tool = {
        name: "getWeather",
        description: "Get the weather for a city",
        parameters: {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "title": "WeatherParams",
            "$ref": "#/$defs/City",
            "default": {},
            "additionalProperties": false,
            "type": "object",
            "properties": {"city": {"type": "string", "default": "Colombo"}}
        }
    };
    ai:ChatAssistantMessage result =
        check provider->chat([{role: ai:USER, content: "Tool schema passthrough test"}], [tool]);
    test:assertTrue(result.toolCalls is ai:FunctionCall[], "expected a tool call in the response");
}

@test:Config
function testChatWithStopSequence() returns ai:Error? {
    ai:ChatAssistantMessage result =
        check provider->chat([{role: ai:USER, content: "Stop test"}], [], "END");
    test:assertEquals(result.content, "Stopping now.");
}

@test:Config
function testChatTruncatedByThinkingReturnsError() returns error? {
    // Thinking tokens are billed against maxOutputTokens, so a candidate can come back
    // with finishReason MAX_TOKENS and no text part. That must be an actionable error,
    // not an assistant message with content = ().
    ai:ChatAssistantMessage|ai:Error result =
        provider->chat([{role: ai:USER, content: "Truncated by thinking"}], []);
    test:assertTrue(result is ai:LlmInvalidResponseError,
            "a candidate with no usable content must surface as ai:LlmInvalidResponseError");
    string message = (<ai:Error>result).message();
    test:assertTrue(message.includes("MAX_TOKENS"), "the error must name the finishReason");
    test:assertTrue(message.includes("maxTokens"),
            "the error should point at the thinking-token cause");
}

@test:Config
function testChatSafetyFinishReasonReturnsError() returns error? {
    ai:ChatAssistantMessage|ai:Error result =
        provider->chat([{role: ai:USER, content: "Safety filtered"}], []);
    test:assertTrue(result is ai:LlmInvalidResponseError,
            "a SAFETY-filtered candidate must surface as ai:LlmInvalidResponseError");
    test:assertTrue((<ai:Error>result).message().includes("SAFETY"),
            "the error must name the finishReason");
}

@test:Config
function testChatBlockedPromptReturnsError() returns error? {
    ai:ChatAssistantMessage|ai:Error result =
        provider->chat([{role: ai:USER, content: "Blocked prompt"}], []);
    test:assertTrue(result is ai:LlmInvalidResponseError,
            "a blocked prompt must surface as ai:LlmInvalidResponseError");
    test:assertTrue((<ai:Error>result).message().includes("PROHIBITED_CONTENT"),
            "the error must name the promptFeedback block reason");
}

@test:Config
function testChatNormalizesOneOfToAnyOf() returns ai:Error? {
    // Nilable and union types produce `oneOf`, which Gemini does not document as
    // supported. It must be rewritten to `anyOf`; the mock asserts the wire shape.
    ai:ChatCompletionFunctions tool = {
        name: "setValue",
        description: "Sets an optional value",
        parameters: {
            "type": "object",
            "properties": {
                "value": {"oneOf": [{"type": "string"}, {"type": "null"}]}
            }
        }
    };
    _ = check provider->chat([{role: ai:USER, content: "Union schema test"}], [tool]);
}

@test:Config
function testChatToolResultWithJsonArrayStaysStructured() returns ai:Error? {
    // A tool returning a JSON array must reach the model as {"result":[1,2,3]}, not
    // {"result":"[1,2,3]"}. The mock asserts the wire shape.
    ai:ChatMessage[] messages = [
        {role: ai:USER, content: "Array tool result"},
        {role: ai:ASSISTANT, toolCalls: [{name: "getScores", arguments: {}}]},
        {role: "function", name: "getScores", content: "[1, 2, 3]"}
    ];
    _ = check provider->chat(messages, []);
}

@test:Config
function testChatToolCallIdRoundTrips() returns ai:Error? {
    // Gemini emits an `id` on parallel function calls; it must survive into
    // ai:FunctionCall so results can be attributed to the right call.
    ai:ChatAssistantMessage result =
        check provider->chat([{role: ai:USER, content: "What's the weather in Colombo?"}], []);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[], "expected a tool call");
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].id, "call-1",
            "the functionCall id must be carried into ai:FunctionCall");
}

@test:Config
function testChatMultipleSystemMessagesAreSeparated() returns ai:Error? {
    // Gemini concatenates systemInstruction parts with no separator, so without an
    // explicit newline the two instructions would run together.
    // The mock dispatches on the first *user* text, so that carries the marker.
    _ = check provider->chat([
        {role: ai:SYSTEM, content: "Be concise."},
        {role: ai:SYSTEM, content: "You are a helpful assistant."},
        {role: ai:USER, content: "Multi system check"}
    ], []);
}

@test:Config
function testChatApiErrorSurfacesGeminiEnvelope() returns error? {
    // A 400 is not a connection problem. It must not be reported as one, and the
    // API's own error envelope must reach the caller.
    ai:ChatAssistantMessage|ai:Error result =
        provider->chat([{role: ai:USER, content: "Trigger API error"}], []);
    test:assertTrue(result is ai:Error, "a 4xx must surface as an error");
    ai:Error err = <ai:Error>result;
    test:assertFalse(err is ai:LlmConnectionError,
            "a 400 must not be reported as ai:LlmConnectionError");
    string message = err.message();
    test:assertTrue(message.includes("400"), "the error must name the HTTP status");
    test:assertTrue(message.includes("INVALID_ARGUMENT"),
            "the error must carry Gemini's error.status");
    test:assertTrue(message.includes("Invalid JSON payload received."),
            "the error must carry Gemini's error.message");
}

@test:Config
function testChatAuthErrorIsNotAConnectionError() returns error? {
    ai:ChatAssistantMessage|ai:Error result =
        provider->chat([{role: ai:USER, content: "Trigger auth error"}], []);
    test:assertTrue(result is ai:Error, "a 401 must surface as an error");
    ai:Error err = <ai:Error>result;
    test:assertFalse(err is ai:LlmConnectionError,
            "an invalid API key is not a connection failure");
    test:assertTrue(err.message().includes("UNAUTHENTICATED"),
            "the error must name Gemini's status so the cause is actionable");
}

@test:Config
function testChatRateLimitIsNotAConnectionError() returns error? {
    ai:ChatAssistantMessage|ai:Error result =
        provider->chat([{role: ai:USER, content: "Trigger rate limit"}], []);
    test:assertTrue(result is ai:Error, "a 429 must surface as an error");
    ai:Error err = <ai:Error>result;
    test:assertFalse(err is ai:LlmConnectionError,
            "a rate limit is not a connection failure");
    test:assertTrue(err.message().includes("RESOURCE_EXHAUSTED"),
            "the error must name Gemini's status so callers can back off");
}

@test:Config
function testChatToolResultWithScalarStaysStructured() returns ai:Error? {
    // A tool returning a bare number must reach the model as {"result":42}, not
    // {"result":"42"} — the same class of bug as the array case.
    ai:ChatMessage[] messages = [
        {role: ai:USER, content: "Scalar tool result"},
        {role: ai:ASSISTANT, toolCalls: [{name: "getCount", arguments: {}}]},
        {role: "function", name: "getCount", content: "42"}
    ];
    _ = check provider->chat(messages, []);
}

// ── telemetry ───────────────────────────────────────────────────────────────

@test:Config
function testOutputTokenCountIncludesThinkingTokens() {
    // Reasoning tokens are billed as output but reported separately. Counting only
    // candidatesTokenCount under-reports cost — here by 9x.
    test:assertEquals(totalOutputTokenCount({candidatesTokenCount: 5, thoughtsTokenCount: 40}), 45,
            "output tokens must include thoughtsTokenCount");
    test:assertEquals(totalOutputTokenCount({candidatesTokenCount: 5}), 5,
            "a response without reasoning tokens must report candidate tokens unchanged");
    test:assertEquals(totalOutputTokenCount({thoughtsTokenCount: 40}), 40,
            "reasoning tokens must be reported even when no candidate tokens are returned");
    test:assertEquals(totalOutputTokenCount(()), (),
            "absent usage metadata must not be reported as zero");
    test:assertEquals(totalOutputTokenCount({promptTokenCount: 10}), (),
            "input-only usage must not report an output count");
}

// ── generate (structured output) ─────────────────────────────────────────────

@test:Config
function testGenerateBasicReturnType() returns ai:Error? {
    int rating = check provider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateArrayReturnType() returns ai:Error? {
    int[] ratings = check provider->generate(`Evaluate these blogs out of 10.
        Content: ${blog1.content}`);
    test:assertEquals(ratings, [9, 1]);
}

@test:Config
function testGenerateRecordReturnType() returns error? {
    Review result = check provider->generate(`Please rate this blog out of 10.
        Content: ${blog2.content}`);
    test:assertEquals(result, reviewRecord);
}

@test:Config
function testGenerateRecordArrayReturnType() returns error? {
    // `Review` carries the compiler-plugin-generated `@ai:JsonSchema` annotation, but
    // `Review[]` does not, so the annotation lookup in `generateJsonSchemaForTypedescAsJson`
    // misses and schema generation falls through to the native path. That path must still
    // resolve the annotation on the array's element type.
    Review[] reviews = check provider->generate(`List the reviews for this blog`);
    test:assertEquals(reviews, [
        {rating: 8, comment: "Solid warm-up advice."},
        {rating: 5, comment: "Thin on nutrition."}
    ]);
}

@test:Config
function testGenerateStringReturnType() returns error? {
    string joke = check provider->generate(`Give me a random joke`);
    test:assertEquals(joke, "Why did the chicken cross the road?");
}

@test:Config
function testGenerateNestedRecordReturnType() returns error? {
    Person person = check provider->generate(`Extract the person from: Ada, 36, London, UK`);
    test:assertEquals(person, personRecord);
}

@test:Config
function testGenerateNilableArrayReturnTypeNormalizesOneOf() returns error? {
    // A nilable array member is the one runtime path that emits `oneOf`
    // (to_json_schema.bal). Gemini does not document `oneOf`, so it must be rewritten
    // to `anyOf` before the schema is sent. The mock asserts the wire shape.
    (int?)[] ratings = check provider->generate(`Nilable array check: rate these blogs`);
    test:assertEquals(ratings, <(int?)[]>[9, (), 1]);
}

@test:Config
function testGenerateMapReturnTypeIsUnsupported() returns ai:Error? {
    // Top-level `map<T>` return types are not supported by the schema generator yet;
    // the connector surfaces this as an ai:Error rather than a panic.
    map<int>|ai:Error scores = provider->generate(`Score the items out of 10`);
    test:assertTrue(scores is ai:Error, "expected an error for an unsupported map return type");
    test:assertTrue((<ai:Error>scores).message().includes("Runtime schema generation is not yet supported"));
}

@test:Config
function testGenerateForwardsGenerationConfig() returns ai:Error? {
    // The mock asserts temperature/maxOutputTokens/responseMimeType are present.
    int result = check provider->generate(`Config check: rate this out of 10`);
    test:assertEquals(result, 5);
}

@test:Config
function testGenerateWithTextDocument() returns ai:Error? {
    ai:TextDocument blog = {content: string `Title: ${blog1.title} Content: ${blog1.content}`};
    int rating = check provider->generate(`How would you rate this blog content out of 10. ${blog}.`);
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateWithTextChunk() returns ai:Error? {
    ai:TextChunk chunk = {content: string `Title: ${blog1.title} Content: ${blog1.content}`};
    int rating = check provider->generate(`How would you rate this text chunk out of 10. ${chunk}.`);
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateWithInlineImage() returns ai:Error? {
    ai:ImageDocument img = {content: sampleBinaryData, metadata: {mimeType: "image/png"}};
    string description = check provider->generate(`Describe the following image. ${img}.`);
    test:assertEquals(description, "This is a sample image description.");
}

@test:Config
function testGenerateWithMultimodalArray() returns ai:Error? {
    ai:TextDocument text = {content: "Product photo to review"};
    ai:ImageDocument image = {content: sampleBinaryData, metadata: {mimeType: "image/png"}};
    ai:Document[] docs = [text, image];
    string description = check provider->generate(`Describe the following image. ${docs}`);
    test:assertEquals(description, "This is a sample image description.");
}

@test:Config
function testGenerateWithMultipleImagesAndText() returns ai:Error? {
    ai:ImageDocument png = {content: sampleBinaryData, metadata: {mimeType: "image/png"}};
    ai:ImageDocument jpeg = {content: sampleBinaryData, metadata: {mimeType: "image/jpeg"}};
    ai:TextDocument caption = {content: "Compare these product shots"};
    ai:Document[] docs = [caption, png, jpeg];
    string description = check provider->generate(`Describe the following image collection. ${docs}`);
    test:assertEquals(description, "This is a sample image description.");
}

@test:Config
function testGenerateWithUnsupportedDocInMultimodalArrayFails() returns ai:Error? {
    ai:TextDocument text = {content: "Some text"};
    ai:AudioDocument audio = {content: sampleBinaryData};
    ai:Document[] docs = [text, audio];
    string|ai:Error result = provider->generate(`Analyze the following documents. ${docs}`);
    test:assertTrue(result is ai:Error, "expected an error for an unsupported document in a multimodal array");
    test:assertTrue((<ai:Error>result).message().includes(UNSUPPORTED_DOC_ERROR));
}

@test:Config
function testGenerateWithImageUrl() returns ai:Error? {
    // No metadata.mimeType: the connector downloads the bytes and uses the
    // response Content-Type (image/png).
    ai:ImageDocument img = {content: IMAGE_URL};
    string description = check provider->generate(`Describe the image at the URL. ${img}.`);
    test:assertEquals(description, "This is a sample image description.");
}

@test:Config
function testGenerateRejectsLoopbackDocumentUrlWhenOptedOut() {
    // Same URL the default provider downloads happily; a provider constructed with
    // `allowPrivateDocumentHosts = false` must refuse it, so a URL arriving from an
    // untrusted source cannot be used to probe internal services.
    ai:ImageDocument img = {content: IMAGE_URL};
    string|ai:Error description = strictProvider->generate(`Describe the image at the URL. ${img}.`);
    test:assertTrue(description is ai:Error, "a loopback document URL must be rejected when opted out");
    test:assertTrue((<ai:Error>description).message().includes("not a public address"),
            "expected the non-public destination error, got: " + (<ai:Error>description).message());
}

@test:Config
function testGenerateRejectsNonHttpDocumentUrl() {
    ai:ImageDocument img = {content: "file:///etc/passwd"};
    string|ai:Error description = strictProvider->generate(`Describe the image at the URL. ${img}.`);
    test:assertTrue(description is ai:Error, "a non-HTTP document URL must be rejected");
    test:assertTrue((<ai:Error>description).message().includes("Only 'http' and 'https'"),
            "expected the scheme error, got: " + (<ai:Error>description).message());
}

@test:Config
function testGenerateFollowsDocumentRedirect() returns ai:Error? {
    // Redirects are now followed by hand rather than by the HTTP client, so that each hop
    // can be revalidated. This covers that loop still resolving a 302 to the real asset.
    // The per-hop *rejection* can only be unit-tested (see testNonPublicHostDetection):
    // the mock is itself on loopback, so an end-to-end redirect into a private address
    // would be blocked on the first hop and prove nothing about the second.
    ai:ImageDocument img = {content: REDIRECT_IMAGE_URL};
    string description = check provider->generate(`Describe the image at the URL. ${img}.`);
    test:assertEquals(description, "This is a sample image description.");
}

@test:Config
function testNonPublicHostDetection() {
    // Table-check the address classifier directly; the ranges are easy to get subtly wrong.
    string[] blocked = [
        "localhost", "app.localhost", "127.0.0.1", "127.1.2.3", "10.0.0.5", "172.16.0.1",
        "172.31.255.254", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0",
        "192.0.0.1", "::1", "::", "fc00::1", "fd12:3456::1", "fe80::1", "::ffff:127.0.0.1"
    ];
    foreach string host in blocked {
        test:assertTrue(isNonPublicHost(host), string `'${host}' must be treated as non-public`);
    }

    string[] allowed = [
        "example.com", "8.8.8.8", "1.1.1.1", "172.32.0.1", "172.15.0.1", "192.169.0.1",
        "169.253.0.1", "100.128.0.1", "2606:4700::1111", "storage.googleapis.com"
    ];
    foreach string host in allowed {
        test:assertFalse(isNonPublicHost(host), string `'${host}' must be treated as public`);
    }
}

@test:Config
function testGenerateWithPdfBytes() returns ai:Error? {
    ai:FileDocument pdf = {content: sampleBinaryData, metadata: {mimeType: "application/pdf"}};
    string summary = check provider->generate(`Summarize the PDF bytes. ${pdf}.`);
    test:assertEquals(summary, "This is a sample document summary.");
}

@test:Config
function testGenerateWithPdfUrl() returns ai:Error? {
    ai:FileDocument pdf = {content: PDF_URL};
    string summary = check provider->generate(`Summarize the PDF at the URL. ${pdf}.`);
    test:assertEquals(summary, "This is a sample document summary.");
}

@test:Config
function testGenerateWithFileId() returns ai:Error? {
    ai:FileDocument file = {content: {fileId: "files/abc-123"}};
    string summary = check provider->generate(`Summarize the referenced file. ${file}.`);
    test:assertEquals(summary, "This is a sample document summary.");
}

@test:Config
function testGenerateWithMissingImageMimeFails() returns ai:Error? {
    ai:ImageDocument img = {content: sampleBinaryData};
    string|ai:Error description = provider->generate(`Describe the following image. ${img}.`);
    test:assertTrue(description is ai:Error, "expected an error when the image MIME type is missing");
    test:assertTrue((<ai:Error>description).message().includes("concrete image MIME type"));
}

@test:Config
function testGenerateWithUnsupportedDocument() returns ai:Error? {
    ai:AudioDocument doc = {content: sampleBinaryData};
    string|error result = provider->generate(`What is in this document. ${doc}.`);
    test:assertTrue(result is error, "expected an error for an unsupported document");
    test:assertTrue((<error>result).message().includes(UNSUPPORTED_DOC_ERROR));
}

// ── embeddings ───────────────────────────────────────────────────────────────

@test:Config
function testEmbed() returns ai:Error? {
    ai:TextChunk chunk = {content: "Embed this text."};
    ai:Embedding embedding = check embeddingProvider->embed(chunk);
    test:assertEquals(embedding, <float[]>[0.1, 0.2, 0.3]);
}

@test:Config
function testBatchEmbed() returns ai:Error? {
    ai:TextChunk[] chunks = [{content: "first"}, {content: "second"}];
    ai:Embedding[] embeddings = check embeddingProvider->batchEmbed(chunks);
    test:assertEquals(embeddings.length(), 2);
    test:assertEquals(embeddings[0], <float[]>[0.1, 0.2]);
}

@test:Config
function testBatchEmbedEmptyInputReturnsEmpty() returns ai:Error? {
    // Gemini rejects an empty `requests` array with a 400, so this must not reach the API.
    ai:Embedding[] embeddings = check embeddingProvider->batchEmbed([]);
    test:assertEquals(embeddings.length(), 0);
}

@test:Config
function testBatchEmbedLengthMismatchIsDetected() returns ai:Error? {
    // The mock returns exactly two embeddings, so three chunks force a short response.
    // Silently returning it would misalign every chunk with the wrong vector.
    ai:TextChunk[] chunks = [{content: "first"}, {content: "second"}, {content: "third"}];
    ai:Embedding[]|ai:Error embeddings = embeddingProvider->batchEmbed(chunks);
    test:assertTrue(embeddings is ai:Error,
            "a response with fewer embeddings than chunks must be rejected, not silently misaligned");
    string message = (<ai:Error>embeddings).message();
    test:assertTrue(message.includes("Expected 3 embeddings"),
            "the error must state how many embeddings were expected");
    test:assertTrue(message.includes("received 2"),
            "the error must state how many embeddings were actually returned");
}

@test:Config
function testEmbedRejectsNonTextChunk() returns ai:Error? {
    ai:ImageDocument img = {content: sampleBinaryData};
    ai:Embedding|ai:Error embedding = embeddingProvider->embed(img);
    test:assertTrue(embedding is ai:Error, "expected an error for a non-text chunk");
}

@test:Config
function testBatchEmbedRejectsNonTextChunk() returns ai:Error? {
    ai:TextChunk text = {content: "valid text"};
    ai:ImageDocument img = {content: sampleBinaryData};
    ai:Embedding[]|ai:Error embeddings = embeddingProvider->batchEmbed([text, img]);
    test:assertTrue(embeddings is ai:Error, "expected an error when a non-text chunk is in the batch");
}

@test:Config
function testEmbedRuntimeErrorIsWrapped() returns ai:Error? {
    // The mock returns a 5xx for this input; the provider should wrap it as an ai:Error.
    ai:TextChunk chunk = {content: "trigger-runtime-error"};
    ai:Embedding|ai:Error embedding = embeddingProvider->embed(chunk);
    test:assertTrue(embedding is ai:Error, "expected an error when the embedding call fails");
    test:assertTrue((<ai:Error>embedding).message().includes("Unable to obtain embedding"));
}
