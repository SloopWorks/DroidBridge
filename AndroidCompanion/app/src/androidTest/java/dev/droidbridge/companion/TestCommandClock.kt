package dev.droidbridge.companion

import org.json.JSONObject

/** Uses the peer's actual monotonic clock; wall-clock fields remain diagnostic. */
fun clockedCommand(store: BridgeStore, request: JSONObject, lifetimeMs: Long = 25_000): JSONObject {
    val hello = store.hello()
    val issued = hello.getLong("server_uptime_ms")
    return request.put("clock_epoch", hello.getString("clock_epoch"))
        .put("issued_uptime_ms", issued).put("expires_uptime_ms", issued + lifetimeMs)
}
