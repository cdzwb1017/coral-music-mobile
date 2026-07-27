# Called by QuickJS through JNI; keep its binary name and @JvmStatic bridge methods.
-keep class com.coral.music.mobile.QuickJsNativeBridge {
    public static <methods>;
}
