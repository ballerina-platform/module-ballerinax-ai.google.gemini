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

final ai:ChatCompletionFunctions streamWeatherTool = {
    name: "getWeather",
    description: "Get the weather for a city",
    parameters: {"type": "object", "properties": {"city": {"type": "string"}}}
};

// Drains a chunk stream into a list, so assertions can address the whole exchange.
//
// Iterates with `next()` rather than a query expression on purpose: `check from ... in
// stream` propagates a failed chunk's error *cause* rather than the error itself, which
// would strip the `ai:Error` subtype the provider reports and leave these tests asserting
// against `lang.value` internals.
function collectChunks(stream<ai:ChatMessageChunk, ai:Error?> chunks)
        returns ai:ChatMessageChunk[]|ai:Error {
    ai:ChatMessageChunk[] collected = [];
    while true {
        record {|ai:ChatMessageChunk value;|}|ai:Error? next = chunks.next();
        if next is () {
            return collected;
        }
        if next is ai:Error {
            return next;
        }
        collected.push(next.value);
    }
}

// Concatenates the text fragments of a collected chunk list.
function joinContent(ai:ChatMessageChunk[] chunks) returns string {
    string text = "";
    foreach ai:ChatMessageChunk chunk in chunks {
        string? content = chunk.content;
        if content is string {
            text += content;
        }
    }
    return text;
}

@test:Config {}
function testChatStreamYieldsTextFragments() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream([{role: ai:USER, content: "Stream a greeting"}]);
    ai:ChatMessageChunk[] collected = check collectChunks(chunks);

    test:assertEquals(collected.length(), 3, "every streamed chunk should surface");
    test:assertEquals(joinContent(collected), "Hello, world!",
            "text fragments should stream through in order and unaltered");
    test:assertEquals(collected[0].id, STREAM_RESPONSE_ID);
    // `role` is required on every chunk of the normalized contract, unlike the OpenAI-style
    // "first delta only" convention the connector used to follow.
    foreach ai:ChatMessageChunk chunk in collected {
        test:assertEquals(chunk.role, ai:ASSISTANT, "role must be set on every chunk");
    }
}

@test:Config {}
function testChatStreamReportsFinishReasonOnlyOnFinalChunk() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream([{role: ai:USER, content: "Stream a greeting"}]);
    ai:ChatMessageChunk[] collected = check collectChunks(chunks);

    test:assertEquals(collected[0].finishReason, (),
            "a mid-stream chunk must not claim the generation has finished");
    test:assertEquals(collected[1].finishReason, ());
    test:assertEquals(collected[2].finishReason, ai:STOP);
}

@test:Config {}
function testChatStreamMapsToolCallTurnToToolCallsFinishReason() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check provider->chatAsStream(
            [{role: ai:USER, content: "Stream tool call please"}], [streamWeatherTool]);
    ai:ChatMessageChunk[] collected = check collectChunks(chunks);

    ai:ChatMessageChunk finalChunk = collected[collected.length() - 1];
    // Gemini says "STOP" even when the turn ends in a function call; passing that through
    // as `stop` would tell an agent loop the turn was a final answer.
    test:assertEquals(finalChunk.finishReason, ai:TOOL_CALLS,
            "a turn ending in a function call should report 'tool_calls', not 'stop'");

    ai:ToolCallChunk[]? toolCalls = finalChunk.toolCalls;
    if toolCalls is () {
        test:assertFail("the function call should surface as a tool-call chunk");
    }
    test:assertEquals(toolCalls.length(), 1);
    test:assertEquals(toolCalls[0].index, 0);
    test:assertEquals(toolCalls[0].name, "getWeather");
    // Gemini delivers arguments complete rather than fragmented, so the whole object
    // arrives in a single fragment.
    test:assertEquals(toolCalls[0].arguments, "{\"city\":\"Colombo\"}");
}

@test:Config {}
function testChatStreamPacksThoughtSignatureOntoToolCallId() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check provider->chatAsStream(
            [{role: ai:USER, content: "Stream tool call please"}], [streamWeatherTool]);
    ai:ChatMessageChunk[] collected = check collectChunks(chunks);

    ai:ToolCallChunk[] toolCalls =
        <ai:ToolCallChunk[]>collected[collected.length() - 1].toolCalls;
    // Gemini 3 rejects a replayed call that has lost its signature, and `ai:ToolCallChunk`
    // has nowhere else to carry one, so it rides on the id exactly as on the `chat` path.
    ToolCallId unpacked = unpackToolCallId(toolCalls[0].id);
    test:assertEquals(unpacked.id, "call-1");
    test:assertEquals(unpacked.signature, MOCK_THOUGHT_SIGNATURE,
            "the thought signature must survive the streamed round trip");
    test:assertFalse(unpacked.continuesBatch, "the first call of a turn opens the batch");
}

@test:Config {}
function testChatStreamNumbersParallelToolCallsAndMarksContinuations() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check provider->chatAsStream(
            [{role: ai:USER, content: "Stream parallel tools now"}], [streamWeatherTool]);
    ai:ChatMessageChunk[] collected = check collectChunks(chunks);

    ai:ToolCallChunk[] toolCalls = <ai:ToolCallChunk[]>collected[0].toolCalls;
    test:assertEquals(toolCalls.length(), 2);
    // Gemini gives streamed calls no index of its own; one is assigned per call so a
    // consumer can key accumulation by it.
    test:assertEquals(toolCalls[0].index, 0);
    test:assertEquals(toolCalls[1].index, 1);
    test:assertEquals(toolCalls[1].name, "getStockPrice");

    // Gemini signs only the first call of a parallel batch; the rest belong to the same
    // turn and must be marked as continuations so the turn can be replayed intact.
    test:assertFalse(unpackToolCallId(toolCalls[0].id).continuesBatch);
    test:assertTrue(unpackToolCallId(toolCalls[1].id).continuesBatch,
            "a later call in a batch should be marked a continuation of the opening turn");
}

@test:Config {}
function testChatStreamKeepsThoughtsOutOfContent() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream([{role: ai:USER, content: "Stream thoughts aloud"}]);
    ai:ChatMessageChunk[] collected = check collectChunks(chunks);

    // A thought part is chain-of-thought, not answer text; folding it into `content` would
    // leak the model's reasoning into the reply.
    test:assertEquals(collected[0].content, (),
            "a thought part must not surface as answer content");
    test:assertEquals(collected[0].reasoning, "weighing options");
    test:assertEquals(joinContent(collected), "The answer is 42.");
}

@test:Config {}
function testChatStreamMapsTruncationToLength() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream([{role: ai:USER, content: "Stream truncated output"}]);
    ai:ChatMessageChunk[] collected = check collectChunks(chunks);

    test:assertEquals(collected[0].finishReason, ai:LENGTH);
}

@test:Config {}
function testChatStreamMapsSafetyStopToContentFilter() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream([{role: ai:USER, content: "Stream filtered output"}]);
    ai:ChatMessageChunk[] collected = check collectChunks(chunks);

    // Gemini omits `parts` altogether on this chunk. It still has to arrive: dropping it as
    // unparseable would strand the consumer with a stream that ended on no finish reason.
    test:assertEquals(collected.length(), 1, "a parts-less terminal chunk must still surface");
    test:assertEquals(collected[0].finishReason, ai:CONTENT_FILTER);
    test:assertEquals(collected[0].content, ());
}

@test:Config {}
function testChatStreamSurfacesHttpErrorStatus() {
    stream<ai:ChatMessageChunk, ai:Error?>|ai:Error chunks =
        provider->chatAsStream([{role: ai:USER, content: "Stream auth error now"}]);

    // Targeting `http:Response` means the client hands back 4xx as an ordinary response, so
    // the status has to be caught here rather than surfacing as an empty event stream.
    if chunks !is ai:Error {
        test:assertFail("a 401 on the streaming endpoint should be reported as an error");
    }
    test:assertTrue(chunks.message().includes("401"), chunks.message());
    test:assertTrue(chunks.message().includes("UNAUTHENTICATED"), chunks.message());
}

@test:Config {}
function testGenerateAsStreamYieldsText() returns error? {
    stream<string, ai:Error?> textStream = check provider->generateAsStream(`Stream a greeting`);
    string answer = "";
    check from string fragment in textStream
        do {
            answer += fragment;
        };
    test:assertEquals(answer, "Hello, world!");
}

@test:Config {}
function testGenerateAsStreamYieldsTextOnlySkippingToolCallAndFinishOnlyChunks() returns error? {
    // The mock response carries a content chunk, then a chunk that is
    // tool-call-and-finish-reason only. `generateAsStream` must surface the former and
    // drop the latter rather than emitting an empty string for it.
    stream<string, ai:Error?> textStream =
        check provider->generateAsStream(`Generate stream tool call`);
    string answer = "";
    check from string fragment in textStream
        do {
            answer += fragment;
        };
    test:assertEquals(answer, "Looking that up. ",
            "generateAsStream must yield only non-empty content fragments");
}

@test:Config {}
function testChatStreamSurfacesMidStreamErrorEnvelope() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream([{role: ai:USER, content: "Stream mid error now"}]);

    // Gemini can fail after a 2xx status line. Every field of the response type is
    // optional, so the `{"error": ...}` frame converts cleanly into an empty chunk — if it
    // is not recognized, the caller keeps the half-written answer and is told nothing.
    ai:ChatMessageChunk[]|ai:Error collected = collectChunks(chunks);
    if collected !is ai:Error {
        test:assertFail("a mid-stream error frame should terminate the stream with an error");
    }
    test:assertTrue(collected.message().includes("UNAVAILABLE"), collected.message());
    test:assertTrue(collected.message().includes("The model is overloaded."), collected.message());
}

@test:Config {}
function testChatStreamSurfacesBlockedPrompt() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream([{role: ai:USER, content: "Stream blocked prompt now"}]);

    // `chat` raises `LlmInvalidResponseError` for a blocked prompt; the streamed path has to
    // agree, or a rejection is indistinguishable from the model having nothing to say.
    ai:ChatMessageChunk[]|ai:Error collected = collectChunks(chunks);
    if collected !is ai:Error {
        test:assertFail("a blocked prompt should terminate the stream with an error");
    }
    test:assertTrue(collected is ai:LlmInvalidResponseError, collected.message());
    test:assertTrue(collected.message().includes("SAFETY"), collected.message());
}

@test:Config {}
function testChatStreamSurfacesMalformedChunk() returns error? {
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream([{role: ai:USER, content: "Stream malformed chunk now"}]);

    // Skipping an unparseable frame would silently drop whatever it carried — including a
    // finish reason or the token usage.
    ai:ChatMessageChunk[]|ai:Error collected = collectChunks(chunks);
    if collected !is ai:Error {
        test:assertFail("a malformed frame should terminate the stream with an error");
    }
    test:assertTrue(collected is ai:LlmInvalidResponseError, collected.message());
}
