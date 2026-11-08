package com.anton.smartulsu.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser

object LoginBridgeCodec {
    fun decode(raw: String): JsonObject? =
        runCatching {
                if (raw.length > 65536) return null
                val outer = JsonParser.parseString(raw)
                if (!outer.isJsonPrimitive || !outer.asJsonPrimitive.isString) return null
                val inner = JsonParser.parseString(outer.asString)
                if (!inner.isJsonObject) return null
                val result = inner.asJsonObject
                val kind = result.get("kind") ?: return null
                if (
                    !kind.isJsonPrimitive ||
                        !kind.asJsonPrimitive.isString ||
                        kind.asString !in setOf("credentials", "code", "authenticated", "web")
                )
                    return null
                for (k in listOf("error", "reason", "outcome", "documentId")) result.get(k)?.let {
                    if (!it.isJsonPrimitive || !it.asJsonPrimitive.isString) return null
                }
                for (k in listOf("submitted", "pending")) result.get(k)?.let {
                    if (!it.isJsonPrimitive || !it.asJsonPrimitive.isBoolean) return null
                }
                result.get("responseRevision")?.let {
                    if (!it.isJsonPrimitive || !it.asJsonPrimitive.isNumber || it.asLong < 0)
                        return null
                }
                result.get("error")?.let { result.addProperty("error", LoginMessages.normalize(it.asString)) }
                result
            }
            .getOrNull()
}
