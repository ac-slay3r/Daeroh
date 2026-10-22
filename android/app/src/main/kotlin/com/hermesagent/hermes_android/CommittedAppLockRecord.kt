package com.hermesagent.hermes_android

/**
 * Single-writer commit boundary, independent of Android for host fault tests.
 * The backing write MUST acknowledge synchronous disk commit, not memory update.
 * A failed commit can still mutate SharedPreferences' process cache. Poison this
 * instance until process restart so that cache can never become security state.
 */
internal class CommittedAppLockRecord(
    private val readEncrypted: () -> String?,
    private val decrypt: (String) -> String,
    private val encrypt: (String) -> String,
    private val commitEncrypted: (String) -> Boolean,
    private val checkAbsent: () -> Unit,
) {
    private var failed = false

    private fun <T> guarded(action: () -> T): T {
        check(!failed) { "App-lock storage unavailable until restart" }
        try {
            return action()
        } catch (error: Exception) {
            failed = true
            throw error
        }
    }

    fun read(): String? = guarded {
        val value = readEncrypted()
        if (value == null) {
            checkAbsent()
            null
        } else {
            decrypt(value)
        }
    }

    fun initialize(value: String) {
        // Idempotent migration: never overwrite an already committed record.
        if (read() == null) write(value)
    }

    fun write(value: String) = guarded {
        check(commitEncrypted(encrypt(value))) { "App-lock disk commit failed" }
    }
}
