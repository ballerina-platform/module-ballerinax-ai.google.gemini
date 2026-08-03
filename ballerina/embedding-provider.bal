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

# EmbeddingProvider provides an interface for interacting with Gemini Embedding Models.
public distinct isolated client class EmbeddingProvider {
    *ai:EmbeddingProvider;
    private final http:Client httpClient;
    private final string apiKey;
    private final GEMINI_EMBEDDING_MODEL_NAMES modelType;

    # Initializes the Gemini embedding model with the given connection configuration.
    #
    # + apiKey - The Gemini API key
    # + modelType - The Gemini embedding model name
    # + serviceUrl - The base URL of Gemini API endpoint
    # + connectionConfig - Additional HTTP connection configuration
    # + return - `nil` on successful initialization; otherwise, returns an `ai:Error`
    public isolated function init(@display {label: "API Key"} string apiKey,
            @display {label: "Embedding Model Type"} GEMINI_EMBEDDING_MODEL_NAMES modelType,
            @display {label: "Service URL"} string serviceUrl = DEFAULT_GEMINI_SERVICE_URL,
            @display {label: "Connection Configuration"} *ConnectionConfig connectionConfig) returns ai:Error? {
        // `ConnectionConfig` is a field-compatible subset of `http:ClientConfiguration`
        // (it omits `auth`; Gemini authenticates via the `x-goog-api-key` header).
        http:Client|error httpClient = new (serviceUrl, {...connectionConfig});
        if httpClient is error {
            return error ai:Error("Failed to initialize Gemini embedding provider", httpClient);
        }
        self.httpClient = httpClient;
        self.apiKey = apiKey;
        self.modelType = modelType;
    }

    # Generates an embedding vector for the provided chunk.
    #
    # + chunk - The `ai:Chunk` containing the content to embed
    # + return - The resulting `ai:Embedding` on success; otherwise, returns an `ai:Error`
    isolated remote function embed(ai:Chunk chunk) returns ai:Embedding|ai:Error {
        observe:EmbeddingSpan span = observe:createEmbeddingSpan(self.modelType);
        span.addProvider("gemini");

        if chunk !is ai:TextDocument|ai:TextChunk {
            ai:Error err = error("Unsupported document type. only 'ai:TextDocument|ai:TextChunk' is supported");
            span.close(err);
            return err;
        }
        do {
            string content = chunk.content;
            EmbedContentRequest request = {
                model: string `models/${self.modelType}`,
                content: {parts: [{text: content}]}
            };
            span.addInputContent(content);
            map<string|string[]> headers = {[API_KEY_HEADER]: self.apiKey};
            string path = string `/models/${self.modelType}:embedContent`;
            EmbedContentResponse response = check self.httpClient->post(path, request, headers);

            span.addResponseModel(self.modelType);
            UsageMetadata? usage = response.usageMetadata;
            if usage is UsageMetadata {
                int? inputTokens = usage.promptTokenCount;
                if inputTokens is int {
                    span.addInputTokenCount(inputTokens);
                }
            }
            ai:Embedding embedding = response.embedding.values;
            span.close();
            return embedding;
        } on fail error e {
            ai:Error err = error("Unable to obtain embedding for the provided document", e);
            span.close(err);
            return err;
        }
    }

    # Converts a batch of chunks into embeddings.
    #
    # + chunks - The array of chunks to be converted into embeddings
    # + return - An array of embeddings on success, or an `ai:Error`
    isolated remote function batchEmbed(ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error {
        observe:EmbeddingSpan span = observe:createEmbeddingSpan(self.modelType);
        span.addProvider("gemini");

        if !isAllTextChunks(chunks) {
            ai:Error err = error("Unsupported chunk type. only 'ai:TextChunk[]|ai:TextDocument[]' is supported");
            span.close(err);
            return err;
        }
        // Gemini rejects an empty `requests` array with a 400, so short-circuit.
        if chunks.length() == 0 {
            span.close();
            return [];
        }
        do {
            string[] input = chunks.map(chunk => chunk.content.toString());
            EmbedContentRequest[] requests = [];
            foreach string text in input {
                requests.push({
                    model: string `models/${self.modelType}`,
                    content: {parts: [{text}]}
                });
            }
            BatchEmbedContentsRequest request = {requests};
            span.addInputContent(input);
            map<string|string[]> headers = {[API_KEY_HEADER]: self.apiKey};
            string path = string `/models/${self.modelType}:batchEmbedContents`;
            BatchEmbedContentsResponse response = check self.httpClient->post(path, request, headers);

            // The contract is one embedding per input chunk, in order. A short or
            // partial response would silently misalign every downstream vector with
            // the wrong chunk, corrupting a vector store in a way that is very hard
            // to diagnose later, so fail loudly instead.
            if response.embeddings.length() != chunks.length() {
                return error ai:Error(string `Expected ${chunks.length()} embeddings from the model but received ${
                    response.embeddings.length()}`);
            }

            span.addResponseModel(self.modelType);
            ai:Embedding[] embeddings = [];
            foreach ContentEmbedding contentEmbedding in response.embeddings {
                embeddings.push(contentEmbedding.values);
            }
            span.close();
            return embeddings;
        } on fail error e {
            ai:Error err = error("Unable to obtain embedding for the provided document", e);
            span.close(err);
            return err;
        }
    }
}

isolated function isAllTextChunks(ai:Chunk[] chunks) returns boolean {
    return chunks.every(chunk => chunk is ai:TextChunk|ai:TextDocument);
}
