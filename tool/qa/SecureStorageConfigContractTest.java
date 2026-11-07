import android.content.SharedPreferences;
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage;
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig;
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback;
import java.lang.reflect.Field;
import java.lang.reflect.Proxy;
import java.util.HashMap;
import java.util.Map;
import sun.misc.Unsafe;

/** Pinned production plugin bytecode, HOST ONLY: no Android/Keystore proof.
 * Seed the post-first-initialize preferences/config state (Android Context is
 * unavailable on this JVM), then execute real initialize/read/readAll recovery.
 * The Flutter test separately exercises the real default startup factory and
 * asserts every app-owned constructor shares the same first configuration.
 */
public final class SecureStorageConfigContractTest {
    private static int passed;

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void probe(boolean firstReset, String key, boolean readAll) throws Exception {
        Field unsafeField = Unsafe.class.getDeclaredField("theUnsafe");
        unsafeField.setAccessible(true);
        Unsafe unsafe = (Unsafe) unsafeField.get(null);
        FlutterSecureStorage storage = (FlutterSecureStorage)
                unsafe.allocateInstance(FlutterSecureStorage.class);
        Map<String, Object> firstOptions = new HashMap<>();
        firstOptions.put("resetOnError", String.valueOf(firstReset));
        FlutterSecureStorageConfig first = new FlutterSecureStorageConfig(firstOptions);
        String prefixedKey = first.getSharedPreferencesKeyPrefix() + "_" + key;
        Map<String, String> data = new HashMap<>();
        data.put(prefixedKey, "!invalid-base64-ciphertext!");
        // A different consumer's encrypted value must not be destroyed by read().
        data.put("unrelated_other_namespace", "untouched");
        Map<String, String> before = new HashMap<>(data);
        SharedPreferences.Editor editor = (SharedPreferences.Editor) Proxy.newProxyInstance(
                SecureStorageConfigContractTest.class.getClassLoader(),
                new Class<?>[]{SharedPreferences.Editor.class}, (p, m, a) -> {
                    switch (m.getName()) {
                        case "remove": data.remove(a[0]); return p;
                        case "clear": data.clear(); return p;
                        case "apply": return null;
                        default: throw new AssertionError(m.getName());
                    }
                });
        SharedPreferences prefs = (SharedPreferences) Proxy.newProxyInstance(
                SecureStorageConfigContractTest.class.getClassLoader(),
                new Class<?>[]{SharedPreferences.class}, (p, m, a) -> {
                    switch (m.getName()) {
                        case "getString": return data.get(a[0]);
                        case "getAll": return new HashMap<>(data);
                        case "edit": return editor;
                        default: throw new AssertionError(m.getName());
                    }
                });
        Field config = FlutterSecureStorage.class.getDeclaredField("config");
        config.setAccessible(true);
        config.set(storage, first);
        Field preferences = FlutterSecureStorage.class.getDeclaredField("preferences");
        preferences.setAccessible(true);
        preferences.set(storage, prefs);
        // Exercise the actual default startup read before app-lock's later init.
        check(storage.read("missing_startup_key") == null, "startup read");
        Map<String, Object> laterOptions = new HashMap<>();
        laterOptions.put("resetOnError", "false");
        storage.initialize(new FlutterSecureStorageConfig(laterOptions),
                new SecurePreferencesCallback<Void>() {
                    public void onSuccess(Void unused) { }
                    public void onError(Exception error) { throw new AssertionError(error); }
                });
        check(config.get(storage) == first, "pinned first configuration cache changed");
        try {
            Object value = readAll ? storage.readAll() : storage.read(prefixedKey);
            check(firstReset, "false-first MUST propagate ciphertext error");
            check(readAll ? ((Map<?, ?>) value).isEmpty() : value == null,
                    "unsafe reset control did not erase unreadable state");
            check(!data.containsKey(prefixedKey), "unsafe control must reproduce deletion");
            if (!readAll) check(data.containsKey("unrelated_other_namespace"), "single-key control");
        } catch (IllegalArgumentException expected) {
            check(!firstReset, "true-first reproduction unexpectedly propagated");
            check(data.equals(before), "false-first changed encrypted values");
        }
        passed++;
        System.out.println("PASS " + (firstReset ? "unsafe-default control" : "shared-policy")
                + " " + (readAll ? "readAll" : "read") + " " + key);
    }

    public static void main(String[] args) throws Exception {
        for (boolean reset : new boolean[]{true, false}) {
            for (String key : new String[]{"app_lock_attempt_window", "app_lock_cooldown_until", "api_key_fixture"}) {
                probe(reset, key, false);
            }
            probe(reset, "app_lock_attempt_window", true);
        }
        System.out.println(passed + " pinned plugin bytecode HOST probes passed");
    }
}
