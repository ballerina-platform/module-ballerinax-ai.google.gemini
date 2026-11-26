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
import ballerina/http;
import ballerina/lang.runtime;
import ballerina/oauth2;
import ballerina/test;

const AUTH_MOCK_URL = "http://localhost:8097/auth";
const OAUTH_CLIENT_ID = "test-client.apps.googleusercontent.com";
const OAUTH_CLIENT_SECRET = "test-client-secret";
const OAUTH_REFRESH_TOKEN = "test-refresh-token";
const QUOTA_PROJECT = "my-quota-project";

// Requests received by the mock token endpoint, per test.
isolated map<map<string>[]> tokenRequests = {};
// The authentication headers of each Gemini request, per test and call type.
isolated map<map<string>[]> geminiAuthHeaders = {};

service /auth on new http:Listener(8097) {
    // Mock Google OAuth 2.0 token endpoint. Issues access tokens that expire in `expiresIn` seconds, or fails with
    // `invalid_grant` when `expiresIn` is -1.
    resource function post [string testId]/[int expiresIn]/token(http:Request req)
            returns json|http:BadRequest|error {
        map<string> form = check req.getFormParams();
        // The client ID and secret are sent in a Basic `Authorization` header.
        string|http:HeaderNotFoundError authorization = req.getHeader(AUTHORIZATION_HEADER);
        if authorization is string {
            form["authorization"] = authorization;
        }
        int count;
        lock {
            map<string>[] requests = tokenRequests[testId] ?: [];
            requests.push(form.clone());
            tokenRequests[testId] = requests;
            count = requests.length();
        }
        if expiresIn == -1 {
            return <http:BadRequest>{
                body: {'error: "invalid_grant", error_description: "Token has been expired or revoked."}
            };
        }
        return {access_token: string `oauth-access-token-${testId}-${count}`, expires_in: expiresIn,
            token_type: "Bearer", scope: "https://www.googleapis.com/auth/cloud-platform"};
    }

    // Mock Gemini API. Records the authentication headers and returns a generate, embed, or batch embed response.
    resource function post [string testId]/models/[string operation](http:Request req, @http:Payload json payload)
            returns json {
        string callType = operation.endsWith(":embedContent") ? "embed"
            : operation.endsWith(":batchEmbedContents") ? "batchEmbed"
            : payload.generationConfig.responseJsonSchema is json && payload.generationConfig.responseJsonSchema != ()
                ? "generate" : "chat";
        map<string> headers = {};
        foreach string name in [AUTHORIZATION_HEADER, API_KEY_HEADER, QUOTA_PROJECT_HEADER] {
            string|http:HeaderNotFoundError value = req.getHeader(name);
            if value is string {
                headers[name] = value;
            }
        }
        lock {
            map<string>[] received = geminiAuthHeaders[string `${testId}/${callType}`] ?: [];
            received.push(headers.clone());
            geminiAuthHeaders[string `${testId}/${callType}`] = received;
        }
        if callType == "embed" {
            return {embedding: {values: [0.1, 0.2, 0.3]}};
        }
        if callType == "batchEmbed" {
            return {embeddings: [{values: [0.1, 0.2]}, {values: [0.3, 0.4]}]};
        }
        return buildTextResponse(callType == "generate" ? "{\"result\": 2}" : "Hi");
    }
}

function geminiUrl(string testId) returns string => string `${AUTH_MOCK_URL}/${testId}`;

function oauthConfig(string testId, int expiresIn = 3600, string? quotaProjectId = ()) returns OAuth2RefreshConfig {
    OAuth2RefreshConfig config = {
        clientId: OAUTH_CLIENT_ID,
        clientSecret: OAUTH_CLIENT_SECRET,
        refreshToken: OAUTH_REFRESH_TOKEN,
        refreshUrl: string `${AUTH_MOCK_URL}/${testId}/${expiresIn}/token`
    };
    if quotaProjectId is string {
        config.quotaProjectId = quotaProjectId;
    }
    return config;
}

function getTokenRequests(string testId) returns map<string>[] {
    lock {
        return (tokenRequests[testId] ?: []).clone();
    }
}

function getGeminiAuthHeaders(string testId, string callType) returns map<string>[] {
    lock {
        return (geminiAuthHeaders[string `${testId}/${callType}`] ?: []).clone();
    }
}

function assertGeminiAuth(string testId, string[] callTypes, map<string> expected) {
    foreach string callType in callTypes {
        map<string>[] received = getGeminiAuthHeaders(testId, callType);
        test:assertTrue(received.length() > 0, string `No ${callType} request received`);
        test:assertEquals(received[received.length() - 1], expected, string `Headers of the ${callType} request`);
    }
}

function callAll(ModelProvider provider, EmbeddingProvider embeddingProvider) returns error? {
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    int result = check provider->generate(`Pick a number`);
    test:assertEquals(result, 2);
    _ = check embeddingProvider->embed(<ai:TextChunk>{content: "Hello"});
    _ = check embeddingProvider->batchEmbed([<ai:TextChunk>{content: "Hello"}, <ai:TextChunk>{content: "World"}]);
}

@test:Config
function testApiKeyAuth() returns error? {
    string testId = "api-key";
    // A string is still an API key, sent in `x-goog-api-key` and trimmed.
    string key = string ` ${API_KEY}${"\n"}`;
    check callAll(check new (key, GEMINI_3_8_FLASH, geminiUrl(testId)),
        check new (key, GEMINI_EMBEDDING_2, geminiUrl(testId)));
    assertGeminiAuth(testId, ["chat", "generate", "embed", "batchEmbed"], {[API_KEY_HEADER]: API_KEY});
}

@test:Config
function testOAuth2RefreshAuth() returns error? {
    string testId = "oauth-refresh";
    OAuth2RefreshConfig config = oauthConfig(testId);
    check callAll(check new (config, GEMINI_3_8_FLASH, geminiUrl(testId)),
        check new (config, GEMINI_EMBEDDING_2, geminiUrl(testId)));
    // The model and embedding providers each get an access token with the refresh token, and reuse it.
    assertGeminiAuth(testId, ["chat", "generate"],
        {[AUTHORIZATION_HEADER]: string `Bearer oauth-access-token-${testId}-1`});
    assertGeminiAuth(testId, ["embed", "batchEmbed"],
        {[AUTHORIZATION_HEADER]: string `Bearer oauth-access-token-${testId}-2`});

    map<string>[] requests = getTokenRequests(testId);
    test:assertEquals(requests.length(), 2);
    test:assertEquals(requests[0]["grant_type"], "refresh_token");
    test:assertEquals(requests[0]["refresh_token"], OAUTH_REFRESH_TOKEN);
}

@test:Config
function testOAuth2RefreshCredentialsAreTrimmed() returns error? {
    string testId = "oauth-trimmed";
    // Credentials read from a file or an environment variable may end with a newline.
    OAuth2RefreshConfig config = {
        clientId: string ` ${OAUTH_CLIENT_ID}${"\n"}`,
        clientSecret: string `${OAUTH_CLIENT_SECRET}${"\n"}`,
        refreshToken: string `${OAUTH_REFRESH_TOKEN}${"\n"}`,
        refreshUrl: string `${AUTH_MOCK_URL}/${testId}/3600/token`
    };
    ModelProvider provider = check new (config, GEMINI_3_8_FLASH, geminiUrl(testId));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    map<string> request = getTokenRequests(testId)[0];
    test:assertEquals(request["refresh_token"], OAUTH_REFRESH_TOKEN);
    test:assertEquals(request["authorization"],
        string `Basic ${string `${OAUTH_CLIENT_ID}:${OAUTH_CLIENT_SECRET}`.toBytes().toBase64()}`);
}

@test:Config
function testOAuth2TokenRequestUsesSecureSocket() {
    // The token request gets the same TLS settings as the Gemini requests.
    oauth2:SecureSocket tokenSecureSocket = toOAuth2SecureSocket({
        cert: {path: "truststore.p12", password: "truststore-password"},
        key: {certFile: "client.crt", keyFile: "client.key", keyPassword: "key-password"}
    });
    test:assertEquals(tokenSecureSocket, {
        disable: false,
        cert: {path: "truststore.p12", password: "truststore-password"},
        key: {certFile: "client.crt", keyFile: "client.key", keyPassword: "key-password"}
    });
    test:assertEquals(toOAuth2SecureSocket({enable: false}), {disable: true});

    http:ClientConfiguration clientConfig = toHttpClientConfig(oauthConfig("secure-socket"),
        {secureSocket: {cert: "server.crt"}});
    http:ClientAuthConfig? auth = clientConfig.auth;
    if auth !is http:OAuth2RefreshTokenGrantConfig {
        test:assertFail("Expected the refresh token grant");
    }
    test:assertEquals(auth.clientConfig?.secureSocket, {disable: false, cert: "server.crt"});
}

@test:Config
function testOAuth2RefreshWithQuotaProject() returns error? {
    string testId = "oauth-quota-project";
    OAuth2RefreshConfig config = oauthConfig(testId, quotaProjectId = QUOTA_PROJECT);
    check callAll(check new (config, GEMINI_3_8_FLASH, geminiUrl(testId)),
        check new (config, GEMINI_EMBEDDING_2, geminiUrl(testId)));
    assertGeminiAuth(testId, ["chat", "generate"], {
        [AUTHORIZATION_HEADER]: string `Bearer oauth-access-token-${testId}-1`,
        [QUOTA_PROJECT_HEADER]: QUOTA_PROJECT
    });
    assertGeminiAuth(testId, ["embed", "batchEmbed"], {
        [AUTHORIZATION_HEADER]: string `Bearer oauth-access-token-${testId}-2`,
        [QUOTA_PROJECT_HEADER]: QUOTA_PROJECT
    });
}

@test:Config
function testOAuth2RefreshesExpiredAccessToken() returns error? {
    string testId = "oauth-expiry";
    // The HTTP client refreshes the access token when it is about to expire.
    ModelProvider provider = check new (oauthConfig(testId, expiresIn = 2), GEMINI_3_8_FLASH, geminiUrl(testId));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    runtime:sleep(2.5);
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    test:assertTrue(getTokenRequests(testId).length() >= 2, getTokenRequests(testId).toString());
    map<string>[] received = getGeminiAuthHeaders(testId, "chat");
    test:assertNotEquals(received[0][AUTHORIZATION_HEADER], received[1][AUTHORIZATION_HEADER]);
}

@test:Config
function testOAuth2RefreshFailure() returns error? {
    string testId = "oauth-revoked";
    // The HTTP client gets the first access token when it is created, so a revoked refresh token fails the
    // provider initialization instead of the first request.
    ModelProvider|ai:Error provider = new (oauthConfig(testId, expiresIn = -1), GEMINI_3_8_FLASH, geminiUrl(testId));
    if provider !is ai:Error {
        test:assertFail("Expected an ai:Error when the refresh token is revoked");
    }
    test:assertEquals(provider.message(), "Failed to initialize the Gemini client");
    error? cause = provider.cause();
    string causeText = cause is error ? cause.toString() : "<no cause>";
    test:assertTrue(causeText.includes("invalid_grant"), causeText);
    EmbeddingProvider|ai:Error embeddingProvider =
        new (oauthConfig(testId, expiresIn = -1), GEMINI_EMBEDDING_2, geminiUrl(testId));
    test:assertTrue(embeddingProvider is ai:Error, "Expected an ai:Error when the refresh token is revoked");
    // No request reaches the Gemini API without an access token.
    test:assertEquals(getGeminiAuthHeaders(testId, "chat").length(), 0);
}

@test:Config
function testBearerTokenAuth() returns error? {
    string testId = "bearer";
    BearerTokenConfig config = {token: "ya29.access-token\n"};
    check callAll(check new (config, GEMINI_3_8_FLASH, geminiUrl(testId)),
        check new (config, GEMINI_EMBEDDING_2, geminiUrl(testId)));
    assertGeminiAuth(testId, ["chat", "generate", "embed", "batchEmbed"],
        {[AUTHORIZATION_HEADER]: "Bearer ya29.access-token"});
}

@test:Config
function testBearerTokenWithQuotaProject() returns error? {
    string testId = "bearer-quota-project";
    // A token from the `gcloud` default OAuth client needs a quota project.
    BearerTokenConfig config = {token: "ya29.access-token", quotaProjectId: string ` ${QUOTA_PROJECT}${"\n"}`};
    check callAll(check new (config, GEMINI_3_8_FLASH, geminiUrl(testId)),
        check new (config, GEMINI_EMBEDDING_2, geminiUrl(testId)));
    assertGeminiAuth(testId, ["chat", "generate", "embed", "batchEmbed"],
        {[AUTHORIZATION_HEADER]: "Bearer ya29.access-token", [QUOTA_PROJECT_HEADER]: QUOTA_PROJECT});
}

@test:Config
function testHttpBearerTokenConfigStillAccepted() returns error? {
    string testId = "http-bearer";
    // Code written against the earlier `http:BearerTokenConfig` option still compiles.
    http:BearerTokenConfig config = {token: "ya29.access-token"};
    ModelProvider provider = check new (config, GEMINI_3_8_FLASH, geminiUrl(testId));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    assertGeminiAuth(testId, ["chat"], {[AUTHORIZATION_HEADER]: "Bearer ya29.access-token"});
}

@test:Config
function testEmptyCredentialFails() {
    foreach [AuthConfig, string] [auth, message] in [
        ["", "The Gemini API key is empty"],
        [" \n", "The Gemini API key is empty"],
        [{token: ""}, "The Gemini access token is empty"]
    ] {
        ModelProvider|ai:Error provider = new (auth, GEMINI_3_8_FLASH);
        if provider !is ai:Error {
            test:assertFail("Expected an ai:Error for an empty credential");
        }
        test:assertEquals(provider.message(), message);
        EmbeddingProvider|ai:Error embeddingProvider = new (auth, GEMINI_EMBEDDING_2);
        if embeddingProvider !is ai:Error {
            test:assertFail("Expected an ai:Error for an empty credential");
        }
        test:assertEquals(embeddingProvider.message(), message);
    }
}

@test:Config
function testAuthConfigType() {
    // `AuthConfig` is public and `anydata`, so it can be kept in a variable or made `configurable`.
    AuthConfig[] configs = [API_KEY, {token: "access-token"}, oauthConfig("auth-config-type")];
    foreach AuthConfig config in configs {
        test:assertTrue(config is anydata);
    }
    OAuth2RefreshConfig config = {clientId: "id", clientSecret: "secret", refreshToken: "token"};
    test:assertEquals(config.refreshUrl, "https://oauth2.googleapis.com/token");
    test:assertTrue(config.quotaProjectId is ());
}
