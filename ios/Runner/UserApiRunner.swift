import Flutter
import AVFoundation
import AudioToolbox
import Foundation
import JavaScriptCore
import MediaPlayer
import Security
import UIKit

/// Session-only LX User API runtime. JavaScriptCore stays alive with the audio
/// session in background and exposes no file, storage or direct network APIs.
final class UserApiRunner: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
  private static let scriptLimit = 256 * 1024
  private static let responseLimit = 1024 * 1024
  private static let requestLimit = 64 * 1024

  private var context: JSContext?
  private var script = ""
  private var loaded = false
  private var sources = Set<String>()
  private var lyricSources = Set<String>()
  private var pendingLoad: FlutterResult?
  private var pendingResults = [String: FlutterResult]()
  private var pendingLyricResults = [String: FlutterResult]()
  private var loadTimeout: DispatchWorkItem?
  private var requestTimeouts = [String: DispatchWorkItem]()
  private var backgroundTasks = [String: UIBackgroundTaskIdentifier]()
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }()
  private var httpRequests = [Int: HttpRequest]()

  private struct HttpRequest {
    let id: String
    var response: HTTPURLResponse?
    var data = Data()
  }

  func load(_ rawScript: String, result: @escaping FlutterResult) {
    guard !rawScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          rawScript.utf8.count <= Self.scriptLimit else {
      result(FlutterError(code: "invalid_script", message: "音源脚本为空或超过大小限制", details: nil))
      return
    }
    pendingLoad?(FlutterError(code: "cancelled", message: "新的音源脚本替换了当前加载", details: nil))
    cancelPendingRequests(message: "新的音源脚本替换了当前运行时")
    loadTimeout?.cancel()
    script = rawScript
    loaded = false
    sources.removeAll()
    lyricSources.removeAll()
    pendingLoad = result
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, !self.loaded else { return }
      self.pendingLoad?(FlutterError(code: "timeout", message: "音源脚本初始化超时", details: nil))
      self.pendingLoad = nil
    }
    loadTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    resetContext()
  }

  func clear(result: @escaping FlutterResult) {
    pendingLoad?(FlutterError(code: "cancelled", message: "音源脚本已移除", details: nil))
    pendingLoad = nil
    loadTimeout?.cancel()
    cancelPendingRequests(message: "音源脚本已移除")
    script = ""
    loaded = false
    sources.removeAll()
    lyricSources.removeAll()
    resetContext()
    result(nil)
  }

  func resolveMusicUrl(arguments: [String: Any]?, result: @escaping FlutterResult) {
    let values = arguments ?? [:]
    let source = values["source"] as? String ?? ""
    guard loaded, sources.contains(source) else {
      result(FlutterError(code: "not_ready", message: "当前音源未支持该歌曲来源", details: nil))
      return
    }
    let payload: [String: Any] = [
      "source": source,
      "action": "musicUrl",
      "info": [
        "type": values["quality"] as? String ?? "128k",
        "musicInfo": values["musicInfo"] as? [String: Any] ?? [:],
      ],
    ]
    resolve(payload: payload, lyric: false, result: result)
  }

  func resolveLyric(arguments: [String: Any]?, result: @escaping FlutterResult) {
    let values = arguments ?? [:]
    let source = values["source"] as? String ?? ""
    guard loaded, sources.contains(source) else {
      result(FlutterError(code: "not_ready", message: "当前音源未支持该歌曲来源的歌词", details: nil))
      return
    }
    let payload: [String: Any] = [
      "source": source,
      "action": "lyric",
      "info": [
        "isGetLyricx": true,
        "musicInfo": values["musicInfo"] as? [String: Any] ?? [:],
      ],
    ]
    resolve(payload: payload, lyric: true, result: result)
  }

  func dispose() {
    clear { _ in }
    session.invalidateAndCancel()
    context = nil
  }

  private func resolve(payload: [String: Any], lyric: Bool, result: @escaping FlutterResult) {
    guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: encoded, encoding: .utf8) else {
      result(FlutterError(code: "invalid_result", message: lyric ? "音源未返回有效歌词" : "音源未返回有效的 HTTP 播放地址", details: nil))
      return
    }
    let id = UUID().uuidString
    if lyric { pendingLyricResults[id] = result } else { pendingResults[id] = result }
    backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(
      withName: "CoralMusicResolve"
    ) { [weak self] in
      self?.expireRequest(id)
    }
    let callback = lyric ? "lyricResult" : "result"
    evaluate("""
      Promise.resolve(window.__coralRequestHandler(\(json)))
        .then((value) => window.__coralNative({method: '\(callback)', id: \(jsonString(id)), ok: true, value}))
        .catch((error) => window.__coralNative({method: '\(callback)', id: \(jsonString(id)), ok: false, error: String(error && error.message || error)}));
    """)
    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let failure = FlutterError(code: "timeout", message: lyric ? "音源歌词获取超时" : "音源取链超时", details: nil)
      self.endBackgroundTask(id)
      if lyric { self.pendingLyricResults.removeValue(forKey: id)?(failure) }
      else { self.pendingResults.removeValue(forKey: id)?(failure) }
    }
    requestTimeouts[id] = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
  }

  private func resetContext() {
    let context = JSContext()!
    context.exceptionHandler = { [weak self] _, exception in
      guard let self, self.pendingLoad != nil else { return }
      self.pendingLoad?(FlutterError(code: "script_error", message: exception?.toString() ?? "音源脚本执行失败", details: nil))
      self.pendingLoad = nil
      self.loadTimeout?.cancel()
    }
    let native: @convention(block) (JSValue) -> Void = { [weak self] value in
      self?.handleNative(value.toDictionary() as? [String: Any] ?? [:])
    }
    let randomByte: @convention(block) () -> Int = {
      var byte: UInt8 = 0
      return SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess
          ? Int(byte) : Int.random(in: 0...255)
    }
    context.setObject(native, forKeyedSubscript: "__coralNative" as NSString)
    context.setObject(randomByte, forKeyedSubscript: "__coralRandomByte" as NSString)
    self.context = context
    guard !script.isEmpty else { return }
    let source = jsonString(script)
    evaluate("""
      (() => {
        window = this;
        window.__coralScriptInfo = { rawScript: \(source) };
        window.fetch = () => Promise.reject(new Error('当前受限运行时禁止直接网络请求'));
        window.XMLHttpRequest = class { constructor() { throw new Error('当前受限运行时禁止直接网络请求'); } };
        \(Self.bridgeScript)
        try { (0, eval)(window.__coralScriptInfo.rawScript); }
        catch (error) { window.__coralNative({method: 'scriptError', message: String(error && error.message || error || '音源脚本执行失败')}); }
      })();
    """)
  }

  private func evaluate(_ javascript: String) {
    context?.evaluateScript(javascript)
  }

  private func cancelPendingRequests(message: String) {
    let failure = FlutterError(code: "cancelled", message: message, details: nil)
    pendingResults.values.forEach { $0(failure) }
    pendingLyricResults.values.forEach { $0(failure) }
    pendingResults.removeAll()
    pendingLyricResults.removeAll()
    requestTimeouts.values.forEach { $0.cancel() }
    requestTimeouts.removeAll()
    Array(backgroundTasks.keys).forEach(endBackgroundTask)
    httpRequests.keys.forEach { taskId in
      session.getAllTasks { tasks in tasks.first(where: { $0.taskIdentifier == taskId })?.cancel() }
    }
    httpRequests.removeAll()
  }

  private func jsonString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    return String(data: data, encoding: .utf8)!.dropFirst().dropLast().description
  }

  private func handleNative(_ body: [String: Any]) {
    guard let method = body["method"] as? String else { return }
    switch method {
    case "ready": handleReady(body["manifest"] as? String ?? "")
    case "scriptError":
      guard !loaded, let result = pendingLoad else { return }
      result(FlutterError(code: "script_error", message: (body["message"] as? String ?? "音源脚本执行失败").prefix(1024).description, details: nil))
      pendingLoad = nil
      loadTimeout?.cancel()
    case "request": startRequest(body)
    case "result": handleResult(body, lyric: false)
    case "lyricResult": handleResult(body, lyric: true)
    default: break
    }
  }

  private func handleReady(_ rawManifest: String) {
    do {
      guard let data = rawManifest.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let declared = root["sources"] as? [String: Any] else { throw RuntimeError("音源脚本未声明来源") }
      let music = declared.compactMap { key, value -> String? in
        guard let item = value as? [String: Any], item["type"] as? String == "music",
              (item["actions"] as? [String])?.contains("musicUrl") == true else { return nil }
        return key
      }
      guard !music.isEmpty else { throw RuntimeError("音源脚本未声明可用的 musicUrl 来源") }
      sources = Set(music)
      lyricSources = Set(declared.compactMap { key, value in
        guard let item = value as? [String: Any], item["type"] as? String == "music",
              (item["actions"] as? [String])?.contains("lyric") == true else { return nil }
        return key
      })
      loaded = true
      pendingLoad?(["musicUrlSources": music.sorted(), "lyricSources": lyricSources.sorted()])
      pendingLoad = nil
      loadTimeout?.cancel()
    } catch {
      pendingLoad?(FlutterError(code: "invalid_manifest", message: error.localizedDescription, details: nil))
      pendingLoad = nil
      loadTimeout?.cancel()
    }
  }

  private func handleResult(_ body: [String: Any], lyric: Bool) {
    guard let id = body["id"] as? String else { return }
    requestTimeouts.removeValue(forKey: id)?.cancel()
    endBackgroundTask(id)
    let result = lyric ? pendingLyricResults.removeValue(forKey: id) : pendingResults.removeValue(forKey: id)
    guard let result else { return }
    guard body["ok"] as? Bool == true else {
      result(FlutterError(code: "source_error", message: (body["error"] as? String ?? (lyric ? "音源歌词获取失败" : "音源取链失败")).prefix(1024).description, details: nil))
      return
    }
    if lyric {
      let value = body["value"]
      let payload: Any = value is String ? ["lyric": value!] : value ?? [:]
      guard JSONSerialization.isValidJSONObject(payload), let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= Self.scriptLimit else {
        result(FlutterError(code: "invalid_result", message: "音源未返回有效歌词", details: nil)); return
      }
      result(String(data: data, encoding: .utf8))
      return
    }
    let raw = body["value"]
    let detail = (raw as? [String: Any])?["data"] as? [String: Any] ?? raw as? [String: Any] ?? (raw as? String).map { ["url": $0] }
    guard let detail, let url = detail["url"] as? String, url.count <= 8192,
          let uri = URL(string: url), ["http", "https"].contains(uri.scheme?.lowercased() ?? ""), uri.host != nil else {
      result(FlutterError(code: "invalid_result", message: "音源未返回有效的 HTTP 播放地址", details: nil)); return
    }
    result(["url": url, "type": detail["type"] as? String ?? ""])
  }

  private func expireRequest(_ id: String) {
    guard backgroundTasks[id] != nil else { return }
    endBackgroundTask(id)
    requestTimeouts.removeValue(forKey: id)?.cancel()
    let failure = FlutterError(code: "timeout", message: "音源取链超时", details: nil)
    pendingResults.removeValue(forKey: id)?(failure)
    pendingLyricResults.removeValue(forKey: id)?(failure)
  }

  private func endBackgroundTask(_ id: String) {
    guard let task = backgroundTasks.removeValue(forKey: id),
          task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
  }

  // MARK: restricted native HTTP

  private func startRequest(_ body: [String: Any]) {
    guard let id = body["id"] as? String, let rawUrl = body["url"] as? String,
          let url = URL(string: rawUrl), url.scheme?.lowercased() == "https", url.host != nil else {
      sendRequestResult(id: body["id"] as? String ?? "", error: "仅允许 HTTPS 请求"); return
    }
    let options = body["options"] as? [String: Any] ?? [:]
    let method = (options["method"] as? String ?? "get").uppercased()
    guard method == "GET" || method == "POST" else { sendRequestResult(id: id, error: "只允许 GET 或 POST 请求"); return }
    guard options["formData"] == nil else { sendRequestResult(id: id, error: "当前受限运行时不支持 multipart 表单"); return }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = min(max(options["timeout"] as? TimeInterval ?? 15, 1), 20)
    request.httpShouldHandleCookies = false
    if let headers = options["headers"] as? [String: String] {
      headers.forEach { name, value in
        if !["host", "connection", "content-length"].contains(name.lowercased()) { request.setValue(value, forHTTPHeaderField: name) }
      }
    }
    let form = options["form"] as? [String: Any]
    let explicitBody = requestBody(options["body"])
    let data = explicitBody?.isEmpty == false
      ? explicitBody
      : form.flatMap { formBody($0) }
    if let data, !data.isEmpty {
      guard method == "POST", data.count <= Self.requestLimit else { sendRequestResult(id: id, error: "请求体超过大小限制"); return }
      if form != nil && request.value(forHTTPHeaderField: "Content-Type") == nil {
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
      }
      request.httpBody = data
    }
    let task = session.dataTask(with: request)
    httpRequests[task.taskIdentifier] = HttpRequest(id: id)
    task.resume()
  }

  private func requestBody(_ raw: Any?) -> Data? {
    if let text = raw as? String { return Data(text.utf8) }
    guard let raw, JSONSerialization.isValidJSONObject(raw) else { return nil }
    return try? JSONSerialization.data(withJSONObject: raw)
  }

  private func formBody(_ form: [String: Any]) -> Data? {
    var components = URLComponents()
    components.queryItems = form.keys.sorted().map { key in
      URLQueryItem(name: key, value: String(describing: form[key] ?? ""))
    }
    return components.percentEncodedQuery.map { Data($0.utf8) }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard var item = httpRequests[dataTask.taskIdentifier], let http = response as? HTTPURLResponse,
          response.expectedContentLength <= Int64(Self.responseLimit) || response.expectedContentLength < 0 else {
      httpRequests.removeValue(forKey: dataTask.taskIdentifier).map { sendRequestResult(id: $0.id, error: "响应超过大小限制") }
      completionHandler(.cancel); return
    }
    item.response = http
    httpRequests[dataTask.taskIdentifier] = item
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard var item = httpRequests[dataTask.taskIdentifier] else { return }
    guard item.data.count + data.count <= Self.responseLimit else {
      httpRequests.removeValue(forKey: dataTask.taskIdentifier).map { sendRequestResult(id: $0.id, error: "响应超过大小限制") }
      dataTask.cancel(); return
    }
    item.data.append(data)
    httpRequests[dataTask.taskIdentifier] = item
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let item = httpRequests.removeValue(forKey: task.taskIdentifier) else { return }
    guard error == nil, let response = item.response else { sendRequestResult(id: item.id, error: error?.localizedDescription ?? "请求失败"); return }
    sendRequestResult(id: item.id, response: [
      "statusCode": response.statusCode,
      "statusMessage": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
      "bytes": item.data.count,
      "body": String(data: item.data, encoding: .utf8) ?? "",
    ])
  }

  private func sendRequestResult(id: String, response: [String: Any]? = nil, error: String? = nil) {
    guard !id.isEmpty else { return }
    var payload: [String: Any] = ["error": error as Any]
    if let response { payload["response"] = response; payload["body"] = response["body"] }
    guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
    evaluate("window.__coralRequestDone(\(jsonString(id)), \(jsonString(json)));" )
  }

  private struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  private static let bridgeScript = """
    (() => {
      const callbacks = {};
      if (!window.TextEncoder) window.TextEncoder = class {
        encode(value) {
          const encoded = unescape(encodeURIComponent(String(value)));
          return Uint8Array.from(encoded, (char) => char.charCodeAt(0));
        }
      };
      if (!window.crypto) window.crypto = {};
      if (!window.crypto.getRandomValues) window.crypto.getRandomValues = (bytes) => {
        for (let index = 0; index < bytes.length; index++) bytes[index] = window.__coralRandomByte();
        return bytes;
      };
      // WebKit messaging is asynchronous, while LX expects md5() to return a
      // string immediately. Keep the small deterministic implementation here
      // instead of opening a synchronous native escape hatch.
      const md5 = (input) => {
        const source = new TextEncoder().encode(String(input));
        const bits = source.length * 8;
        const size = (((source.length + 8) >>> 6) + 1) * 64;
        const bytes = new Uint8Array(size);
        bytes.set(source); bytes[source.length] = 0x80;
        const view = new DataView(bytes.buffer);
        view.setUint32(size - 8, bits >>> 0, true);
        view.setUint32(size - 4, Math.floor(bits / 0x100000000), true);
        const shift = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
          5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
          4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
          6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
        const constants = Array.from({length: 64}, (_, index) =>
          Math.floor(Math.abs(Math.sin(index + 1)) * 0x100000000) >>> 0);
        let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
        const rotate = (value, count) => (value << count) | (value >>> (32 - count));
        for (let offset = 0; offset < size; offset += 64) {
          let a = a0, b = b0, c = c0, d = d0;
          for (let index = 0; index < 64; index++) {
            let f, g;
            if (index < 16) { f = (b & c) | (~b & d); g = index; }
            else if (index < 32) { f = (d & b) | (~d & c); g = (5 * index + 1) % 16; }
            else if (index < 48) { f = b ^ c ^ d; g = (3 * index + 5) % 16; }
            else { f = c ^ (b | ~d); g = (7 * index) % 16; }
            const sum = (a + f + constants[index] + view.getUint32(offset + g * 4, true)) >>> 0;
            a = d; d = c; c = b; b = (b + rotate(sum, shift[index])) >>> 0;
          }
          a0 = (a0 + a) >>> 0; b0 = (b0 + b) >>> 0;
          c0 = (c0 + c) >>> 0; d0 = (d0 + d) >>> 0;
        }
        return [a0, b0, c0, d0].map((word) => [0, 8, 16, 24]
          .map((shift) => ((word >>> shift) & 0xff).toString(16).padStart(2, '0')).join('')).join('');
      };
      window.__coralRequestDone = (id, raw) => {
        const callback = callbacks[id]; delete callbacks[id]; if (!callback) return;
        const result = JSON.parse(raw); let body = result.body;
        try { body = JSON.parse(body); } catch (_) {}
        const response = result.response || null; if (response) response.body = body;
        callback(result.error ? new Error(result.error) : null, response, body);
      };
      let sequence = 0;
      const bridge = {
        EVENT_NAMES: { request: 'request', inited: 'inited' },
        on(event, callback) { if (event !== 'request') return Promise.reject(new Error('Unsupported event')); window.__coralRequestHandler = callback; return Promise.resolve(); },
        send(event, data) { if (event === 'inited') window.__coralNative({method: 'ready', manifest: JSON.stringify(data)}); else if (event !== 'updateAlert') return Promise.reject(new Error('Unsupported event')); return Promise.resolve(); },
        request(url, options = {}, callback) { const id = String(++sequence); callbacks[id] = callback; window.__coralNative({method: 'request', id, url: String(url), options}); return () => delete callbacks[id]; },
        utils: {
          crypto: {
            md5(value) { return md5(value); },
            randomBytes(size) { const bytes = new Uint8Array(Number(size)); if (bytes.length < 1 || bytes.length > 4096) throw new Error('随机字节长度超出限制'); crypto.getRandomValues(bytes); return bytes; },
            aesEncrypt() { return Promise.reject(new Error('当前受限运行时不支持 AES 加密')); },
            rsaEncrypt() { return Promise.reject(new Error('当前受限运行时不支持 RSA 加密')); },
          },
          buffer: { from(value) { if (value instanceof Uint8Array) return value; if (Array.isArray(value)) return Uint8Array.from(value); throw new Error('当前受限运行时仅支持字节数组'); }, bufToString(value) { return new TextDecoder().decode(value); } },
          zlib: { inflate() { return Promise.reject(new Error('当前受限运行时不支持 zlib 解压')); }, deflate() { return Promise.reject(new Error('当前受限运行时不支持 zlib 压缩')); } },
        },
        currentScriptInfo: window.__coralScriptInfo, env: 'mobile', version: '2.0.0',
      };
      window.lx = bridge; window.coral = bridge;
    })();
  """
}

/// Reads the encoded stream's own bitrate property without using file size or duration.
private final class EncodedBitrateProbe: NSObject, URLSessionDataDelegate {
  struct Result {
    let bitrate: Int?
    let totalBytes: Int64?
  }

  private static let byteLimit = 128 * 1024

  private let url: URL
  private let completion: (Result) -> Void
  private var parser: AudioFileStreamID?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var byteCount = 0
  private var completed = false
  private var totalBytes: Int64?

  init(url: URL, completion: @escaping (Result) -> Void) {
    self.url = url
    self.completion = completion
  }

  deinit { if let parser { AudioFileStreamClose(parser) } }

  func start() {
    guard AudioFileStreamOpen(
      Unmanaged.passUnretained(self).toOpaque(), coralBitratePropertyChanged,
      coralBitratePackets, 0, &parser
    ) == noErr else { finish(nil); return }
    var request = URLRequest(url: url)
    request.setValue("bytes=0-\(Self.byteLimit - 1)", forHTTPHeaderField: "Range")
    request.timeoutInterval = 10
    request.httpShouldHandleCookies = false
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    task = session?.dataTask(with: request)
    task?.resume()
  }

  func cancel() { finish(nil) }

  func propertyChanged(_ stream: AudioFileStreamID, property: AudioFileStreamPropertyID) {
    guard property == kAudioFileStreamProperty_BitRate else { return }
    finish(bitrate(from: stream))
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse {
      let contentRange = http.value(forHTTPHeaderField: "Content-Range")
      totalBytes = contentRange?.split(separator: "/").last.flatMap { Int64($0) }
        ?? http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !completed, let parser else { return }
    byteCount += data.count
    data.withUnsafeBytes { bytes in
      guard let address = bytes.baseAddress else { return }
      AudioFileStreamParseBytes(parser, UInt32(data.count), address, [])
    }
    if byteCount >= Self.byteLimit { finish(bitrate(from: parser)) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if !completed { finish(parser.flatMap(bitrate(from:))) }
  }

  private func bitrate(from stream: AudioFileStreamID) -> Int? {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_BitRate, &size, &value) == noErr,
          value >= 8_000 else { return nil }
    return Int(value)
  }

  private func finish(_ bitrate: Int?) {
    guard !completed else { return }
    completed = true
    task?.cancel()
    session?.invalidateAndCancel()
    completion(Result(bitrate: bitrate, totalBytes: totalBytes))
  }
}

private func coralBitratePropertyChanged(
  _ clientData: UnsafeMutableRawPointer, _ stream: AudioFileStreamID,
  _ property: AudioFileStreamPropertyID, _ flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
  Unmanaged<EncodedBitrateProbe>.fromOpaque(clientData).takeUnretainedValue()
    .propertyChanged(stream, property: property)
}

private func coralBitratePackets(
  _ clientData: UnsafeMutableRawPointer, _ byteCount: UInt32, _ packetCount: UInt32,
  _ inputData: UnsafeRawPointer, _ packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {}

/// Owns online playback after Flutter has supplied a logical queue. The player
/// only receives current/next items; URLs are resolved natively just-in-time.
final class NativePlaybackCoordinator: NSObject, FlutterStreamHandler {
  private static let queueWindow = 2
  private static let maxResolveAttempts = 3

  private let runner: UserApiRunner
  private let player = AVQueuePlayer()
  private var tracks = [[String: Any]]()
  private var sequence = [Int]()
  private var itemIndexes = [ObjectIdentifier: Int]()
  private var currentIndex = -1
  private var resolving = false
  private var autoPlay = false
  private var mode = "listLoop"
  private var attempts = [Int: Int]()
  private var artworks = [Int: MPMediaItemArtwork]()
  private var artworkLoads = Set<Int>()
  private var sourceBitrates = [Int: Int]()
  private var sourceSizes = [Int: Int64]()
  private var bitrateProbes = [Int: EncodedBitrateProbe]()
  private var bitrateProbeURLs = [Int: String]()
  private var sink: FlutterEventSink?
  private var endObserver: NSObjectProtocol?
  private var timeObserver: Any?

  init(runner: UserApiRunner) {
    self.runner = runner
    super.init()
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] notification in
      self?.didFinish(notification.object as? AVPlayerItem)
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
    ) { [weak self] _ in self?.emit() }
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.addTarget { [weak self] _ in self?.playFromRemote() ?? .commandFailed }
    commands.pauseCommand.addTarget { [weak self] _ in self?.pauseFromRemote() ?? .commandFailed }
    commands.nextTrackCommand.addTarget { [weak self] _ in self?.nextFromRemote() ?? .commandFailed }
    commands.previousTrackCommand.addTarget { [weak self] _ in self?.previousFromRemote() ?? .commandFailed }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let change = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      return self?.seekFromRemote(change.positionTime) ?? .commandFailed
    }
  }

  deinit {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    if let timeObserver { player.removeTimeObserver(timeObserver) }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    emit()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startQueue": start(call.arguments as? [String: Any] ?? [:], result: result)
    case "play":
      autoPlay = true; activateAudio(); player.play(); emit(status: "loading"); result(nil)
    case "pause":
      autoPlay = false; player.pause(); emit(status: "paused"); result(nil)
    case "stop":
      stop(); result(nil)
    case "next":
      advance(); result(nil)
    case "previous":
      previous(); result(nil)
    case "seek":
      let values = call.arguments as? [String: Any] ?? [:]
      player.seek(to: CMTime(milliseconds: values["positionMs"] as? Int ?? 0), toleranceBefore: .zero, toleranceAfter: .zero)
      emit(); result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func start(_ values: [String: Any], result: @escaping FlutterResult) {
    guard let rawTracks = values["tracks"] as? [[String: Any]], !rawTracks.isEmpty else {
      result(FlutterError(code: "invalid_queue", message: "播放队列为空", details: nil)); return
    }
    let index = values["index"] as? Int ?? 0
    guard rawTracks.indices.contains(index) else {
      result(FlutterError(code: "invalid_queue", message: "播放索引无效", details: nil)); return
    }
    tracks = rawTracks
    currentIndex = index
    sequence = [index]
    itemIndexes.removeAll()
    attempts.removeAll()
    artworks.removeAll()
    artworkLoads.removeAll()
    bitrateProbes.values.forEach { $0.cancel() }
    sourceBitrates.removeAll()
    sourceSizes.removeAll()
    bitrateProbes.removeAll()
    bitrateProbeURLs.removeAll()
    mode = values["mode"] as? String ?? "listLoop"
    autoPlay = values["autoPlay"] as? Bool ?? true
    resolving = false
    player.pause()
    player.removeAllItems()
    activateAudio()
    emit(status: "loading")
    refill()
    result(nil)
  }

  private func refill() {
    guard !resolving, !tracks.isEmpty else { return }
    guard player.items().count < Self.queueWindow else { return }
    let index = sequence.last ?? currentIndex
    if player.items().isEmpty {
      resolveAndInsert(index)
      return
    }
    let next = nextIndex(after: index)
    sequence.append(next)
    resolveAndInsert(next)
  }

  private func resolveAndInsert(_ index: Int) {
    guard tracks.indices.contains(index), !resolving else { return }
    resolving = true
    let track = tracks[index]
    let arguments: [String: Any] = [
      "source": track["source"] as? String ?? "",
      "quality": track["quality"] as? String ?? "flac",
      "musicInfo": track["musicInfo"] as? [String: Any] ?? [:],
    ]
    runner.resolveMusicUrl(arguments: arguments) { [weak self] value in
      DispatchQueue.main.async { self?.resolved(value, index: index) }
    }
  }

  private func resolved(_ value: Any?, index: Int) {
    resolving = false
    if let failure = value as? FlutterError {
      retry(index, message: failure.message ?? "音源取链失败")
      return
    }
    guard let values = value as? [String: Any], let rawUrl = values["url"] as? String,
          let url = URL(string: rawUrl), url.scheme == "https" || url.scheme == "http" else {
      retry(index, message: "音源未返回有效播放地址")
      return
    }
    let requested = tracks[index]["quality"] as? String ?? "flac"
    if let actual = values["type"] as? String, isLowerQuality(actual, than: requested) {
      player.pause()
      emit(status: "error", error: "该曲无此音质")
      return
    }
    let item = AVPlayerItem(url: url)
    probeBitrate(for: index, url: url)
    itemIndexes[ObjectIdentifier(item)] = index
    player.insert(item, after: nil)
    attempts[index] = 0
    if player.currentItem === item {
      currentIndex = index
      updateNowPlaying(index)
      if autoPlay { player.play(); emit(status: "loading") }
      else { emit(status: "ready") }
      refill()
    } else {
      refill()
    }
  }

  private func retry(_ index: Int, message: String) {
    let count = (attempts[index] ?? 0) + 1
    attempts[index] = count
    guard count < Self.maxResolveAttempts else {
      emit(status: "error", error: message)
      player.pause()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(count)) { [weak self] in
      self?.resolveAndInsert(index)
    }
  }

  private func didFinish(_ item: AVPlayerItem?) {
    guard let item, let index = itemIndexes.removeValue(forKey: ObjectIdentifier(item)) else { return }
    currentIndex = index
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let next = self.player.currentItem, let nextIndex = self.itemIndexes[ObjectIdentifier(next)] {
        self.currentIndex = nextIndex
        self.updateNowPlaying(nextIndex)
        self.emit(status: self.player.rate == 0 ? "ready" : "playing")
      }
      self.refill()
    }
  }

  private func advance() {
    guard player.items().count > 1 else { refill(); return }
    player.advanceToNextItem()
    if let item = player.currentItem, let index = itemIndexes[ObjectIdentifier(item)] {
      currentIndex = index
      updateNowPlaying(index)
    }
    if autoPlay { player.play() }
    refill()
    emit(status: autoPlay ? "loading" : "ready")
  }

  private func previous() {
    guard tracks.indices.contains(currentIndex) else { return }
    let index = (currentIndex - 1 + tracks.count) % tracks.count
    sequence = [index]
    itemIndexes.removeAll()
    player.pause(); player.removeAllItems()
    currentIndex = index
    refill()
    emit(status: "loading")
  }

  private func playFromRemote() -> MPRemoteCommandHandlerStatus {
    guard !tracks.isEmpty else { return .noSuchContent }
    autoPlay = true; activateAudio(); player.play(); emit(status: "loading")
    return .success
  }

  private func pauseFromRemote() -> MPRemoteCommandHandlerStatus {
    autoPlay = false; player.pause(); emit(status: "paused")
    return .success
  }

  private func nextFromRemote() -> MPRemoteCommandHandlerStatus {
    advance(); return .success
  }

  private func previousFromRemote() -> MPRemoteCommandHandlerStatus {
    previous(); return .success
  }

  private func seekFromRemote(_ seconds: TimeInterval) -> MPRemoteCommandHandlerStatus {
    player.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 1000)) { [weak self] _ in self?.emit() }
    return .success
  }

  private func nextIndex(after index: Int) -> Int {
    switch mode {
    case "singleLoop": return index
    case "shuffle":
      guard tracks.count > 1 else { return index }
      var candidate = Int.random(in: 0..<tracks.count)
      while candidate == index { candidate = Int.random(in: 0..<tracks.count) }
      return candidate
    default: return (index + 1) % tracks.count
    }
  }

  private func isLowerQuality(_ actual: String, than requested: String) -> Bool {
    let levels = ["master", "atmos_plus", "atmos", "hires", "flac24bit", "flac", "320k", "192k", "128k"]
    guard let actualIndex = levels.firstIndex(of: actual),
          let requestedIndex = levels.firstIndex(of: requested) else { return false }
    return actualIndex > requestedIndex
  }

  private func activateAudio() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
    } catch { emit(status: "error", error: "无法激活音频会话") }
  }

  private func updateNowPlaying(_ index: Int) {
    guard tracks.indices.contains(index) else { return }
    let track = tracks[index]
    let item = player.currentItem
    let duration = (track["durationMs"] as? Int).map { Double($0) / 1000 } ?? item?.duration.seconds ?? 0
    let elapsed = player.currentTime().seconds
    var values: [String: Any] = [
      MPMediaItemPropertyTitle: track["title"] as? String ?? "",
      MPMediaItemPropertyArtist: track["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: track["album"] as? String ?? "",
    ]
    if duration.isFinite, duration > 0 { values[MPMediaItemPropertyPlaybackDuration] = duration }
    if elapsed.isFinite, elapsed >= 0 { values[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
    values[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
    if let artwork = artworks[index] { values[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = values
    loadArtwork(for: index, track: track)
  }

  private func loadArtwork(for index: Int, track: [String: Any]) {
    guard artworks[index] == nil, !artworkLoads.contains(index),
          let raw = track["artwork"] as? String,
          let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" else { return }
    artworkLoads.insert(index)
    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.artworkLoads.remove(index)
        guard let data, data.count <= 4 * 1024 * 1024, let image = UIImage(data: data), self.currentIndex == index else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.artworks[index] = artwork
        self.updateNowPlaying(index)
      }
    }.resume()
  }

  private func probeBitrate(for index: Int, url: URL) {
    guard bitrateProbes[index] == nil else { return }
    let rawURL = url.absoluteString
    bitrateProbeURLs[index] = rawURL
    let probe = EncodedBitrateProbe(url: url) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.bitrateProbeURLs[index] == rawURL else { return }
        self.bitrateProbes.removeValue(forKey: index)
        if let bitrate = result.bitrate { self.sourceBitrates[index] = bitrate }
        if let size = result.totalBytes, size > 0 { self.sourceSizes[index] = size }
        self.emit()
      }
    }
    bitrateProbes[index] = probe
    probe.start()
  }

  private func audioDetails(_ item: AVPlayerItem?) -> (bitrate: Int?, sampleRate: Int?) {
    guard let track = item?.asset.tracks(withMediaType: .audio).first else { return (nil, nil) }
    // indicatedBitrate is declared by the media; observedBitrate is only network throughput.
    let indicated = item?.accessLog()?.events.last?.indicatedBitrate ?? 0
    let dataRate = indicated.isFinite && indicated >= 8_000
      ? indicated : Double(track.estimatedDataRate)
    let index = item.flatMap { itemIndexes[ObjectIdentifier($0)] }
    let bitrate = index.flatMap { sourceBitrates[$0] } ?? (dataRate.isFinite && dataRate >= 8_000
      ? Int(dataRate.rounded()) : nil
    ) ?? index.flatMap(declaredBitrate(for:))
    let sampleRate = track.formatDescriptions.first.map {
      CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)
    }.flatMap { $0 }.map { Int($0.pointee.mSampleRate.rounded()) }
    return (bitrate, sampleRate)
  }

  /// Same final fallback as Android: source-declared file size over source duration.
  private func declaredBitrate(for index: Int) -> Int? {
    guard tracks.indices.contains(index),
          let durationMs = tracks[index]["durationMs"] as? Int, durationMs > 0 else { return nil }
    let track = tracks[index]
    let quality = track["quality"] as? String ?? ""
    let info = track["musicInfo"] as? [String: Any] ?? [:]
    let metadata = info["meta"] as? [String: Any] ?? [:]
    let groups = [
      info["_qualitys"] as? [String: Any],
      metadata["_qualitys"] as? [String: Any],
      info["_types"] as? [String: Any],
    ]
    let declaredSize = groups.compactMap { group -> Int64? in
      guard let raw = group?[quality] as? [String: Any], let value = raw["size"] as? NSNumber else { return nil }
      return value.int64Value > 0 ? value.int64Value : nil
    }.first
    guard let size = sourceSizes[index] ?? declaredSize else { return nil }
    let bitrate = size * 8_000 / Int64(durationMs)
    return bitrate >= 8_000 && bitrate <= 10_000_000 ? Int(bitrate) : nil
  }

  private func stop() {
    autoPlay = false
    resolving = false
    bitrateProbes.values.forEach { $0.cancel() }
    sourceBitrates.removeAll(); sourceSizes.removeAll(); bitrateProbes.removeAll(); bitrateProbeURLs.removeAll()
    player.pause(); player.removeAllItems()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    emit(status: "idle")
  }

  private func emit(status: String? = nil, error: String? = nil) {
    let active = player.currentItem.flatMap { itemIndexes[ObjectIdentifier($0)] } ?? currentIndex
    if tracks.indices.contains(active) { currentIndex = active }
    let duration = tracks.indices.contains(active)
      ? (tracks[active]["durationMs"] as? Int).map { Double($0) / 1000 } ?? player.currentItem?.duration.seconds
      : player.currentItem?.duration.seconds
    updateNowPlaying(active)
    guard let sink else { return }
    let details = audioDetails(player.currentItem)
    var values: [String: Any] = [
      "index": active,
      "status": status ?? liveStatus(),
      "positionMs": Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds * 1000 : 0),
    ]
    if let duration, duration.isFinite { values["durationMs"] = Int(duration * 1000) }
    if let bitrate = details.bitrate { values["bitrate"] = bitrate }
    if let sampleRate = details.sampleRate { values["sampleRate"] = sampleRate }
    if tracks.indices.contains(active) { values["quality"] = tracks[active]["quality"] as? String ?? "" }
    if let error { values["error"] = error }
    sink(values)
  }

  private func liveStatus() -> String {
    guard player.currentItem != nil else { return resolving ? "loading" : "idle" }
    if resolving || (autoPlay && player.timeControlStatus != .playing) { return "loading" }
    return player.rate == 0 ? "paused" : "playing"
  }
}

private extension CMTime {
  init(milliseconds: Int) {
    self.init(value: CMTimeValue(milliseconds), timescale: 1000)
  }
}
