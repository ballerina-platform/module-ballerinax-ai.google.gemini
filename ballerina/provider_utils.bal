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
# + allowPrivateHosts - Allows document URLs to resolve to non-public addresses
# + return - The ordered content parts, or an `ai:Error` for unsupported documents
isolated function generateChatCreationContent(ai:Prompt prompt, boolean allowPrivateHosts)
        returns Part[]|ai:Error {
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
            check addDocumentPart(insertion, parts, allowPrivateHosts);
        } else if insertion is (ai:Document|ai:Chunk)[] {
            addTextPart(accumulatedTextContent, parts);
            accumulatedTextContent = "";
            foreach ai:Document|ai:Chunk doc in insertion {
                check addDocumentPart(doc, parts, allowPrivateHosts);
            }
        } else {
            accumulatedTextContent += insertion.toString();
        }
        accumulatedTextContent += str;
    }

    addTextPart(accumulatedTextContent, parts);
    return parts;
}

isolated function addDocumentPart(ai:Document|ai:Chunk doc, Part[] parts, boolean allowPrivateHosts)
        returns ai:Error? {
    if doc is ai:TextDocument|ai:TextChunk {
        addTextPart(doc.content, parts);
        return;
    } else if doc is ai:ImageDocument {
        parts.push(check buildImagePart(doc, allowPrivateHosts));
        return;
    } else if doc is ai:FileDocument {
        parts.push(check buildFilePart(doc, allowPrivateHosts));
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
# + allowPrivateHosts - Allows a document URL to resolve to a non-public address
# + return - The corresponding part, or an `ai:Error` on failure
isolated function buildFilePart(ai:FileDocument doc, boolean allowPrivateHosts) returns Part|ai:Error {
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
        [byte[], string?] downloaded = check downloadDocument(content, allowPrivateHosts);
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
# + allowPrivateHosts - Allows a document URL to resolve to a non-public address
# + return - The image part, or an `ai:Error` when the MIME type cannot be
#            determined or the download fails
isolated function buildImagePart(ai:ImageDocument doc, boolean allowPrivateHosts) returns Part|ai:Error {
    ai:Url|byte[] content = doc.content;
    if content is ai:Url {
        [byte[], string?] downloaded = check downloadDocument(content, allowPrivateHosts);
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
# + allowPrivateHosts - Skips the non-public destination check when `true`
# + return - The downloaded bytes and the response MIME type (`Content-Type`
#            without parameters, `()` when absent), or an `ai:Error` on failure
isolated function downloadDocument(ai:Url url, boolean allowPrivateHosts) returns [byte[], string?]|ai:Error {
    string currentUrl = url;
    foreach int hop in 0 ... MAX_DOCUMENT_REDIRECTS {
        [string, string] originPath = check splitUrl(currentUrl);
        check validateDownloadDestination(originPath[0], allowPrivateHosts);
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
# Only `http` and `https` are permitted. Unless `allowPrivateHosts` is set, a host that
# is a literal loopback, private, link-local, carrier-grade-NAT or unspecified address
# is rejected, as is `localhost`.
#
# Note this checks the literal host in the URL. A public DNS name that resolves to an
# internal address is not detected, because resolving it here and connecting separately
# would still leave a TOCTOU gap. Deployments handling genuinely untrusted URLs should
# pair this with an egress policy at the network layer.
#
# + origin - The origin (`scheme://host[:port]`) to check
# + allowPrivateHosts - Skips the non-public destination check when `true`
# + return - `()` when the destination is permitted, otherwise an `ai:Error`
isolated function validateDownloadDestination(string origin, boolean allowPrivateHosts) returns ai:Error? {
    string lowered = origin.toLowerAscii();
    if !lowered.startsWith("http://") && !lowered.startsWith("https://") {
        return error ai:Error(string `Only 'http' and 'https' document URLs are supported, got '${origin}'.`);
    }
    if allowPrivateHosts {
        return;
    }
    string host = extractHost(lowered);
    if isNonPublicHost(host) {
        return error ai:Error(string `Refusing to download a document from '${host}', which is not a public ` +
                "address. Set 'allowPrivateDocumentHosts' to true if documents are served from a trusted " +
                "internal host.");
    }
    return;
}

# Extracts the host from a lowercased origin, dropping the scheme, any port, and the
# brackets around an IPv6 literal.
#
# + origin - The lowercased origin (`scheme://host[:port]`)
# + return - The bare host
isolated function extractHost(string origin) returns string {
    int? schemeIdx = origin.indexOf("://");
    string hostPort = schemeIdx is int ? origin.substring(schemeIdx + 3) : origin;
    if hostPort.startsWith("[") {
        int? closing = hostPort.indexOf("]");
        return closing is int ? hostPort.substring(1, closing) : hostPort.substring(1);
    }
    int? portIdx = hostPort.indexOf(":");
    return portIdx is int ? hostPort.substring(0, portIdx) : hostPort;
}

# Reports whether a literal host is a loopback, private, link-local, CGNAT or
# unspecified address, or a `localhost` name.
#
# + host - The bare lowercased host
# + return - `true` when the host must not be reached
isolated function isNonPublicHost(string host) returns boolean {
    if host == "localhost" || host.endsWith(".localhost") || host.length() == 0 {
        return true;
    }
    int[]? octets = parseIpv4(host);
    if octets is int[] {
        return isNonPublicIpv4(octets);
    }
    if host.includes(":") {
        // IPv6 literal. `::ffff:a.b.c.d` maps an IPv4 address into v6 space, so the
        // embedded address is checked with the same rules rather than being let through.
        int? lastColon = host.lastIndexOf(":");
        if lastColon is int {
            int[]? mapped = parseIpv4(host.substring(lastColon + 1));
            if mapped is int[] {
                return isNonPublicIpv4(mapped);
            }
        }
        if host == "::1" || host == "::" {
            return true;
        }
        // fc00::/7 (unique local) and fe80::/10 (link-local).
        return host.startsWith("fc") || host.startsWith("fd")
            || host.startsWith("fe8") || host.startsWith("fe9")
            || host.startsWith("fea") || host.startsWith("feb");
    }
    return false;
}

isolated function isNonPublicIpv4(int[] octets) returns boolean {
    int first = octets[0];
    int second = octets[1];
    // 0.0.0.0/8 unspecified, 127/8 loopback, 10/8 + 172.16/12 + 192.168/16 private,
    // 169.254/16 link-local, 100.64/10 carrier-grade NAT, 192.0.0/24 IETF protocol.
    return first == 0 || first == 127 || first == 10
        || (first == 172 && second >= 16 && second <= 31)
        || (first == 192 && second == 168)
        || (first == 169 && second == 254)
        || (first == 100 && second >= 64 && second <= 127)
        || (first == 192 && second == 0 && octets[2] == 0);
}

# Parses a dotted-quad IPv4 literal.
#
# + host - The host to parse
# + return - The four octets, or `()` when `host` is not an IPv4 literal
isolated function parseIpv4(string host) returns int[]? {
    string[] parts = re `\.`.split(host);
    if parts.length() != 4 {
        return ();
    }
    int[] octets = [];
    foreach string part in parts {
        if part.length() == 0 || part.length() > 3 {
            return ();
        }
        int|error octet = int:fromString(part);
        if octet is error || octet < 0 || octet > 255 {
            return ();
        }
        octets.push(octet);
    }
    return octets;
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
# + allowPrivateDocumentHosts - Allows document URLs to resolve to non-public addresses
# + prompt - The prompt to send
# + expectedResponseTypedesc - The caller's expected return type
# + return - The generated value bound to the expected type, or an `ai:Error`
isolated function generateLlmResponse(http:Client httpClient, string apiKey, GEMINI_MODEL_NAMES modelType,
        decimal? temperature, int maxTokens, boolean allowPrivateDocumentHosts,
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(modelType);
    span.addProvider("gemini");

    Part[] parts;
    ResponseSchema responseSchema;
    do {
        parts = check generateChatCreationContent(prompt, allowPrivateDocumentHosts);
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
