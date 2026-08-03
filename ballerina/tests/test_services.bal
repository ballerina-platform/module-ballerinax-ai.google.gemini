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
import ballerina/test;

// Mock Gemini API. The connector posts to `${serviceUrl}/models/{model}:{action}`,
// so a single resource captures `models/<model>:<action>` as one path segment and
// dispatches on the action suffix. For `:generateContent`, the request body is
// asserted (per scenario) before a response is returned, so the request-building
// layer unique to Gemini is covered.
service /llm on new http:Listener(8080) {
    resource function post models/[string operation](@http:Payload json payload,
            @http:Header {name: "x-goog-api-key"} string? apiKeyHeader = ())
            returns json|http:Response|error {
        // Authentication must not silently break: every request, on every endpoint,
        // has to carry the API key in the documented header.
        test:assertEquals(apiKeyHeader, API_KEY,
                string `'x-goog-api-key' must be sent on ${operation}`);
        if operation.endsWith(":embedContent") {
            // Simulate an upstream/runtime failure for a designated input.
            if embedInputText(payload) == "trigger-runtime-error" {
                return error("simulated upstream embedding failure");
            }
            return {embedding: {values: [0.1, 0.2, 0.3]}};
        }
        if operation.endsWith(":batchEmbedContents") {
            return {embeddings: [{values: [0.1, 0.2]}, {values: [0.3, 0.4]}]};
        }
        // :generateContent — assert the request shape, then pick a response based
        // on the first text part.
        string promptText = extractFirstText(payload);
        validateGenerateContentRequest(promptText, payload);
        if promptText.startsWith("What's the weather") {
            return buildToolCallResponse("getWeather", {city: "Colombo"});
        }
        if promptText.startsWith("Weather follow-up") {
            return buildTextResponse("It is 20 degrees in Paris.");
        }
        if promptText.startsWith("Tool schema passthrough") {
            return buildToolCallResponse("getWeather", {city: "Paris"});
        }
        // A truncated candidate: thinking consumed the whole token budget, so the
        // candidate carries a finishReason but no parts.
        if promptText.startsWith("Truncated by thinking") {
            return {candidates: [{content: {role: "model", parts: []}, finishReason: "MAX_TOKENS"}]};
        }
        // A safety-filtered candidate: no content at all, only a finishReason.
        if promptText.startsWith("Safety filtered") {
            return {candidates: [{finishReason: "SAFETY"}]};
        }
        // A blocked prompt: Gemini returns no candidates, only promptFeedback.
        if promptText.startsWith("Blocked prompt") {
            return {candidates: [], promptFeedback: {blockReason: "PROHIBITED_CONTENT"}};
        }
        // 401 and 429 exercise the same mapping path as 400 but must not be reported as
        // connection failures either — a bad key and a rate limit are distinct causes.
        if promptText.startsWith("Trigger auth error") {
            http:Response unauthorized = new;
            unauthorized.statusCode = 401;
            unauthorized.setJsonPayload({
                'error: {code: 401, message: "API key not valid.", status: "UNAUTHENTICATED"}
            });
            return unauthorized;
        }
        if promptText.startsWith("Trigger rate limit") {
            http:Response rateLimited = new;
            rateLimited.statusCode = 429;
            rateLimited.setJsonPayload({
                'error: {code: 429, message: "Quota exceeded.", status: "RESOURCE_EXHAUSTED"}
            });
            return rateLimited;
        }
        // A 4xx carrying Gemini's error envelope, so the error-mapping path is covered.
        if promptText.startsWith("Trigger API error") {
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({
                'error: {
                    code: 400,
                    message: "Invalid JSON payload received.",
                    status: "INVALID_ARGUMENT"
                }
            });
            return errorResponse;
        }
        return buildTextResponse(getMockResultText(promptText));
    }

    // Serves document bytes so the connector's URL-download path can be exercised.
    // `.pdf` names are served as application/pdf; everything else as image/png.
    resource function get assets/[string name]() returns http:Response {
        http:Response response = new;
        string mimeType = name.endsWith(".pdf") ? "application/pdf" : "image/png";
        response.setBinaryPayload(sampleBinaryData, mimeType);
        return response;
    }

    // Redirects to the asset above, so the connector's manual redirect loop is
    // exercised. The HTTP client no longer auto-follows redirects (each hop must be
    // revalidated), so a broken loop shows up here as a failed download.
    resource function get redirect/[string name]() returns http:Response {
        http:Response response = new;
        response.statusCode = 302;
        response.setHeader("Location", string `/llm/assets/${name}`);
        return response;
    }
}

// Asserts the shape of a `:generateContent` request for the scenarios that
// exercise the Gemini-specific request-building logic. No-ops for other prompts.
function validateGenerateContentRequest(string promptText, json payload) {
    map<json> obj = payload is map<json> ? payload : {};

    if promptText.startsWith("System check") {
        json systemInstruction = obj["systemInstruction"];
        test:assertTrue(systemInstruction is map<json>, "expected a systemInstruction in the request");
        test:assertEquals(firstPartText(systemInstruction), "You are a helpful assistant.");
    }

    if promptText.startsWith("Weather follow-up") {
        json contents = obj["contents"];
        test:assertTrue(contents is json[], "expected a contents array");
        json[] contentsArr = <json[]>contents;
        test:assertEquals(contentsArr.length(), 3, "expected user, model and function-response turns");

        map<json> modelTurn = <map<json>>contentsArr[1];
        test:assertEquals(modelTurn["role"], "model", "assistant turn must use the 'model' role");
        map<json> modelPart = <map<json>>(<json[]>modelTurn["parts"])[0];
        test:assertTrue(modelPart.hasKey("functionCall"), "expected a functionCall part in the model turn");
        map<json> functionCall = <map<json>>modelPart["functionCall"];
        test:assertEquals(functionCall["name"], "getWeather");

        map<json> fnTurn = <map<json>>contentsArr[2];
        test:assertEquals(fnTurn["role"], "user", "function-response turn must use the 'user' role");
        map<json> fnPart = <map<json>>(<json[]>fnTurn["parts"])[0];
        test:assertTrue(fnPart.hasKey("functionResponse"), "expected a functionResponse part");
        map<json> functionResponse = <map<json>>fnPart["functionResponse"];
        test:assertEquals(functionResponse["name"], "getWeather");
    }

    if promptText.startsWith("What's the weather using two tools") {
        json toolsJson = obj["tools"];
        test:assertTrue(toolsJson is json[] && toolsJson.length() > 0, "expected a tools array");
        map<json> firstTool = <map<json>>(<json[]>toolsJson)[0];
        json declarations = firstTool["functionDeclarations"];
        test:assertTrue(declarations is json[], "expected function declarations");
        test:assertEquals((<json[]>declarations).length(), 2, "expected two function declarations");
    }

    if promptText.startsWith("Tool schema passthrough") {
        // Tool schemas go through `parametersJsonSchema`, which accepts standard JSON
        // Schema. Keywords the old deny-list stripped must now survive intact —
        // dropping `$ref` in particular degraded nested schemas to an unconstrained
        // object, telling the model nothing about the expected arguments.
        map<json> params = toolParameters(obj);
        foreach string key in ["$schema", "title", "$ref", "default", "additionalProperties"] {
            test:assertTrue(params.hasKey(key),
                    string `'${key}' must pass through to parametersJsonSchema, not be stripped`);
        }
        map<json> props = params["properties"] is map<json> ? <map<json>>params["properties"] : {};
        map<json> city = props["city"] is map<json> ? <map<json>>props["city"] : {};
        test:assertEquals(city["default"], "Colombo", "nested 'default' must survive");
        test:assertEquals(city["type"], "string");
    }

    if promptText.startsWith("Union schema") {
        // `oneOf`/`allOf` are not documented as supported; `anyOf` is. They must be
        // rewritten rather than sent verbatim.
        map<json> params = toolParameters(obj);
        map<json> props = params["properties"] is map<json> ? <map<json>>params["properties"] : {};
        map<json> value = props["value"] is map<json> ? <map<json>>props["value"] : {};
        test:assertFalse(value.hasKey("oneOf"), "'oneOf' must be normalised away");
        test:assertTrue(value.hasKey("anyOf"), "'oneOf' must be rewritten to 'anyOf'");
        test:assertEquals(value["anyOf"], <json[]>[{"type": "string"}, {"type": "null"}],
                "the union members must be preserved unchanged");
    }

    if promptText.startsWith("Scalar tool result") {
        map<json> fnResponse = functionResponsePayload(obj);
        test:assertEquals(fnResponse["result"], 42,
                "a scalar tool result must stay a number, not become a string");
    }

    if promptText.startsWith("Array tool result") {
        // The functionResponse must carry the parsed array, not the raw string.
        map<json> fnResponse = functionResponsePayload(obj);
        test:assertEquals(fnResponse["result"], <json[]>[1, 2, 3],
                "a JSON array tool result must stay structured, not become a string");
    }

    if promptText.startsWith("Multi system") {
        map<json> sysInstruction = obj["systemInstruction"] is map<json>
            ? <map<json>>obj["systemInstruction"] : {};
        json[] parts = sysInstruction["parts"] is json[] ? <json[]>sysInstruction["parts"] : [];
        test:assertEquals(parts.length(), 2, "each system message becomes its own part");
        map<json> second = parts[1] is map<json> ? <map<json>>parts[1] : {};
        test:assertTrue((second["text"] is string ? <string>second["text"] : "").startsWith("\n"),
                "successive system instructions must be newline-separated, since Gemini " +
                "concatenates parts with no separator");
    }

    if promptText.startsWith("Stop test") {
        map<json> genConfig = generationConfig(obj);
        test:assertEquals(genConfig["stopSequences"], <json[]>["END"]);
    }

    // Structured output must be requested via `responseJsonSchema`; Gemini rejects a
    // request carrying both that and `responseSchema`.
    if promptText.startsWith("Rate this blog") || promptText.startsWith("Give me a random joke")
        || promptText.startsWith("Evaluate these blogs") || promptText.startsWith("Extract the person") {
        map<json> genConfig = generationConfig(obj);
        test:assertFalse(genConfig.hasKey("responseSchema"),
                "responseSchema must be omitted when responseJsonSchema is used");
        test:assertTrue(genConfig.hasKey("responseJsonSchema"),
                "structured output must be requested through responseJsonSchema");
    }

    if promptText.startsWith("Rate this blog") {
        assertSchemaContains(responseJsonSchemaOf(obj), expectedIntResponseSchema(), "int return");
    }
    if promptText.startsWith("Nilable array check") {
        // Regression guard: whatever the schema generator emits for a nilable member,
        // no `oneOf`/`allOf` may reach Gemini — neither is a documented keyword.
        string schema = responseJsonSchemaOf(obj).toJsonString();
        test:assertFalse(schema.includes("oneOf"),
                string `'oneOf' must not reach Gemini, got ${schema}`);
        test:assertFalse(schema.includes("allOf"),
                string `'allOf' must not reach Gemini, got ${schema}`);
        // KNOWN DEFECT (pre-existing, in ported schema-generation code): a nilable array
        // member is emitted as {"type": null} rather than a usable type or a null union,
        // so the model receives no type constraint for the item. Not introduced by this
        // PR — `to_json_schema.bal`'s own `oneOf` branch is unreachable because
        // `getStringRepresentation` panics on unsupported types. Tracked as a follow-up.
        test:assertTrue(schema.includes("\"items\""), "the array item schema must be present");
    }
    if promptText.startsWith("Give me a random joke") {
        assertSchemaContains(responseJsonSchemaOf(obj), expectedStringResponseSchema(), "string return");
    }
    if promptText.startsWith("Evaluate these blogs") {
        assertSchemaContains(responseJsonSchemaOf(obj), expectedIntArrayResponseSchema(), "int[] return");
    }
    if promptText.startsWith("Extract the person") {
        assertSchemaContains(responseJsonSchemaOf(obj), expectedNestedRecordResponseSchema(),
                "nested record return");
    }

    if promptText.startsWith("Config check") {
        map<json> genConfig = generationConfig(obj);
        // `temperature` is omitted unless the caller sets it, so the model's own default
        // applies. Google strongly recommends leaving it unset on Gemini 3 models.
        test:assertFalse(genConfig.hasKey("temperature"),
                "temperature must be omitted from generate() when unset");
        test:assertFalse(genConfig.hasKey("thinkingConfig"),
                "thinkingConfig must never be sent; the connector does not expose a thinking budget");
        test:assertEquals(genConfig["maxOutputTokens"], DEFAULT_MAX_TOKEN_COUNT,
                "maxTokens must be forwarded to generate()");
        test:assertEquals(genConfig["responseMimeType"], "application/json");
    }

    if promptText.startsWith("Describe the image at the URL") {
        map<json> inlineData = inlineDataPart(obj);
        test:assertEquals(inlineData["mimeType"], "image/png", "downloaded image URL must become an inlineData part");
        test:assertTrue(inlineData["data"] is string, "expected base64 data for the downloaded image");
    }

    if promptText.startsWith("Summarize the PDF") {
        map<json> inlineData = inlineDataPart(obj);
        test:assertEquals(inlineData["mimeType"], "application/pdf", "PDF must become an application/pdf inlineData part");
    }

    if promptText.startsWith("Summarize the referenced file") {
        map<json> part = partWithKey(obj, "fileData");
        map<json> fileData = part["fileData"] is map<json> ? <map<json>>part["fileData"] : {};
        test:assertEquals(fileData["fileUri"], "files/abc-123", "a FileId must become a fileData part");
    }
}

// Returns the `inlineData` object of the first inlineData part in `contents[0]`.
isolated function inlineDataPart(map<json> payload) returns map<json> {
    map<json> part = partWithKey(payload, "inlineData");
    return part["inlineData"] is map<json> ? <map<json>>part["inlineData"] : {};
}

// Returns the `response` object of the first `functionResponse` part found anywhere in
// `contents`, or `{}` when none. Unlike `partWithKey` this scans every content entry,
// since a tool result is never the first turn.
isolated function functionResponsePayload(map<json> payload) returns map<json> {
    json contents = payload["contents"];
    if contents !is json[] {
        return {};
    }
    foreach json content in contents {
        map<json> entry = content is map<json> ? <map<json>>content : {};
        json parts = entry["parts"];
        if parts !is json[] {
            continue;
        }
        foreach json part in parts {
            map<json> partObj = part is map<json> ? <map<json>>part : {};
            json fnResponse = partObj["functionResponse"];
            if fnResponse is map<json> {
                return fnResponse["response"] is map<json> ? <map<json>>fnResponse["response"] : {};
            }
        }
    }
    return {};
}

// Returns the first part of `contents[0]` that carries `key`, or `{}` when none.
isolated function partWithKey(map<json> payload, string key) returns map<json> {
    json contents = payload["contents"];
    if contents is json[] && contents.length() > 0 {
        map<json> first = contents[0] is map<json> ? <map<json>>contents[0] : {};
        json parts = first["parts"];
        if parts is json[] {
            foreach json part in parts {
                if part is map<json> && part.hasKey(key) {
                    return part;
                }
            }
        }
    }
    return {};
}

// Returns the first text part of `contents[0]`, or "" when absent.
isolated function extractFirstText(json payload) returns string {
    map<json> obj = payload is map<json> ? payload : {};
    json contents = obj["contents"];
    if contents is json[] && contents.length() > 0 {
        json first = contents[0];
        return firstPartText(first) is string ? <string>firstPartText(first) : "";
    }
    return "";
}

// Returns the `text` of the first part of a content object, or `()` when absent.
isolated function firstPartText(json content) returns json {
    map<json> obj = content is map<json> ? content : {};
    json parts = obj["parts"];
    if parts is json[] {
        foreach json part in parts {
            map<json> partObj = part is map<json> ? part : {};
            json text = partObj["text"];
            if text is string {
                return text;
            }
        }
    }
    return ();
}

// Returns the text of the first part of an `:embedContent` request's content.
isolated function embedInputText(json payload) returns string {
    map<json> obj = payload is map<json> ? payload : {};
    json content = obj["content"];
    return firstPartText(content) is string ? <string>firstPartText(content) : "";
}

// Returns the request's `generationConfig` object, or `{}` when absent.
isolated function generationConfig(map<json> payload) returns map<json> {
    json genConfig = payload["generationConfig"];
    return genConfig is map<json> ? genConfig : {};
}

// Returns the parameter schema of the first function declaration of the first
// tool, or `{}` when absent.
isolated function toolParameters(map<json> payload) returns map<json> {
    json tools = payload["tools"];
    if tools is json[] && tools.length() > 0 {
        map<json> firstTool = tools[0] is map<json> ? <map<json>>tools[0] : {};
        json declarations = firstTool["functionDeclarations"];
        if declarations is json[] && declarations.length() > 0 {
            map<json> firstDeclaration = declarations[0] is map<json> ? <map<json>>declarations[0] : {};
            json params = firstDeclaration["parametersJsonSchema"];
            return params is map<json> ? params : {};
        }
    }
    return {};
}

// Maps a prompt prefix to the text a Gemini model would return. For structured
// `generate` calls this is JSON (wrapped in `result` for non-object types); for
// plain chat it is free text.
isolated function getMockResultText(string message) returns string {
    if message.startsWith("Say hello") {
        return "Hello there!";
    }
    if message.startsWith("System check") {
        return "System instruction received.";
    }
    if message.startsWith("Stop test") {
        return "Stopping now.";
    }
    if message.startsWith("Config check") {
        return "{\"result\": 5}";
    }
    if message.startsWith("Evaluate") {
        return "{\"result\": [9, 1]}";
    }
    if message.startsWith("Nilable array check") {
        return "{\"result\": [9, null, 1]}";
    }
    if message.startsWith("Rate this blog") {
        return "{\"result\": 4}";
    }
    if message.startsWith("Please rate this blog") {
        return review;
    }
    if message.startsWith("List the reviews") {
        return reviews;
    }
    if message.startsWith("Extract the person") {
        return personJson;
    }
    if message.startsWith("Score the items") {
        return "{\"math\": 9, \"science\": 8}";
    }
    if message.startsWith("How would you rate this") {
        return "{\"result\": 4}";
    }
    if message.startsWith("Describe the following image") || message.startsWith("Describe the image at the URL") {
        return "{\"result\": \"This is a sample image description.\"}";
    }
    if message.startsWith("Summarize the") {
        return "{\"result\": \"This is a sample document summary.\"}";
    }
    if message.startsWith("Give me a random joke") {
        return "{\"result\": \"Why did the chicken cross the road?\"}";
    }
    return "{\"result\": null}";
}

isolated function buildTextResponse(string text) returns json => {
    candidates: [
        {
            content: {role: "model", parts: [{text}]},
            finishReason: "STOP",
            index: 0
        }
    ],
    // Thinking models report reasoning tokens separately from candidate tokens; both are
    // billed as output.
    usageMetadata: {
        promptTokenCount: 10,
        candidatesTokenCount: 5,
        thoughtsTokenCount: 40,
        totalTokenCount: 55
    },
    responseId: "resp-abc123",
    modelVersion: "gemini-2.5-flash-001"
};

isolated function buildToolCallResponse(string name, map<json> args) returns json => {
    candidates: [
        {
            // Gemini emits an `id` on function calls so parallel calls can be correlated.
            content: {role: "model", parts: [{functionCall: {id: "call-1", name, args}}]},
            finishReason: "STOP",
            index: 0
        }
    ],
    usageMetadata: {promptTokenCount: 12, candidatesTokenCount: 6, totalTokenCount: 18},
    modelVersion: "gemini-2.5-flash"
};
