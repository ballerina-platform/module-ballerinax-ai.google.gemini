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
import ballerina/ai.observe;
import ballerina/http;
import ballerina/lang.array;

type ResponseSchema record {|
    map<json> schema;
    boolean isOriginallyJsonObject = true;
|};

# Maximum size of a document fetched from a caller-supplied URL, in bytes (20 MiB).
#
# Matches Gemini's own 20 MB inline-request ceiling: anything larger could not be sent
# as `inlineData` anyway. Without a cap, a URL taken from prompt data could stream an
# unbounded body into memory.
const int MAX_DOCUMENT_DOWNLOAD_SIZE = 20 * 1024 * 1024;
const int MAX_DOCUMENT_REDIRECTS = 5;

const JSON_CONVERSION_ERROR = "FromJsonStringError";
const CONVERSION_ERROR = "ConversionError";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the " +
    "LLM as the expected type. Retrying and/or validating the prompt could fix the response.";
const RESULT = "result";
const NO_RELEVANT_RESPONSE_FROM_THE_LLM = "No relevant response from the LLM";
const JSON_MIME_TYPE = "application/json";

isolated function generateJsonObjectSchema(map<json> schema) returns ResponseSchema {
    string[] supportedMetaDataFields = ["$schema", "$id", "$anchor", "$comment", "title", "description"];

    if schema["type"] == "object" {
        return {schema};
    }

    map<json> updatedSchema = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) is int
        select [key, value];

    updatedSchema["type"] = "object";
    map<json> content = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) !is int
        select [key, value];

    updatedSchema["properties"] = {[RESULT]: content};
    // Mark `result` as required so Gemini must populate it rather than being free
    // to return an empty object for a non-object return type.
    updatedSchema["required"] = [RESULT];

    return {schema: updatedSchema, isOriginallyJsonObject: false};
}

isolated function parseResponseAsType(string resp,
        typedesc<anydata> expectedResponseTypedesc, boolean isOriginallyJsonObject) returns anydata|error {
    if !isOriginallyJsonObject {
        map<json> respContent = check resp.fromJsonStringWithType();
        anydata|error result = trap respContent[RESULT].fromJsonWithType(expectedResponseTypedesc);
        if result is error {
            return handleParseResponseError(result);
        }
        return result;
    }

    anydata|error result = resp.fromJsonStringWithType(expectedResponseTypedesc);
    if result is error {
        return handleParseResponseError(result);
    }
    return result;
}

isolated function getExpectedResponseSchema(typedesc<anydata> expectedResponseTypedesc) returns ResponseSchema|ai:Error {
    // The compiler plugin restricts `generate`'s expected type to a `json`-convertible
    // one today; map the (unexpected) failure to an `ai:Error` rather than panicking.
    typedesc<json>|error td = expectedResponseTypedesc.ensureType();
    if td is error {
        return error ai:Error("Unsupported response type for structured generation; " +
                "expected a type convertible to 'json'.", td);
    }
    return generateJsonObjectSchema(check generateJsonSchemaForTypedescAsJson(td));
}

# Builds the Gemini content parts for a prompt: accumulated text is emitted as
# `text` parts and image documents as `inlineData` parts.
#
# + prompt - The prompt whose interpolated strings and insertions are converted
# + return - The ordered content parts, or an `ai:Error` for unsupported documents
isolated function generateChatCreationContent(ai:Prompt prompt) returns Part[]|ai:Error {
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    Part[] parts = [];
    string accumulatedTextContent = "";

    if strings.length() > 0 {
        accumulatedTextContent += strings[0];
    }

    foreach int i in 0 ..< insertions.length() {
        anydata insertion = insertions[i];
        string str = strings[i + 1];

        if insertion is ai:Document|ai:Chunk {
            addTextPart(accumulatedTextContent, parts);
            accumulatedTextContent = "";
            check addDocumentPart(insertion, parts);
        } else if insertion is (ai:Document|ai:Chunk)[] {
            addTextPart(accumulatedTextContent, parts);
            accumulatedTextContent = "";
            foreach ai:Document|ai:Chunk doc in insertion {
                check addDocumentPart(doc, parts);
            }
        } else {
            accumulatedTextContent += insertion.toString();
        }
        accumulatedTextContent += str;
    }

    addTextPart(accumulatedTextContent, parts);
    return parts;
}

isolated function addDocumentPart(ai:Document|ai:Chunk doc, Part[] parts) returns ai:Error? {
    if doc is ai:TextDocument|ai:TextChunk {
        addTextPart(doc.content, parts);
        return;
    } else if doc is ai:ImageDocument {
        parts.push(check buildImagePart(doc));
        return;
    } else if doc is ai:FileDocument {
        parts.push(check buildFilePart(doc));
        return;
    }
    return error ai:Error("Only text, image and file documents are supported.");
}

# Builds a Gemini part from an `ai:FileDocument` (e.g. a PDF). Inline bytes and
# downloaded URL content are sent as `inlineData`; an `ai:FileId` (a Gemini File
# API URI) is sent as `fileData`. A concrete MIME type is required for inline/
# downloaded bytes — from `metadata.mimeType`, falling back to the URL response's
# `Content-Type` for URLs.
#
# + doc - The file document
# + return - The corresponding part, or an `ai:Error` on failure
isolated function buildFilePart(ai:FileDocument doc) returns Part|ai:Error {
    byte[]|ai:Url|ai:FileId content = doc.content;
    if content is ai:FileId {
        FileData fileData = {fileUri: content.fileId};
        string? mimeType = doc.metadata?.mimeType;
        if mimeType is string {
            fileData.mimeType = mimeType;
        }
        return {fileData};
    }
    if content is ai:Url {
        [byte[], string?] downloaded = check downloadDocument(content);
        string? mimeType = doc.metadata?.mimeType ?: downloaded[1];
        if mimeType is () {
            return error ai:Error("A concrete file MIME type is required for Gemini; none was provided in " +
                    "'metadata.mimeType' and the URL response had no usable 'Content-Type'.");
        }
        return {inlineData: {mimeType, data: check getBase64EncodedString(downloaded[0])}};
    }
    string? mimeType = doc.metadata?.mimeType;
    if mimeType is () {
        return error ai:Error("A concrete file MIME type (e.g. 'application/pdf') is required in " +
                "'metadata.mimeType' for Gemini inline files.");
    }
    return {inlineData: {mimeType, data: check getBase64EncodedString(content)}};
}

isolated function addTextPart(string content, Part[] parts) {
    if content.length() > 0 {
        parts.push({text: content});
    }
}

# Builds a Gemini `inlineData` image part. Inline bytes are sent as-is; a URL is
# downloaded by the connector (Gemini does not fetch arbitrary web URLs) and sent
# inline. A concrete IANA image MIME type is required — from `metadata.mimeType`,
# falling back to the URL response's `Content-Type` — since Gemini rejects a
# wildcard like `image/*`.
#
# + doc - The image document
# + return - The image part, or an `ai:Error` when the MIME type cannot be
#            determined or the download fails
isolated function buildImagePart(ai:ImageDocument doc) returns Part|ai:Error {
    ai:Url|byte[] content = doc.content;
    if content is ai:Url {
        [byte[], string?] downloaded = check downloadDocument(content);
        string? mimeType = doc.metadata?.mimeType ?: downloaded[1];
        if mimeType is () {
            return error ai:Error("A concrete image MIME type is required for Gemini; none was provided in " +
                    "'metadata.mimeType' and the URL response had no usable 'Content-Type'.");
        }
        return {inlineData: {mimeType, data: check getBase64EncodedString(downloaded[0])}};
    }
    string? mimeType = doc.metadata?.mimeType;
    if mimeType is () {
        return error ai:Error("A concrete image MIME type (e.g. 'image/png') is required in " +
                "'metadata.mimeType' for Gemini inline images.");
    }
    return {inlineData: {mimeType, data: check getBase64EncodedString(content)}};
}

# Downloads the bytes at `url` and returns them together with the response MIME
# type. Gemini cannot fetch arbitrary web URLs itself, so image/file URLs are
# fetched by the connector and sent inline.
#
# Redirects are followed manually rather than by the HTTP client, so that every hop
# is checked against `validateDownloadDestination`. Letting the client follow them
# automatically would allow a public origin to bounce the request to an internal
# address after the initial check had already passed.
#
# + url - The URL to fetch
# + return - The downloaded bytes and the response MIME type (`Content-Type`
#            without parameters, `()` when absent), or an `ai:Error` on failure
isolated function downloadDocument(ai:Url url) returns [byte[], string?]|ai:Error {
    string currentUrl = url;
    foreach int hop in 0 ... MAX_DOCUMENT_REDIRECTS {
        [string, string] originPath = check splitUrl(currentUrl);
        check validateDownloadDestination(originPath[0]);
        http:Client|error downloadClient = new (originPath[0], {followRedirects: {enabled: false}});
        if downloadClient is error {
            return error ai:Error(string `Failed to create a client to download the document from '${url}'.`,
                    downloadClient);
        }
        http:Response|error response = downloadClient->get(originPath[1]);
        if response is error {
            return error ai:Error(string `Failed to download the document from '${url}'.`, response);
        }

        if isRedirectStatus(response.statusCode) {
            if hop == MAX_DOCUMENT_REDIRECTS {
                return error ai:Error(string `Too many redirects (more than ${MAX_DOCUMENT_REDIRECTS}) while ` +
                        string `downloading the document from '${url}'.`);
            }
            string|error location = response.getHeader("Location");
            if location is error {
                return error ai:Error(string `The document at '${url}' returned a ${response.statusCode} ` +
                        "redirect with no 'Location' header.");
            }
            currentUrl = resolveRedirectTarget(originPath[0], location);
            continue;
        }

        if response.statusCode < 200 || response.statusCode >= 300 {
            return error ai:Error(string `Failed to download the document from '${url}': status ${
                response.statusCode}.`);
        }
        // The URL comes from caller-supplied prompt data, so this is an outbound fetch to an
        // address the connector does not control. Reject an oversized body before reading it
        // where the server declares its length, and again afterwards as a backstop for
        // chunked responses that declare none.
        string|error declaredLength = response.getHeader("Content-Length");
        if declaredLength is string {
            int|error contentLength = int:fromString(declaredLength);
            if contentLength is int && contentLength > MAX_DOCUMENT_DOWNLOAD_SIZE {
                return error ai:Error(string `The document at '${url}' is ${contentLength} bytes, which exceeds the ${
                    MAX_DOCUMENT_DOWNLOAD_SIZE} byte limit.`);
            }
        }
        byte[]|error payload = response.getBinaryPayload();
        if payload is error {
            return error ai:Error(string `Failed to read the downloaded document from '${url}'.`, payload);
        }
        if payload.length() > MAX_DOCUMENT_DOWNLOAD_SIZE {
            return error ai:Error(string `The document at '${url}' is ${payload.length()} bytes, which exceeds the ${
                MAX_DOCUMENT_DOWNLOAD_SIZE} byte limit.`);
        }
        return [payload, normalizeMimeType(response.getContentType())];
    }
    return error ai:Error(string `Too many redirects while downloading the document from '${url}'.`);
}

isolated function isRedirectStatus(int statusCode) returns boolean =>
    statusCode == 301 || statusCode == 302 || statusCode == 303 || statusCode == 307 || statusCode == 308;

# Resolves a `Location` header against the origin it was served from. An absolute URL is
# taken as-is; a root-relative or relative reference is resolved against the origin.
#
# + origin - The origin (`scheme://host[:port]`) that issued the redirect
# + location - The raw `Location` header value
# + return - The absolute URL of the redirect target
isolated function resolveRedirectTarget(string origin, string location) returns string {
    string lowered = location.toLowerAscii();
    if lowered.startsWith("http://") || lowered.startsWith("https://") {
        return location;
    }
    return location.startsWith("/") ? origin + location : origin + "/" + location;
}

# Rejects a download destination that the connector must not reach.
#
# Only `http` and `https` are permitted.
#
# + origin - The origin (`scheme://host[:port]`) to check
# + return - `()` when the destination is permitted, otherwise an `ai:Error`
isolated function validateDownloadDestination(string origin) returns ai:Error? {
    string lowered = origin.toLowerAscii();
    if !lowered.startsWith("http://") && !lowered.startsWith("https://") {
        return error ai:Error(string `Only 'http' and 'https' document URLs are supported, got '${origin}'.`);
    }
    return;
}

# Splits a URL into its origin (`scheme://host[:port]`) and the resource path
# (path + query), for constructing an `http:Client`.
#
# + url - The URL to split
# + return - `[origin, path]`, or an `ai:Error` when the URL has no scheme
isolated function splitUrl(ai:Url url) returns [string, string]|ai:Error {
    string urlStr = url;
    int? schemeIdx = urlStr.indexOf("://");
    if schemeIdx is () {
        return error ai:Error(string `Invalid URL (missing scheme): '${url}'.`);
    }
    int hostStart = schemeIdx + 3;
    string afterScheme = urlStr.substring(hostStart);
    // The authority ends at the first '/', '?' or '#'. Splitting on '/' alone is wrong
    // for a URL with no path — "https://host?q=1" would put the query string into the
    // client's target URL and leave the request path as "/".
    int authorityEnd = afterScheme.length();
    foreach string delimiter in ["/", "?", "#"] {
        int? idx = afterScheme.indexOf(delimiter);
        if idx is int && idx < authorityEnd {
            authorityEnd = idx;
        }
    }
    string origin = urlStr.substring(0, hostStart + authorityEnd);
    string remainder = afterScheme.substring(authorityEnd);
    if remainder.length() == 0 {
        return [origin, "/"];
    }
    // A query or fragment with no path still needs a leading '/' in the request target.
    return [origin, remainder.startsWith("/") ? remainder : "/" + remainder];
}

# Strips any parameters from a `Content-Type` value (e.g. "; charset=..."),
# returning the bare MIME type, or `()` when empty.
#
# + contentType - The raw `Content-Type` header value
# + return - The bare MIME type, or `()` when there is none
isolated function normalizeMimeType(string contentType) returns string? {
    if contentType.length() == 0 {
        return ();
    }
    int? semicolon = contentType.indexOf(";");
    string mime = (semicolon is int ? contentType.substring(0, semicolon) : contentType).trim();
    return mime.length() > 0 ? mime : ();
}

isolated function getBase64EncodedString(byte[] content) returns string|ai:Error {
    string|error binaryContent = array:toBase64(content);
    if binaryContent is error {
        return error("Failed to convert byte array to string: " + binaryContent.message() + ", " +
                        binaryContent.detail().toBalString());
    }
    return binaryContent;
}

isolated function handleParseResponseError(error chatResponseError) returns error {
    string msg = chatResponseError.message();
    if msg.includes(JSON_CONVERSION_ERROR) || msg.includes(CONVERSION_ERROR) {
        return error(string `${ERROR_MESSAGE}`, chatResponseError);
    }
    return chatResponseError;
}

// ── thought signatures ──────────────────────────────────────────────────────

# Markers packed onto a tool-call id, carrying what `ai:FunctionCall` cannot.
#
# Gemini 3 returns a `thoughtSignature` covering a model turn and rejects a later request
# that replays that turn's calls without it. Two things therefore have to survive the round
# trip out through `ai:ChatAssistantMessage` and back into `chat`: the signature itself,
# and — for parallel calls, where Gemini signs the first part of the turn — which calls
# belong to that same turn. The two markers are kept independent rather than exclusive: a
# signature that does arrive on a later part of a batch is carried rather than dropped.
#
# Neither fits in `ai:FunctionCall`: it is a closed record (`{name, arguments, id?}`), and
# the agent runtime rebuilds it from persisted JSON, which would drop any extra field
# anyway. The only value that survives both that path and `ai:Memory` is the call id, so
# both travel appended to it and are split off before anything reaches the wire or a span.
#
# A connector-side cache was the alternative, and was rejected: tool-call turns are written
# to `ai:Memory` and replayed on later runs, so a cache would lose the signature across a
# restart, across service replicas, and whenever an identical call repeats — each of which
# is the same 400 in a less obvious place.
#
# The markers cannot occur in a call id (short alphanumeric tokens) or a signature (base64),
# so both can be appended to an id and split off again unambiguously. The signature marker
# is appended last, since a signature is the only part that may itself run to the end.
const THOUGHT_SIGNATURE_MARKER = "|thought-signature:";
const BATCH_CONTINUATION_MARKER = "|thought-continuation";

# A tool-call id as it travels through `ai:FunctionCall`.
type ToolCallId record {|
    # Gemini's own `functionCall.id`, or `()` when it sent none
    string? id;
    # The `thoughtSignature` Gemini returned on this call's part, or `()` when it sent none
    string? signature;
    # Whether this call continues the parallel batch opened by an earlier call, and so
    # belongs in the same `contents` entry rather than one of its own
    boolean continuesBatch;
|};

# Packs what Gemini needs back onto the id handed to the caller as `ai:FunctionCall.id`.
#
# + id - The `functionCall.id` Gemini returned, or `()` when it returned none
# + signature - The `thoughtSignature` on this call's part, if any
# + continuesBatch - Whether an earlier call in the same candidate opened this turn
# + return - The composite id, or `()` when there is nothing to carry and no id
isolated function packToolCallId(string? id, string? signature, boolean continuesBatch) returns string? {
    boolean signed = signature is string && signature.length() > 0;
    if !continuesBatch && !signed {
        return id;
    }
    // Gemini signs the first call of a batch, so a signed continuation is not the shape it
    // normally sends — but if one arrives, packing must not be what loses the signature.
    string packed = id ?: "";
    if continuesBatch {
        packed += BATCH_CONTINUATION_MARKER;
    }
    if signed {
        packed += string `${THOUGHT_SIGNATURE_MARKER}${<string>signature}`;
    }
    return packed;
}

# Splits a packed id back into Gemini's own id, the turn's signature, and whether the call
# continues a parallel batch.
#
# Tolerates an unmarked id — one a caller assembled by hand, or persisted before this
# connector packed anything — by returning it unchanged as a plain call id.
#
# + packed - The id from an `ai:FunctionCall`
# + return - The decomposed id
isolated function unpackToolCallId(string? packed) returns ToolCallId {
    if packed is () {
        return {id: (), signature: (), continuesBatch: false};
    }
    // Markers are stripped from the right, so a call carrying both is decomposed in full.
    string remainder = packed;
    string? signature = ();
    int? signatureIdx = remainder.indexOf(THOUGHT_SIGNATURE_MARKER);
    if signatureIdx is int {
        string packedSignature = remainder.substring(signatureIdx + THOUGHT_SIGNATURE_MARKER.length());
        signature = packedSignature.length() > 0 ? packedSignature : ();
        remainder = remainder.substring(0, signatureIdx);
    }
    boolean continuesBatch = false;
    int? continuationIdx = remainder.indexOf(BATCH_CONTINUATION_MARKER);
    if continuationIdx is int {
        continuesBatch = true;
        remainder = remainder.substring(0, continuationIdx);
    }
    // An empty remainder means Gemini sent no id of its own and the id exists only to
    // carry a marker; it must not be echoed back as `functionCall.id`.
    return {id: remainder.length() > 0 ? remainder : (), signature, continuesBatch};
}

# Reports whether an assistant message is nothing but the continuation of a parallel
# tool-call batch, and so must be folded back into the turn that opened it.
#
# + message - The assistant message to classify
# + return - `true` when every tool call in it continues an earlier batch
isolated function continuesToolCallBatch(ai:ChatAssistantMessage message) returns boolean {
    ai:FunctionCall[]? toolCalls = message.toolCalls;
    if toolCalls is () || toolCalls.length() == 0 {
        return false;
    }
    foreach ai:FunctionCall toolCall in toolCalls {
        if !unpackToolCallId(toolCall.id).continuesBatch {
            return false;
        }
    }
    return true;
}

# Returns the assistant message with any packed signature stripped from its tool-call ids.
#
# Signatures are multi-kilobyte opaque blobs; recorded verbatim they would dominate every
# span carrying a tool call and bury the arguments that make a trace readable.
#
# + message - The assistant message about to be recorded
# + return - An equivalent message carrying only Gemini's own call ids
isolated function stripThoughtSignatures(ai:ChatAssistantMessage message) returns ai:ChatAssistantMessage {
    ai:FunctionCall[]? toolCalls = message.toolCalls;
    if toolCalls is () {
        return message;
    }
    ai:FunctionCall[] stripped = [];
    foreach ai:FunctionCall toolCall in toolCalls {
        ai:FunctionCall call = {name: toolCall.name, arguments: toolCall.arguments};
        string? id = unpackToolCallId(toolCall.id).id;
        if id is string {
            call.id = id;
        }
        stripped.push(call);
    }
    ai:ChatAssistantMessage result = {role: message.role, content: message.content, toolCalls: stripped};
    string? name = message?.name;
    if name is string {
        result.name = name;
    }
    return result;
}

# Total tokens billed as output for a response.
#
# Gemini reports reasoning tokens in `thoughtsTokenCount`, separately from
# `candidatesTokenCount`, even though both are billed as output. Reporting only
# `candidatesTokenCount` therefore under-reports cost — severely on thinking models,
# where reasoning can account for most of the generation.
#
# + usage - The response's token accounting, if reported
# + return - Candidate plus reasoning tokens, or `()` when neither is reported
isolated function totalOutputTokenCount(UsageMetadata? usage) returns int? {
    if usage is () {
        return ();
    }
    int candidateTokens = usage.candidatesTokenCount ?: 0;
    int thoughtTokens = usage.thoughtsTokenCount ?: 0;
    int total = candidateTokens + thoughtTokens;
    return total > 0 ? total : ();
}

# Records token usage and response identity from a `generateContent` response.
#
# Output tokens are reported as `candidatesTokenCount + thoughtsTokenCount`. Gemini
# reports reasoning tokens separately even though they are billed as output, so counting
# only `candidatesTokenCount` under-reports cost — by a wide margin on thinking models,
# where reasoning can dominate the response.
#
# + span - The chat or generate-content span to annotate
# + response - The response to read usage and identity from
isolated function recordResponseTelemetry(observe:LlmSpan span, GenerateContentResponse response) {
    UsageMetadata? usage = response.usageMetadata;
    if usage is UsageMetadata {
        int? inputTokens = usage.promptTokenCount;
        if inputTokens is int {
            span.addInputTokenCount(inputTokens);
        }
        int? outputTokens = totalOutputTokenCount(usage);
        if outputTokens is int {
            span.addOutputTokenCount(outputTokens);
        }
    }
    string? responseId = response.responseId;
    if responseId is string {
        span.addResponseId(responseId);
    }
    // The concrete version behind a floating alias such as "gemini-3.6-flash"; without it
    // a trace cannot say which model actually served the request.
    string? modelVersion = response.modelVersion;
    if modelVersion is string {
        span.addResponseModel(modelVersion);
    }
}

# Maps an HTTP failure from a Gemini call onto the `ai:LlmError` taxonomy.
#
# Gemini reports failures as `{"error": {"code": .., "message": "..", "status": ".."}}`.
# `http:ClientRequestError` (4xx) and `http:RemoteServerError` (5xx) carry that body in
# their detail, so the status code and the API's own message are surfaced rather than
# discarded. `ai:LlmConnectionError` is reserved for genuine transport failures — a 400
# `INVALID_ARGUMENT`, a 401 bad key and a 429 `RESOURCE_EXHAUSTED` are not connection
# problems, and reporting them as such sends callers down the wrong diagnostic path.
#
# + err - The error returned by the HTTP client
# + return - A typed `ai:Error` describing the failure
isolated function mapHttpError(error err) returns ai:Error {
    int statusCode;
    anydata body;
    if err is http:ClientRequestError {
        statusCode = err.detail().statusCode;
        body = err.detail().body;
    } else if err is http:RemoteServerError {
        statusCode = err.detail().statusCode;
        body = err.detail().body;
    } else {
        return error ai:LlmConnectionError("Error while connecting to the model", err);
    }
    string detail = describeGeminiError(body);
    return error ai:LlmError(detail.length() > 0
            ? string `Gemini API request failed with status ${statusCode}: ${detail}`
            : string `Gemini API request failed with status ${statusCode}`, err);
}

# Maps a non-2xx response to a streaming request onto the `ai:LlmError` taxonomy.
#
# The streaming call targets `http:Response` rather than a bound record, so the HTTP client
# hands back 4xx/5xx as an ordinary response instead of raising an error — `mapHttpError`
# never sees them. The status is therefore inspected directly and Gemini's
# `{"error": {...}}` envelope read from the body, so a rejected key or invalid request
# reports as itself instead of as an empty or unparseable event stream.
#
# + response - The non-2xx response
# + return - A typed `ai:Error` describing the failure
isolated function mapStreamErrorResponse(http:Response response) returns ai:Error {
    json|error payload = response.getJsonPayload();
    string detail = payload is json ? describeGeminiError(payload) : "";
    // A gateway or proxy rejecting the request ahead of Gemini answers in HTML or plain
    // text, not the JSON error envelope. Falling back to the raw body keeps the reason
    // visible instead of reporting a bare status code.
    if detail.length() == 0 {
        string|error textPayload = response.getTextPayload();
        if textPayload is string {
            string trimmed = textPayload.trim();
            detail = trimmed.length() > 200 ? trimmed.substring(0, 200) : trimmed;
        }
    }
    return error ai:LlmError(detail.length() > 0
            ? string `Gemini API streaming request failed with status ${response.statusCode}: ${detail}`
            : string `Gemini API streaming request failed with status ${response.statusCode}`);
}

# Extracts `error.status` and `error.message` from Gemini's error envelope.
#
# + body - The response body carried by the HTTP error
# + return - A "STATUS - message" description, or "" when the envelope is absent
isolated function describeGeminiError(anydata body) returns string {
    json payload = body.toJson();
    if payload !is map<json> {
        return "";
    }
    json errorObj = payload["error"];
    if errorObj !is map<json> {
        return "";
    }
    json status = errorObj["status"];
    json message = errorObj["message"];
    string statusText = status is string ? status : "";
    string messageText = message is string ? message : "";
    if statusText.length() > 0 && messageText.length() > 0 {
        return string `${statusText} - ${messageText}`;
    }
    return messageText.length() > 0 ? messageText : statusText;
}

# Builds an error message for a response that carried no candidates. When the
# prompt was blocked, Gemini populates `promptFeedback.blockReason`; surfacing it
# makes a blocked prompt distinguishable from a genuinely empty response.
#
# + response - The `generateContent` response with empty/absent candidates
# + return - A message naming the block reason when present, otherwise a generic one
isolated function buildEmptyCandidatesMessage(GenerateContentResponse response) returns string {
    PromptFeedback? feedback = response.promptFeedback;
    if feedback is PromptFeedback {
        string? blockReason = feedback.blockReason;
        if blockReason is string {
            return string `Prompt blocked by the model: ${blockReason}`;
        }
    }
    return "Empty response from the model";
}

# Returns the candidate's finish reason when generation stopped for a reason other
# than normal completion ("STOP") — e.g. truncation ("MAX_TOKENS"), safety filtering
# ("SAFETY"), recitation ("RECITATION") or a malformed tool call
# ("MALFORMED_FUNCTION_CALL").
#
# + candidate - The response candidate
# + return - The finish reason, or `()` when generation completed normally
isolated function abnormalFinishReason(Candidate candidate) returns string? {
    string? finishReason = candidate.finishReason;
    if finishReason is string && finishReason != "STOP" {
        return finishReason;
    }
    return ();
}

# Formats the abnormal finish reason as a parenthetical suffix for an error message.
#
# + candidate - The response candidate
# + return - `" (finishReason: <reason>)"`, or "" for normal completion
isolated function finishReasonNote(Candidate candidate) returns string {
    string? finishReason = abnormalFinishReason(candidate);
    return finishReason is string ? string ` (finishReason: ${finishReason})` : "";
}

# Builds an error message for a candidate that produced neither text nor a function
# call. Without this, such a candidate becomes a valid-looking `ai:ChatAssistantMessage`
# with `content` and `toolCalls` both `()`, which surfaces inside an agent loop as an
# inscrutable downstream failure rather than an actionable error.
#
# + candidate - The response candidate that yielded no usable content
# + response - The full response, consulted for `promptFeedback.blockReason`
# + return - A message naming the finish reason and block reason where available
isolated function buildUnusableCandidateMessage(Candidate candidate,
        GenerateContentResponse response) returns string {
    string message = "The model returned no usable content";
    string? finishReason = abnormalFinishReason(candidate);
    if finishReason is string {
        message += string ` (finishReason: ${finishReason})`;
        if finishReason == "MAX_TOKENS" {
            message += "; generation was truncated before any text was produced. Thinking " +
                "tokens count towards 'maxTokens', so raising 'maxTokens' may resolve this";
        }
    }
    PromptFeedback? feedback = response.promptFeedback;
    if feedback is PromptFeedback {
        string? blockReason = feedback.blockReason;
        if blockReason is string {
            message += string `; prompt blocked by the model: ${blockReason}`;
        }
    }
    return message;
}

# Concatenates the text parts of a response candidate.
#
# + candidate - The response candidate
# + return - The combined text, or `()` when no text is present
isolated function extractTextFromCandidate(Candidate candidate) returns string? {
    Content? content = candidate.content;
    if content is () {
        return ();
    }
    string text = "";
    foreach Part part in content.parts {
        string? partText = part.text;
        if partText is string {
            text += partText;
        }
    }
    return text.length() > 0 ? text : ();
}

# Backs the dependently-typed `generate` method (via the native `Generator` shim).
# Uses Gemini's native structured output: the expected type's JSON schema is sent
# as `generationConfig.responseSchema` with `responseMimeType` = "application/json",
# and the returned JSON text is parsed back into the expected type.
#
# + httpClient - The provider's HTTP client
# + apiKey - The Gemini API key, sent as the `x-goog-api-key` header
# + modelType - The Gemini model to invoke
# + temperature - The temperature for controlling randomness in the model's output; omitted
#                 from the request when `()` so the model's own default applies
# + maxTokens - The upper limit for the number of tokens in the generated response
# + prompt - The prompt to send
# + expectedResponseTypedesc - The caller's expected return type
# + return - The generated value bound to the expected type, or an `ai:Error`
isolated function generateLlmResponse(http:Client httpClient, string apiKey, GEMINI_MODEL_NAMES modelType,
        decimal? temperature, int maxTokens,
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(modelType);
    span.addProvider("gemini");

    Part[] parts;
    ResponseSchema responseSchema;
    do {
        parts = check generateChatCreationContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
    } on fail ai:Error err {
        span.close(err);
        return err;
    }

    // Structured output is requested through `responseJsonSchema`, which accepts
    // standard JSON Schema on Gemini 2.5 models and later — including `$ref`/`$defs`,
    // `additionalProperties`, `title` and `prefixItems`. Only `oneOf`/`allOf` are
    // rewritten (to the documented `anyOf`). `responseSchema` must be left unset:
    // Gemini rejects a request that carries both. Note a top-level `map<T>` return type
    // is still unsupported by the schema generator itself, and very large or deeply
    // nested schemas may still be rejected by the API.
    map<json> normalizedSchema = normalizeJsonObjectSchema(responseSchema.schema);
    GenerationConfig generationConfig = {
        maxOutputTokens: maxTokens,
        responseMimeType: JSON_MIME_TYPE,
        responseJsonSchema: normalizedSchema
    };
    if temperature is decimal {
        generationConfig.temperature = temperature;
    }
    GenerateContentRequest request = {
        contents: [{role: GEMINI_ROLE_USER, parts}],
        generationConfig
    };
    span.addInputMessages(request.contents.toJson());

    map<string|string[]> headers = {[API_KEY_HEADER]: apiKey};
    string path = string `/models/${modelType}:generateContent`;
    GenerateContentResponse|error response = httpClient->post(path, request, headers);
    if response is error {
        ai:Error err = mapHttpError(response);
        span.close(err);
        return err;
    }

    Candidate[]? candidates = response.candidates;
    if candidates is () || candidates.length() == 0 {
        ai:Error err = error ai:LlmInvalidResponseError(buildEmptyCandidatesMessage(response));
        span.close(err);
        return err;
    }

    recordResponseTelemetry(span, response);

    string? generatedText = extractTextFromCandidate(candidates[0]);
    if generatedText is () {
        ai:Error err = error ai:LlmInvalidResponseError(
                NO_RELEVANT_RESPONSE_FROM_THE_LLM + finishReasonNote(candidates[0]));
        span.close(err);
        return err;
    }

    anydata|error res = parseResponseAsType(generatedText, expectedResponseTypedesc,
            responseSchema.isOriginallyJsonObject);
    if res is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'${finishReasonNote(candidates[0])}`);
        span.close(err);
        return err;
    }

    anydata|error result = res.ensureType(expectedResponseTypedesc);
    if result is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${(typeof res).toBalString()}'`);
        span.close(err);
        return err;
    }

    span.addOutputMessages(result.toJson());
    span.addOutputType(observe:JSON);
    span.close();
    return result;
}
