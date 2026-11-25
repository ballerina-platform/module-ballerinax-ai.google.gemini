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

const AUTHORIZATION_HEADER = "authorization";
# Header naming the Google Cloud project that is billed and whose quota is used for an OAuth request.
const QUOTA_PROJECT_HEADER = "x-goog-user-project";
const DEFAULT_GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";

# OAuth 2.0 credentials with a refresh token, such as those that `gcloud auth application-default login` stores in
# `~/.config/gcloud/application_default_credentials.json` when run with your OAuth client (`--client-id-file`) and the
# `cloud-platform` and `generative-language.retriever` scopes. The HTTP client exchanges the refresh token for a
# short-lived access token when it is created, and gets a new one before the access token expires.
# See https://ai.google.dev/gemini-api/docs/oauth
public type OAuth2RefreshConfig record {|
    # The OAuth client ID
    @display {label: "Client ID"}
    string clientId;
    # The OAuth client secret
    @display {label: "Client Secret"}
    string clientSecret;
    # The refresh token. It does not expire unless it is revoked or unused for six months
    @display {label: "Refresh Token"}
    string refreshToken;
    # The Google Cloud project to bill and to count quota against, sent in the `x-goog-user-project` header.
    # Needed when the OAuth client belongs to a different project, such as the `gcloud` default client
    @display {label: "Quota Project ID"}
    string quotaProjectId?;
    # The Google OAuth 2.0 token endpoint
    @display {label: "Token URL"}
    string refreshUrl = DEFAULT_GOOGLE_TOKEN_URL;
|};

# How the model or embedding provider authenticates with the Gemini API: an API key (`string`), OAuth 2.0 credentials
# with a refresh token (`OAuth2RefreshConfig`), or an OAuth 2.0 access token (`http:BearerTokenConfig`), which is not
# refreshed. The record types come first so that the connection form offers a record editor for them.
public type AuthConfig OAuth2RefreshConfig|http:BearerTokenConfig|string;

# Provides the authentication headers for each request to the Gemini API.
type AuthProvider isolated object {
    # Returns the authentication headers to send with a request.
    #
    # + return - The authentication headers
    isolated function getHeaders() returns map<string> & readonly;
};

# Provides headers that do not change. For `OAuth2RefreshConfig`, the HTTP client adds the `Authorization` header.
isolated class StaticAuthProvider {
    *AuthProvider;
    private final map<string> & readonly headers;

    isolated function init(map<string> & readonly headers) {
        self.headers = headers;
    }

    isolated function getHeaders() returns map<string> & readonly => self.headers;
}

# Creates the authentication provider for the given authentication configuration.
#
# + auth - The authentication configuration. A `string` is a Gemini API key
# + return - The authentication provider, or an `ai:Error` if the configuration is invalid
isolated function createAuthProvider(AuthConfig auth) returns AuthProvider|ai:Error {
    if auth is string {
        // Sent in the `x-goog-api-key` header, as in 1.0, so existing users see no change on the wire.
        return new StaticAuthProvider({[API_KEY_HEADER]: check validateCredential(auth, "API key")});
    }
    if auth is http:BearerTokenConfig {
        string token = check validateCredential(auth.token, "access token");
        return new StaticAuthProvider({[AUTHORIZATION_HEADER]: string `Bearer ${token}`});
    }
    string? quotaProjectId = auth.quotaProjectId;
    return new StaticAuthProvider(quotaProjectId is string && quotaProjectId.trim() != ""
        ? {[QUOTA_PROJECT_HEADER]: quotaProjectId.trim()} : {});
}

# Creates the HTTP client configuration. For `OAuth2RefreshConfig`, adds the refresh token grant, so the HTTP client
# adds the `Authorization` header to each request and refreshes the access token before it expires.
#
# + auth - The authentication configuration
# + connectionConfig - The connection configuration
# + return - The HTTP client configuration
isolated function toHttpClientConfig(AuthConfig auth, ConnectionConfig connectionConfig)
        returns http:ClientConfiguration {
    // `ConnectionConfig` is a field-compatible subset of `http:ClientConfiguration` without `auth`, so it can be
    // spread directly.
    http:ClientConfiguration clientConfig = {...connectionConfig};
    if auth is OAuth2RefreshConfig {
        clientConfig.auth = {
            refreshUrl: auth.refreshUrl,
            refreshToken: auth.refreshToken.trim(),
            clientId: auth.clientId,
            clientSecret: auth.clientSecret
        };
    }
    return clientConfig;
}

# Trims a credential, so a value read from a file or an environment variable with a trailing newline still works.
#
# + credential - The credential
# + name - The name of the credential, used in the error message
# + return - The trimmed credential, or an `ai:Error` if it is empty
isolated function validateCredential(string credential, string name) returns string|ai:Error {
    string trimmed = credential.trim();
    if trimmed == "" {
        return error ai:Error(string `The Gemini ${name} is empty`);
    }
    return trimmed;
}
