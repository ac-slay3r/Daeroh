package com.hermesagent.hermes_android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Only the two attempt-limit keys live here; PIN material stays in secure storage.
 * AES-GCM with a non-exportable AndroidKeyStore key (API 23+, app minSdk 29).
 * Every mutation, including deletion, commits a complete encrypted record. An
 * empty record remains as the migration marker; it is never deleted/reimported.
 * Backup is disabled by the app manifest. No recovery path deletes ciphertext.
 * All engines/Activity recreations share one process-wide serial writer/poison.
 */
internal object AppLockAttempts {
    private const val CHANNEL = "hermes/app_lock_attempts"
    private const val ALIAS = "daeroh.app_lock_attempts.v1"
    private const val PREFS = "app_lock_attempts_v1"
    private const val RECORD = "encrypted_record"
    private val allowedKeys = setOf("app_lock_attempt_window", "app_lock_cooldown_until")
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var record: CommittedAppLockRecord? = null

    fun attach(context: Context, messenger: BinaryMessenger) {
        val application = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            executor.execute {
                try {
                    val store = record ?: createRecord(application).also { record = it }
                    val reply: Any? = when (call.method) {
                        "isInitialized" -> store.read()?.let { decode(it); true } ?: false
                        "initialize" -> {
                            val values = requireNotNull(call.argument<Map<String, String>>("values"))
                            require(values.keys.all { it in allowedKeys })
                            store.initialize(JSONObject(values).toString())
                            true
                        }
                        "read", "write", "delete" -> {
                            val key = requireNotNull(call.argument<String>("key"))
                            require(key in allowedKeys)
                            val values = decode(requireNotNull(store.read()))
                            when (call.method) {
                                "read" -> if (values.has(key)) values.getString(key) else null
                                else -> {
                                    if (call.method == "write") {
                                        values.put(key, requireNotNull(call.argument<String>("value")))
                                    } else {
                                        values.remove(key)
                                    }
                                    store.write(values.toString())
                                    true
                                }
                            }
                        }
                        else -> throw IllegalArgumentException("Unknown app-lock operation")
                    }
                    // write/initialize/delete reach this only after commit() == true.
                    main.post { result.success(reply) }
                } catch (_: Exception) {
                    // Never expose key material or ciphertext in error messages/logs.
                    main.post { result.error("app_lock_storage", "App-lock storage unavailable", null) }
                }
            }
        }
    }

    private fun decode(value: String): JSONObject {
        val values = JSONObject(value)
        for (key in values.keys()) {
            require(key in allowedKeys && values.get(key) is String)
        }
        return values
    }

    private fun createRecord(context: Context): CommittedAppLockRecord {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        fun existingKey(): SecretKey =
            requireNotNull(keyStore.getKey(ALIAS, null) as? SecretKey)
        fun encryptionKey(): SecretKey {
            if (!keyStore.containsAlias(ALIAS)) {
                KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                    init(
                        KeyGenParameterSpec.Builder(
                            ALIAS,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setKeySize(256)
                            .build(),
                    )
                }.generateKey()
            }
            return existingKey()
        }
        return CommittedAppLockRecord(
            readEncrypted = { prefs.getString(RECORD, null) },
            decrypt = { encoded ->
                val parts = encoded.split(":")
                require(parts.size == 3 && parts[0] == "v1")
                val iv = Base64.decode(parts[1], Base64.NO_WRAP)
                require(iv.size == 12)
                Cipher.getInstance("AES/GCM/NoPadding").run {
                    init(Cipher.DECRYPT_MODE, existingKey(), GCMParameterSpec(128, iv))
                    updateAAD(ALIAS.toByteArray(Charsets.UTF_8))
                    String(doFinal(Base64.decode(parts[2], Base64.NO_WRAP)), Charsets.UTF_8)
                }
            },
            encrypt = { value ->
                Cipher.getInstance("AES/GCM/NoPadding").run {
                    init(Cipher.ENCRYPT_MODE, encryptionKey())
                    updateAAD(ALIAS.toByteArray(Charsets.UTF_8))
                    val encrypted = doFinal(value.toByteArray(Charsets.UTF_8))
                    "v1:${Base64.encodeToString(iv, Base64.NO_WRAP)}:" +
                        Base64.encodeToString(encrypted, Base64.NO_WRAP)
                }
            },
            commitEncrypted = { encrypted ->
                // apply() or a read-back is NOT a durability acknowledgement.
                prefs.edit().putString(RECORD, encrypted).commit()
            },
            checkAbsent = {
                // A missing/unreadable preferences file must not look like a new
                // install once this key exists. Also fail closed if the process
                // died between initial key generation and first disk commit.
                check(!keyStore.containsAlias(ALIAS)) { "Missing app-lock record" }
            },
        )
    }
}
