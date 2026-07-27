#include <jni.h>
#include <string>
#include "quickjs.h"

namespace {
JavaVM* vm = nullptr;
JSRuntime* runtime = nullptr;
JSContext* context = nullptr;
std::string manifest;
std::string result;

std::string chars(JNIEnv* env, jstring value) {
  if (!value) return {};
  const char* raw = env->GetStringUTFChars(value, nullptr);
  std::string text(raw ? raw : "");
  if (raw) env->ReleaseStringUTFChars(value, raw);
  return text;
}

jstring callJava(JNIEnv* env, const char* method, const std::string& first,
                 const std::string& second = {}) {
  jclass bridge = env->FindClass("com/coral/music/mobile/QuickJsNativeBridge");
  if (!bridge || env->ExceptionCheck()) {
    env->ExceptionClear();
    return nullptr;
  }
  jmethodID execute = env->GetStaticMethodID(
      bridge, method, "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
  if (!execute || env->ExceptionCheck()) {
    env->ExceptionClear();
    env->DeleteLocalRef(bridge);
    return nullptr;
  }
  jstring firstValue = env->NewStringUTF(first.c_str());
  jstring secondValue = env->NewStringUTF(second.c_str());
  auto output = static_cast<jstring>(
      env->CallStaticObjectMethod(bridge, execute, firstValue, secondValue));
  env->DeleteLocalRef(firstValue);
  env->DeleteLocalRef(secondValue);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    env->DeleteLocalRef(bridge);
    return nullptr;
  }
  env->DeleteLocalRef(bridge);
  return output;
}

JSValue nativeHttp(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  if (argc != 2) return JS_ThrowTypeError(ctx, "request 参数无效");
  const char* url = JS_ToCString(ctx, argv[0]);
  JSValue rawOptions = JS_JSONStringify(ctx, argv[1], JS_UNDEFINED, JS_UNDEFINED);
  const char* options = JS_ToCString(ctx, rawOptions);
  JNIEnv* env = nullptr;
  vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  jstring response = callJava(env, "request", url ? url : "", options ? options : "{}");
  if (url) JS_FreeCString(ctx, url);
  if (options) JS_FreeCString(ctx, options);
  JS_FreeValue(ctx, rawOptions);
  if (!response) return JS_ThrowInternalError(ctx, "原生 HTTP 请求失败");
  std::string value = chars(env, response);
  env->DeleteLocalRef(response);
  return JS_NewStringLen(ctx, value.data(), value.size());
}

JSValue nativeReady(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  if (argc == 1) {
    const char* value = JS_ToCString(ctx, argv[0]);
    manifest = value ? value : "";
    if (value) JS_FreeCString(ctx, value);
  }
  return JS_UNDEFINED;
}

JSValue nativeMd5(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  if (argc != 1) return JS_ThrowTypeError(ctx, "md5 参数无效");
  const char* value = JS_ToCString(ctx, argv[0]);
  JNIEnv* env = nullptr;
  vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  jstring output = callJava(env, "md5", value ? value : "");
  if (value) JS_FreeCString(ctx, value);
  if (!output) return JS_ThrowInternalError(ctx, "MD5 计算失败");
  std::string text = chars(env, output);
  env->DeleteLocalRef(output);
  return JS_NewStringLen(ctx, text.data(), text.size());
}

JSValue nativeResult(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  if (argc == 1) {
    const char* value = JS_ToCString(ctx, argv[0]);
    result = value ? value : "";
    if (value) JS_FreeCString(ctx, value);
  }
  return JS_UNDEFINED;
}

std::string exception(JSContext* ctx) {
  JSValue error = JS_GetException(ctx);
  const char* value = JS_ToCString(ctx, error);
  std::string message = value ? value : "音源脚本执行失败";
  if (value) JS_FreeCString(ctx, value);
  JS_FreeValue(ctx, error);
  return message;
}

bool evaluate(const std::string& source, std::string* error) {
  JSValue value = JS_Eval(context, source.data(), source.size(), "coral-user-api.js", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) {
    *error = exception(context);
    JS_FreeValue(context, value);
    return false;
  }
  JS_FreeValue(context, value);
  JSContext* pending = nullptr;
  while (JS_ExecutePendingJob(runtime, &pending) > 0) {}
  return true;
}

void reset() {
  if (context) JS_FreeContext(context);
  if (runtime) JS_FreeRuntime(runtime);
  runtime = JS_NewRuntime();
  context = JS_NewContext(runtime);
  manifest.clear(); result.clear();
}

const char* kBridge = R"JS(
  globalThis.window = globalThis;
  globalThis.__coralRequestHandler = null;
  globalThis.lx = globalThis.coral = {
    EVENT_NAMES: { request: 'request', inited: 'inited' },
    on(event, callback) { if (event !== 'request') return Promise.reject(new Error('Unsupported event')); __coralRequestHandler = callback; return Promise.resolve(); },
    send(event, data) { if (event === 'inited') __coralReady(JSON.stringify(data)); else if (event !== 'updateAlert') return Promise.reject(new Error('Unsupported event')); return Promise.resolve(); },
    request(url, options = {}, callback) {
      const data = JSON.parse(__coralHttp(String(url), options));
      let body = data.body;
      try { body = JSON.parse(body); } catch (_) {}
      if (data.response) data.response.body = body;
      callback(data.error ? new Error(data.error) : null, data.response || null, body);
      return () => {};
    },
    utils: { crypto: { md5(value) { return __coralMd5(String(value)); } }, buffer: { from(value) { return value instanceof Uint8Array ? value : Uint8Array.from(value); }, bufToString(value) { return new TextDecoder().decode(value); } } },
    env: 'mobile', version: '2.0.0'
  };
)JS";
}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* value, void*) {
  vm = value;
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_coral_music_mobile_QuickJsRuntime_nativeLoad(JNIEnv* env, jobject, jstring script) {
  reset();
  JSValue global = JS_GetGlobalObject(context);
  JS_SetPropertyStr(context, global, "__coralHttp", JS_NewCFunction(context, nativeHttp, "__coralHttp", 2));
  JS_SetPropertyStr(context, global, "__coralReady", JS_NewCFunction(context, nativeReady, "__coralReady", 1));
  JS_SetPropertyStr(context, global, "__coralMd5", JS_NewCFunction(context, nativeMd5, "__coralMd5", 1));
  JS_FreeValue(context, global);
  std::string error;
  if (!evaluate(kBridge, &error) || !evaluate(chars(env, script), &error) || manifest.empty()) {
    return env->NewStringUTF(("{\"error\":" + std::string("\"") + error + "\"}").c_str());
  }
  return env->NewStringUTF(manifest.c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_coral_music_mobile_QuickJsRuntime_nativeResolve(JNIEnv* env, jobject, jstring payload) {
  if (!context) return env->NewStringUTF("{\"error\":\"音源脚本尚未加载\"}");
  JSValue global = JS_GetGlobalObject(context);
  JS_SetPropertyStr(context, global, "__coralResult", JS_NewCFunction(context, nativeResult, "__coralResult", 1));
  JS_FreeValue(context, global);
  result.clear();
  std::string source = "Promise.resolve(__coralRequestHandler(" + chars(env, payload) + ")).then(value => __coralResult(JSON.stringify({ok:true,value}))).catch(error => __coralResult(JSON.stringify({ok:false,error:String(error && error.message || error)})));";
  std::string error;
  if (!evaluate(source, &error)) return env->NewStringUTF(("{\"error\":\"" + error + "\"}").c_str());
  return env->NewStringUTF((result.empty() ? "{\"error\":\"音源未返回结果\"}" : result).c_str());
}
