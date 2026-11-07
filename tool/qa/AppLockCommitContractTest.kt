package com.hermesagent.hermes_android

import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/** Host JVM tests of the production commit boundary; NOT Android Keystore tests. */
private class DiskModel {
    var disk: String? = null
    var memory: String? = null
    var hasKey = false
    var failCommit = false
    var throwCommit = false
    var lostReply = false
    var corruptCiphertext = false
    var commits = 0
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    fun restart(): CommittedAppLockRecord {
        memory = disk
        return CommittedAppLockRecord(
            readEncrypted = { memory },
            checkAbsent = { check(!hasKey) },
            encrypt = { plaintext ->
                hasKey = true
                Cipher.getInstance("AES/GCM/NoPadding").run {
                    init(Cipher.ENCRYPT_MODE, key)
                    val bytes = iv + doFinal(plaintext.toByteArray())
                    Base64.getEncoder().encodeToString(bytes)
                }
            },
            decrypt = { encoded ->
                check(!corruptCiphertext)
                val bytes = Base64.getDecoder().decode(encoded)
                Cipher.getInstance("AES/GCM/NoPadding").run {
                    init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                    String(doFinal(bytes.copyOfRange(12, bytes.size)))
                }
            },
            commitEncrypted = { encrypted ->
                commits++
                // Android commit() first changes the process cache, even when
                // its disk write later fails. This is deliberately not atomic.
                memory = encrypted
                if (throwCommit) throw IllegalStateException("disk error")
                if (failCommit) {
                    false
                } else {
                    disk = encrypted
                    if (lostReply) throw IllegalStateException("process lost after commit")
                    true
                }
            },
        )
    }
}

private fun fails(action: () -> Unit) {
    check(runCatching(action).isFailure) { "Expected fail-closed error" }
}

fun main() {
    var passed = 0
    fun test(name: String, body: () -> Unit) {
        body()
        passed++
        println("PASS $name")
    }

    test("encrypted migration survives restart and is idempotent") {
        val model = DiskModel()
        val store = model.restart()
        check(store.read() == null)
        store.initialize("four misses")
        check(model.disk != "four misses")
        val next = model.restart()
        next.initialize("stale legacy state")
        check(next.read() == "four misses")
        check(model.commits == 1)
    }
    for (throws in listOf(false, true)) {
        test("reservation commit ${if (throws) "throws" else "false"} poisons cached state") {
            val model = DiskModel()
            val store = model.restart()
            store.initialize("four misses")
            model.failCommit = !throws
            model.throwCommit = throws
            fails { store.write("fifth miss cooldown") }
            // Never use the uncommitted in-memory value, even after recovery.
            model.failCommit = false
            model.throwCommit = false
            fails { store.read() }
            fails { store.write("empty") }
            check(model.restart().read() == "four misses")
        }
    }
    test("process loss after disk commit retains reservation") {
        val model = DiskModel()
        val store = model.restart()
        store.initialize("four misses")
        model.lostReply = true
        fails { store.write("fifth miss cooldown") }
        check(model.restart().read() == "fifth miss cooldown")
    }
    test("cleanup failure cannot erase persisted cooldown") {
        val model = DiskModel()
        val store = model.restart()
        store.initialize("cooldown")
        model.failCommit = true
        fails { store.write("{}") }
        check(model.restart().read() == "cooldown")
    }
    test("successful empty record prevents legacy resurrection") {
        val model = DiskModel()
        val store = model.restart()
        store.initialize("cooldown")
        store.write("{}")
        val next = model.restart()
        next.initialize("old cooldown")
        check(next.read() == "{}")
    }
    test("ciphertext corruption never resets the record") {
        val model = DiskModel()
        val store = model.restart()
        store.initialize("four misses")
        val before = model.disk
        model.corruptCiphertext = true
        fails { store.read() }
        fails { store.initialize("empty") }
        check(model.disk == before)
    }
    test("tampered AES-GCM ciphertext fails authentication without reset") {
        val model = DiskModel()
        model.restart().initialize("four misses")
        val bytes = Base64.getDecoder().decode(model.disk)
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        model.disk = Base64.getEncoder().encodeToString(bytes)
        val store = model.restart()
        fails { store.read() } // Real host AES-GCM authentication failure.
        fails { store.initialize("empty") }
        check(model.commits == 1)
    }
    test("absent record with existing key fails closed") {
        val model = DiskModel()
        model.hasKey = true
        val store = model.restart()
        fails { store.read() }
        fails { store.initialize("empty") }
        check(model.disk == null)
    }
    test("interrupted first migration never falls back to fresh budget") {
        val model = DiskModel()
        val store = model.restart()
        model.failCommit = true
        fails { store.initialize("four legacy misses") }
        check(model.hasKey && model.disk == null)
        model.failCommit = false
        fails { model.restart().read() }
    }
    println("$passed native commit-boundary host tests passed")
}
