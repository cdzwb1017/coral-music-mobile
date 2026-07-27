import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testUserApiRunnerLoadsScriptWithoutWebView() {
    let loaded = expectation(description: "script loaded")
    let runner = UserApiRunner()

    runner.load("""
      lx.on('request', () => {});
      lx.send('inited', {sources: {kw: {type: 'music', actions: ['musicUrl']}}});
      """) { value in
      let manifest = value as? [String: Any]
      XCTAssertEqual(manifest?["musicUrlSources"] as? [String], ["kw"])
      loaded.fulfill()
    }

    wait(for: [loaded], timeout: 1)
  }

}
