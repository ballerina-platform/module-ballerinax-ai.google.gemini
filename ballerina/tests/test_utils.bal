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

import ballerina/test;

// Expected schema fixtures for the request assertions in `test_services.bal`.
//
// Schema handling is the riskiest part of this connector: a regression here produces
// no error, just silently worse model output. These fixtures pin the exact JSON sent
// as `generationConfig.responseJsonSchema` and `functionDeclarations[].parametersJsonSchema`.

// `int` return type — the generator wraps a non-object return in a single-key object.
isolated function expectedIntResponseSchema() returns map<json> => {
    "type": "object",
    "properties": {"result": {"type": "integer"}},
    "required": ["result"]
};

// `string` return type.
isolated function expectedStringResponseSchema() returns map<json> => {
    "type": "object",
    "properties": {"result": {"type": "string"}},
    "required": ["result"]
};

// `int[]` return type.
isolated function expectedIntArrayResponseSchema() returns map<json> => {
    "type": "object",
    "properties": {"result": {"type": "array", "items": {"type": "integer"}}},
    "required": ["result"]
};

// Nested record (`Person` containing `Address`). The nested object must keep its own
// `properties` and `required` — under the previous deny-list sanitiser a `$ref`-based
// schema would have degraded to an unconstrained `{}` here.
isolated function expectedNestedRecordResponseSchema() returns map<json> => {
    "type": "object",
    "properties": {
        "name": {"type": "string"},
        "age": {"type": "integer"},
        "address": {
            "type": "object",
            "properties": {"city": {"type": "string"}, "country": {"type": "string"}},
            "required": ["city", "country"]
        }
    },
    "required": ["address", "age", "name"]
};

// Asserts that `actual` contains every key/value in `expected`, recursively.
//
// A containment check rather than strict equality: the Ballerina schema generator may
// legitimately add keys (e.g. `additionalProperties`) that are not the subject of a
// given assertion, and those now pass through untouched to `responseJsonSchema`.
isolated function assertSchemaContains(map<json> actual, map<json> expected, string context) {
    foreach [string, json] [key, expectedValue] in expected.entries() {
        test:assertTrue(actual.hasKey(key),
                string `${context}: expected schema key '${key}' to be present, got ${actual.toJsonString()}`);
        json actualValue = actual[key];
        if expectedValue is map<json> && actualValue is map<json> {
            assertSchemaContains(actualValue, expectedValue, string `${context}.${key}`);
        } else {
            test:assertEquals(actualValue, expectedValue, string `${context}: mismatch at '${key}'`);
        }
    }
}

// Returns `generationConfig.responseJsonSchema`, or `{}` when absent.
isolated function responseJsonSchemaOf(map<json> payload) returns map<json> {
    map<json> genConfig = generationConfig(payload);
    return genConfig["responseJsonSchema"] is map<json>
        ? <map<json>>genConfig["responseJsonSchema"] : {};
}
