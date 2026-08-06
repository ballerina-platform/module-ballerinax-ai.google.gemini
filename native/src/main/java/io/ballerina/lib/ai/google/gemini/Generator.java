/*
 * Copyright (c) 2026 WSO2 LLC. (http://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package io.ballerina.lib.ai.google.gemini;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.Module;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BTypedesc;

/**
 * This class provides the native function to generate a response from a Gemini model.
 *
 * @since 1.0.0
 */
public class Generator {
    public static Object generate(Environment env, BObject modelProvider,
                                  BObject prompt, BTypedesc expectedResponseTypedesc) {
        return env.getRuntime().callFunction(
                // The third argument is this package's MAJOR version, which the runtime uses as
                // the module version. It must be updated whenever the major version in
                // gradle.properties changes, or the lookup fails at runtime with
                // "Value creator object is not available for: ballerinax/ai.google.gemini".
                new Module("ballerinax", "ai.google.gemini", "0"), "generateLlmResponse", null,
                modelProvider.get(StringUtils.fromString("httpClient")),
                modelProvider.get(StringUtils.fromString("apiKey")),
                modelProvider.get(StringUtils.fromString("modelType")),
                modelProvider.get(StringUtils.fromString("temperature")),
                modelProvider.get(StringUtils.fromString("maxTokens")),
                prompt, expectedResponseTypedesc);
    }
}
