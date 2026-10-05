import Darwin
import Foundation
import XCTest
@testable import SlipstreamMenubarCore

final class PrometheusTextTests: XCTestCase {
    func testParsesSeriesLabelsAndSpecialValues() {
        let values = PrometheusText.parse("""
        # HELP x help text
        # TYPE x gauge
        plain_total 42
        labelled{state="a b",x="1"} 1.5 1700000000
        infinite +Inf
        not_a_number NaN
        broken
        """)
        XCTAssertEqual(values["plain_total"], 42)
        XCTAssertEqual(values["labelled{state=\"a b\",x=\"1\"}"], 1.5)
        XCTAssertEqual(values["infinite"], .infinity)
        XCTAssertTrue(values["not_a_number"]?.isNaN == true)
        XCTAssertNil(values["broken"])
        XCTAssertEqual(values.count, 4)
    }

    func testReadsARealSlipstreamCapture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "metrics", withExtension: "txt",
                                                  subdirectory: "Fixtures"))
        let metrics = PrometheusText.parse(try String(contentsOf: url, encoding: .utf8))
        let sample = try XCTUnwrap(EngineSample(metrics: metrics, time: Date()))
        XCTAssertEqual(sample.kvPagesTotal, 12032)
        XCTAssertEqual(sample.memoryLimitBytes, 59_957_743_453)
        XCTAssertEqual(sample.memoryPressure, "normal")
        XCTAssertEqual(sample.kvPagesActive + sample.kvPagesCached + sample.kvPagesFree, sample.kvPagesTotal)
    }

    func testNoSampleWithoutSlipstreamMetrics() {
        XCTAssertNil(EngineSample(metrics: ["other_metric": 1], time: Date()))
    }
}

final class EngineRatesTests: XCTestCase {
    private func sample(output: Double, prompt: Double, at seconds: Double) -> EngineSample {
        EngineSample(metrics: [
            "slipstream_v2_decode_output_tokens_total": output,
            "slipstream_v2_prefill_input_tokens_total": prompt,
        ], time: Date(timeIntervalSinceReferenceDate: seconds))!
    }

    func testRatesUseWallClockTime() throws {
        let rates = try XCTUnwrap(EngineRates.between(
            sample(output: 100, prompt: 1000, at: 0), sample(output: 180, prompt: 1700, at: 2)))
        XCTAssertEqual(rates.outputTokensPerSecond, 40)
        XCTAssertEqual(rates.promptTokensPerSecond, 350)
    }

    func testCounterResetOrClockSkewYieldsNoRate() {
        XCTAssertNil(EngineRates.between(sample(output: 500, prompt: 0, at: 0), sample(output: 10, prompt: 0, at: 1)))
        XCTAssertNil(EngineRates.between(sample(output: 0, prompt: 0, at: 5), sample(output: 1, prompt: 0, at: 5)))
    }

    func testTimeSeriesKeepsItsCapacity() {
        var series = TimeSeries(capacity: 3)
        for value in 1...5 { series.append(Double(value), at: Date(timeIntervalSinceReferenceDate: Double(value))) }
        XCTAssertEqual(series.points.map(\.value), [3, 4, 5])
        XCTAssertEqual(series.maximum, 5)
    }
}

final class LogProgressTests: XCTestCase {
    func testFollowsPreparationLoadingAndReady() {
        var log = "[Slipstream] Preparing GGUF model from /models/x...\n"
        log += "  [DONE] Layer  0 finished (1431.4 MB)\n  [DONE] Head finished (993.9 MB)\n"
        XCTAssertEqual(LogProgress.parse(log).phase, .preparing)
        XCTAssertEqual(LogProgress.parse(log).preparedParts, 2)
        log += "17:06:39 Loading · local/x\n"
        XCTAssertEqual(LogProgress.parse(log).phase, .loading)
        log += "17:06:52 Ready · local/x · context 256K · http://127.0.0.1:8090\n"
        XCTAssertEqual(LogProgress.parse(log).phase, .ready)
    }

    func testKeepsTheLastError() {
        let progress = LogProgress.parse("error: first\nother\nerror: preparing /m failed; see the output above\n")
        XCTAssertEqual(progress.lastError, "error: preparing /m failed; see the output above")
    }
}

final class StatusResolverTests: XCTestCase {
    func testNoProcessIsStoppedUnlessSomethingAnswersThePort() {
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: false, healthOK: false, readyOK: false)), .stopped)
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: false, healthOK: true, readyOK: true)), .running)
    }

    func testAnUnexpectedExitIsAFailureWithTheLoggedError() {
        var log = LogProgress()
        log.lastError = "error: model download failed"
        let status = StatusResolver.resolve(.init(processAlive: false, healthOK: false, readyOK: false,
                                                  logProgress: log, exitDescription: "Server exited with status 1"))
        XCTAssertEqual(status, .failed("error: model download failed"))
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: false, healthOK: false, readyOK: false,
                                                    stopping: true, exitDescription: "signal 15")), .stopped)
    }

    func testStartupPhases() {
        var log = LogProgress()
        log.phase = .preparing
        log.preparedParts = 7
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: false, readyOK: false,
                                                    logProgress: log)), .preparing(parts: 7))
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: true, readyOK: false)), .loading)
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: false, readyOK: false)), .starting)
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: true, readyOK: true)), .running)
    }

    func testABusyServerSeenFirstAtLaunchIsRunningNotLoading() {
        let busy = StatusObservation(processAlive: true, healthOK: true, readyOK: false,
                                     hasServedRequests: true)
        XCTAssertEqual(StatusResolver.resolve(busy), .running)
        var logged = LogProgress()
        logged.phase = .ready
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: true, readyOK: false,
                                                    logProgress: logged)), .running)
        // A server that has not served anything and is not ready is still loading.
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: true, readyOK: false)), .loading)
    }

    func testASaturatedServerStaysRunningWhileHealthy() {
        // Under load /ready answers 503 but /health stays 200.
        let busy = StatusObservation(processAlive: true, healthOK: true, readyOK: false,
                                     previous: .running, healthFailures: 0)
        XCTAssertEqual(StatusResolver.resolve(busy), .running)
        var recovered = busy
        recovered.previous = .unresponsive
        XCTAssertEqual(StatusResolver.resolve(recovered), .running)
    }

    func testARunningServerTurnsUnresponsiveOnlyAfterRepeatedFailures() {
        let blip = StatusObservation(processAlive: true, healthOK: false, readyOK: false,
                                     previous: .running, healthFailures: 1)
        XCTAssertEqual(StatusResolver.resolve(blip), .running)
        var lasting = blip
        lasting.healthFailures = StatusResolver.unresponsiveAfter
        XCTAssertEqual(StatusResolver.resolve(lasting), .unresponsive)
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: true, readyOK: false,
                                                    stopping: true, previous: .running)), .stopping)
    }
}

final class ServerConfigTests: XCTestCase {
    func testServeArgumentsIncludeOnlySetOptions() {
        var config = ServerConfig(repoPath: "/repo", model: "/models/m", port: 8091)
        XCTAssertEqual(config.serveArguments(), ["serve", "--model", "/models/m", "--port", "8091"])
        config.maxContext = "100K"
        config.maxMemory = " 48G "
        config.allowedHosts = ["mac.local", " ", "10.0.0.2"]
        config.noWebUI = true
        XCTAssertEqual(config.serveArguments(), [
            "serve", "--model", "/models/m", "--port", "8091", "--max-context", "100K", "--max-memory", "48G",
            "--allowed-host", "mac.local", "--allowed-host", "10.0.0.2", "--no-webui",
        ])
    }

    func testValidation() {
        // The GPU limit is off: whether its default fits depends on this machine's memory.
        let config = ServerConfig(repoPath: "/nonexistent", model: "", port: 0, maxContext: "lots", maxMemory: "48G",
                                  raiseGPULimit: false)
        let errors = config.validationErrors(installation: nil)
        XCTAssertEqual(errors.count, 4, "\(errors)")
        var limited = config
        limited.raiseGPULimit = true
        limited.gpuWiredLimitMB = 4096
        XCTAssertTrue(limited.validationErrors(installation: nil).contains { $0.contains("GPU memory limit") })
    }

    func testRoundTripsThroughTheStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("menubar.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigStore(url: url)
        let config = ServerConfig(repoPath: "/r", model: "/m", port: 9000, allowedHosts: ["a"], startServerOnLaunch: true)
        try store.save(config)
        XCTAssertEqual(store.load(), config)
        XCTAssertEqual(ConfigStore(url: url.appendingPathExtension("missing")).load(), ServerConfig())
    }
}

final class ProcessInspectorTests: XCTestCase {
    func testReadsOwnArguments() throws {
        let arguments = try XCTUnwrap(ServerProcessInspector.arguments(of: getpid()))
        XCTAssertEqual(arguments.count, CommandLine.arguments.count)
        XCTAssertTrue(ServerProcessInspector.isAlive(getpid()))
        XCTAssertFalse(ServerProcessInspector.isSlipstreamServer(getpid()))
    }

    func testDeadPid() {
        XCTAssertFalse(ServerProcessInspector.isAlive(0))
        XCTAssertFalse(ServerProcessInspector.isAlive(Int32.max))
    }

    func testReadsTheLock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"pid": 70756, "model": "/m", "port": 8090}"#.utf8).write(to: url)
        XCTAssertEqual(ServeLock.read(from: url), ServeLock(pid: 70756, model: "/m", port: 8090))
        try Data().write(to: url)
        XCTAssertNil(ServeLock.read(from: url))
    }
}

final class SystemSamplerTests: XCTestCase {
    func testSamplesPlausibleValues() {
        let sampler = SystemSampler()
        let first = sampler.sample()
        XCTAssertNil(first.cpuUsage, "needs two readings")
        usleep(200_000)
        let second = sampler.sample()
        XCTAssertNotNil(second.cpuUsage)
        XCTAssertTrue((0...1).contains(second.cpuUsage ?? -1))
        XCTAssertGreaterThan(second.memoryUsedBytes, 0)
        XCTAssertLessThanOrEqual(second.memoryUsedBytes, second.memoryTotalBytes)
        if let gpu = second.gpuUsage { XCTAssertTrue((0...1).contains(gpu)) }
    }
}

final class NetworkAccessTests: XCTestCase {
    func testOlderConfigFilesLoadWithDefaultsForNewKeys() throws {
        let json = #"{"repoPath":"/r","model":"/m","port":8090,"maxContext":"","maxMemory":"","allowedHosts":[],"noWebUI":false,"startServerOnLaunch":true}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.listenOnNetwork)
        XCTAssertTrue(config.startServerOnLaunch)
        XCTAssertEqual(config.model, "/m")
    }

    func testHostIsPassedOnlyWhenListeningOnTheNetwork() {
        var config = ServerConfig(repoPath: "/r", model: "/m", port: 8090)
        XCTAssertFalse(config.serveArguments().contains("--host"))
        config.listenOnNetwork = true
        let arguments = config.serveArguments()
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--host")! + 1], "0.0.0.0")
    }

    func testLockHostAndNetworkFlag() throws {
        let old = try JSONDecoder().decode(ServeLock.self, from: Data(#"{"pid":1,"model":"m","port":8090}"#.utf8))
        XCTAssertNil(old.host)
        XCTAssertFalse(old.listensOnNetwork)
        let network = try JSONDecoder().decode(
            ServeLock.self, from: Data(#"{"pid":1,"model":"m","port":8090,"host":"0.0.0.0"}"#.utf8))
        XCTAssertTrue(network.listensOnNetwork)
        XCTAssertFalse(ServeLock(pid: 1, model: "m", port: 1, host: "127.0.0.1").listensOnNetwork)
    }

    func testLauncherCapabilityCheck() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("install"),
                                                withIntermediateDirectories: true)
        let launcher = repo.appendingPathComponent("install/launcher.py")
        let script = repo.appendingPathComponent("slipstream")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var config = ServerConfig(repoPath: repo.path, model: "/m", listenOnNetwork: true)
        try Data(#"server.add_argument("--port")"#.utf8).write(to: launcher)
        let checkout = try XCTUnwrap(SlipstreamInstallation.checkout(at: repo))
        XCTAssertFalse(checkout.supportsHost)
        XCTAssertTrue(config.validationErrors(installation: checkout).contains { $0.contains("--host") })
        try Data(#"server.add_argument("--host", default="127.0.0.1")"#.utf8).write(to: launcher)
        XCTAssertTrue(checkout.supportsHost)
        XCTAssertFalse(checkout.supportsPull)
        try Data(#"puller = commands.add_parser("pull", help="download")"#.utf8).write(to: launcher)
        XCTAssertTrue(checkout.supportsPull)
        config.listenOnNetwork = false
        XCTAssertFalse(config.validationErrors(installation: checkout).contains { $0.contains("--host") })

        // Keeping GGUF files is asked for only from a launcher that knows the flag; older ones keep them anyway.
        config.keepGGUFFiles = true
        XCTAssertFalse(checkout.supportsKeepGGUF)
        XCTAssertFalse(config.serveArguments(for: checkout).contains("--keep-gguf"))
        try Data(#"server.add_argument("--keep-gguf", action="store_true")"#.utf8).write(to: launcher)
        XCTAssertTrue(checkout.supportsKeepGGUF)
        XCTAssertEqual(config.serveArguments(for: checkout).last, "--keep-gguf")
        XCTAssertFalse(config.serveArguments().contains("--keep-gguf"))
        config.keepGGUFFiles = false
        XCTAssertFalse(config.serveArguments(for: checkout).contains("--keep-gguf"))
    }

    func testAddressesExcludeLoopback() {
        let addresses = NetworkAddresses.ipv4()
        XCTAssertFalse(addresses.contains("127.0.0.1"))
        XCTAssertTrue(addresses.allSatisfy { $0.split(separator: ".").count == 4 })
        XCTAssertTrue(NetworkAddresses.localHostName()?.hasSuffix(".local") ?? true)
    }
}

final class TimeSeriesWindowTests: XCTestCase {
    private func time(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    func testDropsPointsOlderThanTheWindowButKeepsOneForTheLeftEdge() {
        var series = TimeSeries(capacity: 1000, window: 10)
        for second in stride(from: 0.0, through: 30, by: 3) { series.append(second, at: time(second)) }
        // Window ends at 30: 21, 24, 27, 30 are inside, 18 is kept for the edge.
        XCTAssertEqual(series.points.map(\.value), [18, 21, 24, 27, 30])
    }

    func testSlowSamplingNoLongerAccumulatesBeyondTheWindow() {
        var series = TimeSeries(capacity: 400, window: 300)
        for step in 0..<1000 { series.append(1, at: time(Double(step) * 3)) }  // 50 minutes at 3 s
        XCTAssertLessThanOrEqual(series.points.count, 102)
    }

    func testPointsWithinAWindowEndingNow() {
        var series = TimeSeries(capacity: 100)
        for second in 0...10 { series.append(Double(second), at: time(Double(second))) }
        XCTAssertEqual(series.points(within: 3, endingAt: time(10)).map(\.value), [6, 7, 8, 9, 10])
        XCTAssertEqual(series.points(within: 3, endingAt: time(100)).map(\.value), [10])
        XCTAssertTrue(TimeSeries(capacity: 1).points(within: 3, endingAt: time(0)).isEmpty)
    }
}

final class DataGapTests: XCTestCase {
    private func time(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    func testClipsToTheChartWindow() {
        let window = time(100)...time(400)
        XCTAssertEqual(DataGap(start: time(50), end: time(150)).clipped(to: window), time(100)...time(150))
        XCTAssertEqual(DataGap(start: time(380)).clipped(to: window), time(380)...time(400), "open gap runs to now")
        XCTAssertNil(DataGap(start: time(10), end: time(90)).clipped(to: window))
    }

    func testSegmentsAreKeptPerPoint() {
        var series = TimeSeries(capacity: 10)
        series.append(1, at: time(1), segment: 0)
        series.append(2, at: time(9), segment: 1)
        XCTAssertEqual(series.points.map(\.segment), [0, 1])
    }
}

final class InstallationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// <root>/share/<version>/{bin/slipstream, release.json, install/launcher.py}, linked from <root>/bin.
    private func makeRelease(_ version: String, host: Bool = true) throws -> URL {
        let package = root.appendingPathComponent("share/\(version)")
        try executable(package.appendingPathComponent("bin/slipstream"))
        try Data(#"{"version": "\#(version)"}"#.utf8).write(to: package.appendingPathComponent("release.json"))
        try FileManager.default.createDirectory(at: package.appendingPathComponent("install"), withIntermediateDirectories: true)
        try Data((host ? #"add_argument("--host")"# : "").utf8)
            .write(to: package.appendingPathComponent("install/launcher.py"))
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: bin.appendingPathComponent("slipstream"))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("slipstream"),
                                                   withDestinationURL: package.appendingPathComponent("bin/slipstream"))
        return bin
    }

    private func makeCheckout() throws -> URL {
        let checkout = root.appendingPathComponent("checkout")
        try executable(checkout.appendingPathComponent("slipstream"))
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("install"), withIntermediateDirectories: true)
        try Data().write(to: checkout.appendingPathComponent("install/launcher.py"))
        return checkout
    }

    func testFindsTheReleaseThroughTheBinLink() throws {
        let bin = try makeRelease("26.10.0")
        let found = try XCTUnwrap(InstallationLocator.find(config: ServerConfig(), searchPath: [], binDirectory: bin))
        XCTAssertEqual(found.kind, .release)
        XCTAssertEqual(found.version, "26.10.0")
        XCTAssertEqual(found.root.resolvingSymlinksInPath().lastPathComponent, "26.10.0")
        XCTAssertEqual(found.launcher.path, bin.appendingPathComponent("slipstream").path, "runs the link, not the target")
        XCTAssertTrue(found.supportsHost)
        XCTAssertTrue(found.serveLockURL.path.hasSuffix("Slipstream-v2/runtime/serve.lock"))
        XCTAssertEqual(found.displayName, "Slipstream 26.10.0")
    }

    func testFallsBackToPathAndRecognisesACheckoutThere() throws {
        let checkout = try makeCheckout()
        let empty = root.appendingPathComponent("nothing")
        XCTAssertNil(InstallationLocator.find(config: ServerConfig(), searchPath: [], binDirectory: empty))
        let found = try XCTUnwrap(InstallationLocator.find(config: ServerConfig(), searchPath: ["/nope", checkout.path],
                                                           binDirectory: empty))
        XCTAssertEqual(found.kind, .checkout)
        XCTAssertEqual(found.serveLockURL, checkout.appendingPathComponent("build/runtime/serve.lock"))
        XCTAssertFalse(found.supportsHost)
    }

    func testTheCheckoutSettingWinsOverAnInstalledRelease() throws {
        let bin = try makeRelease("26.10.0")
        let checkout = try makeCheckout()
        var config = ServerConfig(repoPath: checkout.path)
        config.useCheckout = true
        XCTAssertEqual(InstallationLocator.find(config: config, searchPath: [], binDirectory: bin)?.kind, .checkout)
        config.repoPath = root.appendingPathComponent("missing").path
        XCTAssertNil(InstallationLocator.find(config: config, searchPath: [], binDirectory: bin))
        XCTAssertTrue(config.validationErrors(installation: nil).contains { $0.contains("checkout") })
    }

    func testWatchesEveryLockAServerMayHaveWritten() throws {
        let checkout = try makeCheckout()
        let config = ServerConfig(repoPath: checkout.path)
        let release = InstallationLocator.find(config: config, searchPath: [],
                                               binDirectory: try makeRelease("26.10.0"))
        let locks = InstallationLocator.serveLocks(installation: release, config: config)
        XCTAssertEqual(locks.count, 2, "release data lock and the checkout's, without duplicates")
        XCTAssertTrue(locks.contains(checkout.appendingPathComponent("build/runtime/serve.lock")))
    }

    func testNotInstalledIsAValidationError() {
        let config = ServerConfig(model: "/m")
        XCTAssertTrue(config.validationErrors(installation: nil).contains { $0.contains("not installed") })
    }

    func testOlderSettingsDefaultToTheInstalledRelease() throws {
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"repoPath":"/r","model":"/m"}"#.utf8))
        XCTAssertFalse(config.useCheckout)
        XCTAssertEqual(config.releaseRepository, "npanj/slipstream")
    }
}

final class ReleasePackagesTests: XCTestCase {
    let sums = """
    aaa  slipstream-26.10.0-macos26-arm-64bit.zip
    bbb  slipstream-26.10.0-macos27-arm-64bit.zip
    ccc  slipstream-26.10.0-macos26-x86-64bit.zip
    ddd  install.sh
    """

    func testPicksTheNewestPackageThisMacOSCanRun() {
        XCTAssertEqual(ReleasePackages.select(from: sums, macOSMajor: 26)?.name, "slipstream-26.10.0-macos26-arm-64bit.zip")
        XCTAssertEqual(ReleasePackages.select(from: sums, macOSMajor: 26)?.sha256, "aaa")
        XCTAssertEqual(ReleasePackages.select(from: sums, macOSMajor: 28)?.sha256, "bbb")
        XCTAssertNil(ReleasePackages.select(from: sums, macOSMajor: 15))
    }

    func testVersionFromThePackageFolder() {
        XCTAssertEqual(ReleasePackages.version(fromPackageFolder: "slipstream-26.10.0-macos26-arm-64bit"), "26.10.0")
        XCTAssertNil(ReleasePackages.version(fromPackageFolder: "something-else"))
    }

    func testKeepsTheInstalledAndTheNewestOtherVersion() {
        let removed = ReleasePackages.superseded(["26.8.0", "26.10.0", "26.9.0", "notes", "26.9.10"], installed: "26.10.0")
        XCTAssertEqual(Set(removed), ["26.8.0", "26.9.0"], "26.9.10 is newer than 26.9.0 numerically")
        XCTAssertTrue(ReleasePackages.superseded(["26.10.0"], installed: "26.10.0").isEmpty)
    }
}

final class ModelSetupTests: XCTestCase {
    func testTotalSizeSumsTheFilesOfAHubTree() {
        let tree = Data(#"[{"type":"file","path":"a.gguf","size":45566928224},{"type":"directory","path":"MTP"},{"type":"file","path":"README.md","size":2351}]"#.utf8)
        XCTAssertEqual(ModelSpec.totalSize(ofTree: tree), 45_566_930_575)
        XCTAssertNil(ModelSpec.totalSize(ofTree: Data("{}".utf8)))
    }

    func testTheDefaultModelIsTheReadmesSwiftVariant() {
        let model = ModelSpec.swiftQwen38FlashNext
        XCTAssertEqual(model.repository, "nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF")
        XCTAssertEqual(model.folderURL, ModelStore.root.appendingPathComponent(model.repository))
    }

    func testModelPresence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(ModelPresence.isAvailable(""))
        XCTAssertFalse(ModelPresence.isAvailable(folder.path), "missing folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(ModelPresence.isAvailable(folder.path), "empty folder")
        try Data("x".utf8).write(to: folder.appendingPathComponent("model-00001-of-00003.gguf"))
        XCTAssertTrue(ModelPresence.isAvailable(folder.path))
        XCTAssertGreaterThan(ModelPresence.allocatedSize(of: folder), 0)
    }

    func testHubIDsAreAvailableOnceTheirPullFinished() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("SLIPSTREAM_MODELS", store.path, 1)
        defer { unsetenv("SLIPSTREAM_MODELS"); try? FileManager.default.removeItem(at: store) }
        XCTAssertEqual(ModelStore.folder(for: "owner/repo"), store.appendingPathComponent("owner/repo"))
        XCTAssertFalse(ModelPresence.isAvailable("owner/repo"), "not downloaded")
        let folder = ModelStore.folder(for: "owner/repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent(ModelStore.markerName)
        try Data(#"{"model": "owner/repo", "revision": "abc"}"#.utf8).write(to: marker)
        XCTAssertFalse(ModelPresence.isAvailable("owner/repo"), "a pull still running or stopped")
        try Data(#"{"model": "owner/repo", "revision": "abc", "downloaded": true}"#.utf8).write(to: marker)
        XCTAssertTrue(ModelPresence.isAvailable("owner/repo"))
        XCTAssertTrue(ModelStore.isDownloaded("owner/repo"))
    }

    func testOnly64GBMacsRaiseTheGPULimit() {
        XCTAssertTrue(MachineCheck.needsGPULimitRaise(memoryGiB: 64))
        XCTAssertFalse(MachineCheck.needsGPULimitRaise(memoryGiB: 48))
        XCTAssertFalse(MachineCheck.needsGPULimitRaise(memoryGiB: 128))
        XCTAssertEqual(GPUMemoryLimit.command(megabytes: 59392), "/usr/sbin/sysctl iogpu.wired_limit_mb=59392")
        XCTAssertNotNil(GPUMemoryLimit.currentMB(), "the sysctl exists on Apple Silicon")
    }

    func testTransferEstimate() {
        var estimator = TransferEstimator(window: 20)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        estimator.add(bytes: 0, at: start)
        XCTAssertNil(estimator.bytesPerSecond)
        estimator.add(bytes: 500_000_000, at: start.addingTimeInterval(10))  // 50 MB/s
        XCTAssertEqual(estimator.bytesPerSecond ?? 0, 50_000_000, accuracy: 1)
        XCTAssertEqual(estimator.secondsRemaining(total: 3_500_000_000) ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(TransferEstimator.describe(30), "less than a minute")
        XCTAssertEqual(TransferEstimator.describe(240), "about 4 min")
        XCTAssertEqual(TransferEstimator.describe(4_320), "about 1 h 12 min")
    }

    func testGPULimitSettingsDefaultAndValidate() throws {
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"model":"/m"}"#.utf8))
        XCTAssertTrue(config.raiseGPULimit)
        XCTAssertEqual(config.gpuWiredLimitMB, 59392)
        var bad = config
        bad.gpuWiredLimitMB = 100
        XCTAssertTrue(bad.validationErrors(installation: nil).contains { $0.contains("GPU memory limit") })
    }
}

final class DiskCheckTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    func testTenGigabytesMustRemainAfterTheDownload() {
        XCTAssertEqual(DiskCheck.evaluate(total: 100 * gb, downloaded: 0, free: 105 * gb), .insufficient(shortBy: 5 * gb))
        XCTAssertEqual(DiskCheck.evaluate(total: 100 * gb, downloaded: 0, free: 110 * gb),
                       .noRoomToPrepare(shortBy: 100 * gb))
        XCTAssertEqual(DiskCheck.evaluate(total: 100 * gb, downloaded: 0, free: 210 * gb), .ok)
    }

    func testAPartialDownloadCountsTowardsTheModel() {
        // 60 GB already on disk: 40 GB to go, and 10 GB must remain.
        XCTAssertEqual(DiskCheck.evaluate(total: 100 * gb, downloaded: 60 * gb, free: 50 * gb),
                       .noRoomToPrepare(shortBy: 100 * gb))
        XCTAssertEqual(DiskCheck.evaluate(total: 100 * gb, downloaded: 60 * gb, free: 45 * gb),
                       .insufficient(shortBy: 5 * gb))
    }
}

final class MTPDraftHeadTests: XCTestCase {
    func testTheSwiftModelBringsTheMTPDraftHead() {
        XCTAssertEqual(ModelSpec.swiftQwen38FlashNext.extraFiles,
                       [ModelSpec.ExtraFile(repository: "nitinpanj/qwen38-flash-next-v3", path: "MTP/mtp-shared-Q4_K_M.gguf")])
    }

    func testSizeOfOneFileInATree() {
        let tree = Data(#"[{"type":"file","path":"MTP/mtp-shared-Q4_K_M.gguf","size":1907151936},{"type":"file","path":"README.md","size":6908}]"#.utf8)
        XCTAssertEqual(ModelSpec.size(of: "MTP/mtp-shared-Q4_K_M.gguf", inTree: tree), 1_907_151_936)
        XCTAssertNil(ModelSpec.size(of: "missing.gguf", inTree: tree))
    }

    func testTheConvertersMissingMTPWarningIsNoticed() {
        let log = "Warning: no MTP draft head (MTP/mtp-shared-Q4_K_M.gguf) next to the model; ...\n=== Fast GGUF Ingestion ===\n"
        XCTAssertTrue(LogProgress.parse(log).missingMTPDraftHead)
        XCTAssertFalse(LogProgress.parse("Sidecar: /m/MTP/mtp-shared-Q4_K_M.gguf\n").missingMTPDraftHead)
    }
}

final class RunningVersionTests: XCTestCase {
    func testTheRootComesFromTheServersArguments() {
        let serving = ["/x/26.10.0/python/bin/python3", "-u", "/x/26.10.0/server/server.py", "/m/prepared/target"]
        XCTAssertEqual(SlipstreamInstallation.runningRoot(arguments: serving)?.path, "/x/26.10.0")
        let preparing = ["python3", "-u", "/repo/install/launcher.py", "serve", "--model", "/m"]
        XCTAssertEqual(SlipstreamInstallation.runningRoot(arguments: preparing)?.path, "/repo")
        XCTAssertNil(SlipstreamInstallation.runningRoot(arguments: ["/usr/bin/python3", "other.py"]))
    }

    func testTheVersionOfARoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(SlipstreamInstallation.releaseVersion(ofRoot: root), "a checkout has no release.json")
        try Data(#"{"version": "26.10.0"}"#.utf8).write(to: root.appendingPathComponent("release.json"))
        XCTAssertEqual(SlipstreamInstallation.releaseVersion(ofRoot: root), "26.10.0")
    }
}

final class ModelCatalogTests: XCTestCase {
    func testTheCatalog() {
        XCTAssertEqual(ModelSpec.catalog.map(\.repository), [
            "MikeZ75/Swift-Qwen3.8-Flash-Next-V3-Splash", "nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF",
            "MikeZ75/Qwen3.8-Flash-Next-V3-Splash", "nitinpanj/qwen38-flash-next-v3",
        ], "the engine loads only Qwen3.8-Flash-Next")
        XCTAssertEqual(ModelSpec.qwen38FlashNext.memoryNote, "64 GB Mac")
        XCTAssertEqual(ModelSpec(repository: "a/b", title: "b", minimumMemoryGiB: 36,
                                 recommendedMemoryGiB: 48).memoryNote, "36 GB Mac, 48 GB recommended")
        XCTAssertTrue(ModelSpec.qwen38FlashNext.extraFiles.isEmpty, "the base model ships its MTP head")
        XCTAssertEqual(ModelSpec.matching(model: "nitinpanj/qwen38-flash-next-v3", in: ModelSpec.catalog)?.title,
                       "Qwen3.8-Flash-Next V3")
        XCTAssertEqual(ModelSpec.matching(model: ModelSpec.qwen38FlashNext.folder, in: ModelSpec.catalog)?.title,
                       "Qwen3.8-Flash-Next V3", "its folder in the model store")
        XCTAssertNil(ModelSpec.matching(model: "~/models/qwen38-flash-next-v3", in: ModelSpec.catalog),
                     "a folder outside the store is a custom model")
        XCTAssertNil(ModelSpec.matching(model: "/elsewhere", in: ModelSpec.catalog))
    }

    func testRecognisesPackagesAndGGUFRepositories() {
        let package = Data(#"[{"type":"file","path":"manifest.json","size":10},{"type":"file","path":"target/layer-0.bin","size":90}]"#.utf8)
        XCTAssertEqual(ModelCheck.layout(ofTree: package).layout, .package)
        XCTAssertEqual(ModelCheck.layout(ofTree: package).size, 100)
        let gguf = Data(#"[{"type":"file","path":"m-00002-of-00002.gguf","size":5},{"type":"file","path":"m-00001-of-00002.gguf","size":5}]"#.utf8)
        XCTAssertEqual(ModelCheck.layout(ofTree: gguf).layout, .gguf(firstShard: "m-00001-of-00002.gguf", hasMTP: false))
        let withMTP = Data(#"[{"type":"file","path":"a.gguf","size":5},{"type":"file","path":"MTP/mtp-shared-Q4_K_M.gguf","size":1}]"#.utf8)
        XCTAssertEqual(ModelCheck.layout(ofTree: withMTP).layout, .gguf(firstShard: "a.gguf", hasMTP: true))
        if case .unsupported = ModelCheck.layout(ofTree: Data(#"[{"type":"file","path":"model.safetensors","size":5}]"#.utf8)).layout {
        } else { XCTFail("safetensors-only repositories are not served") }
    }

    func testManifestFormats() {
        XCTAssertNil(ModelCheck.problem(withManifest: Data(#"{"schema_version":5,"format":{"name":"splash-packed-q4-qwen4exp"}}"#.utf8)))
        // Splash 1.0 formats the launcher lists but the engine rejects ("unsupported weight format").
        XCTAssertNotNil(ModelCheck.problem(withManifest: Data(#"{"schema_version":3,"format":{"name":"splash-packed-q4"}}"#.utf8)))
        XCTAssertNotNil(ModelCheck.problem(withManifest: Data(#"{"schema_version":4,"format":{"name":"splash-packed-q4-moe"}}"#.utf8)))
        XCTAssertNotNil(ModelCheck.problem(withManifest: Data(#"{"schema_version":3,"format":{"name":"mlx"}}"#.utf8)))
        XCTAssertNotNil(ModelCheck.problem(withManifest: Data(#"{"schema_version":4,"format":{"name":"splash-packed-q4-qwen4exp"}}"#.utf8)))
        XCTAssertNotNil(ModelCheck.problem(withManifest: Data("not json".utf8)))
    }

    func testGGUFArchitectureFromTheHeader() {
        func header(_ kvs: [(String, UInt32, Data)]) -> Data {
            var data = Data("GGUF".utf8)
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func string(_ s: String) { u64(UInt64(s.utf8.count)); data.append(contentsOf: s.utf8) }
            u32(3); u64(0); u64(UInt64(kvs.count))
            for (key, type, value) in kvs { string(key); u32(type); data.append(value) }
            return data
        }
        func stringValue(_ s: String) -> Data {
            var d = Data(); withUnsafeBytes(of: UInt64(s.utf8.count).littleEndian) { d.append(contentsOf: $0) }
            d.append(contentsOf: s.utf8); return d
        }
        let version = Data([1, 0, 0, 0])  // a u32 key/value before the architecture
        let data = header([("general.file_type", 4, version), ("general.architecture", 8, stringValue("qwen4exp"))])
        XCTAssertEqual(GGUFHeader.architecture(in: data), "qwen4exp")
        XCTAssertNil(GGUFHeader.architecture(in: data.prefix(20)), "truncated before the key")
        XCTAssertNil(GGUFHeader.architecture(in: Data("NOPE".utf8)))
        XCTAssertNil(ModelCheck.problem(withArchitecture: "qwen4exp"))
        XCTAssertNotNil(ModelCheck.problem(withArchitecture: "qwen2"))
    }

    func testSpecsForNewModels() {
        let package = ModelCheck.spec(repository: "someone/Thing-Splash", layout: .package)
        XCTAssertEqual(package?.kind, .package)
        XCTAssertEqual(package?.folderURL, ModelStore.folder(for: "someone/Thing-Splash"))
        XCTAssertEqual(package?.minimumMemoryGiB, 64, "the only loadable package is Flash-Next")
        let gguf = ModelCheck.spec(repository: "someone/Flash-GGUF", layout: .gguf(firstShard: "a.gguf", hasMTP: false))
        XCTAssertEqual(gguf?.extraFiles, [ModelSpec.mtpDraftHead], "a GGUF without its own MTP head gets the shared one")
        XCTAssertEqual(gguf?.minimumMemoryGiB, 64)
    }

    func testCustomModelsAreStoredAndListedOnce() throws {
        var config = ServerConfig()
        config.customModels = [ModelSpec(repository: "someone/Thing-Splash", title: "Thing",
                                         kind: .package, minimumMemoryGiB: 36, recommendedMemoryGiB: 48),
                               ModelSpec.qwen38FlashNext]
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.customModels.first?.repository, "someone/Thing-Splash")
        XCTAssertEqual(decoded.availableModels.count, ModelSpec.catalog.count + 1, "a catalog model is not repeated")
    }

    func testOlderSettingsWithModelFoldersStillLoad() throws {
        let json: String = #"{"model": "~/models/thing", "customModels": [{"repository": "someone/Thing", "#
            + #""folder": "~/models/thing", "title": "Thing", "extraFiles": [], "kind": "gguf", "#
            + #""minimumMemoryGiB": 64, "recommendedMemoryGiB": 64}]}"#
        let saved = Data(json.utf8)
        let config = try JSONDecoder().decode(ServerConfig.self, from: saved)
        XCTAssertEqual(config.model, "~/models/thing", "a configured folder is kept and served as a folder")
        XCTAssertEqual(config.customModels.first?.folderURL, ModelStore.folder(for: "someone/Thing"),
                       "a custom model now lives in the store")
    }

    func testPackagesNeedNoRoomForAPreparedCopy() {
        let gb: Int64 = 1_000_000_000
        XCTAssertEqual(DiskCheck.evaluate(total: 20 * gb, downloaded: 0, free: 35 * gb, preparation: .none), .ok)
        XCTAssertEqual(DiskCheck.evaluate(total: 20 * gb, downloaded: 0, free: 35 * gb, preparation: .alongside),
                       .noRoomToPrepare(shortBy: 15 * gb), "35 - 20 - 20 leaves -5 GB, 15 GB short of the reserve")
    }

    func testPreparingInPlaceNeedsATwentiethAndThePartsInFlight() {
        let gb: Int64 = 1_000_000_000
        let inFlight: Int64 = 12 * 1_073_741_824
        // A 100 GB model: 5 GB of growth plus 12.9 GB in flight, not another 100 GB.
        XCTAssertEqual(DiskCheck.Preparation.inPlace.bytes(total: 100 * gb), 5 * gb + inFlight)
        XCTAssertEqual(DiskCheck.evaluate(total: 100 * gb, downloaded: 0, free: 115 * gb + inFlight,
                                          preparation: .inPlace), .ok)
        XCTAssertEqual(DiskCheck.evaluate(total: 100 * gb, downloaded: 0, free: 115 * gb + inFlight,
                                          preparation: .alongside), .noRoomToPrepare(shortBy: 95 * gb - inFlight))
    }

    func testOlderSettingsUseGGUFFilesUp() throws {
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"model": "a/b"}"#.utf8))
        XCTAssertFalse(config.keepGGUFFiles)
    }
}

final class CleanupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("SLIPSTREAM_MODELS", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("SLIPSTREAM_MODELS")
        try? FileManager.default.removeItem(at: root)
    }

    private func model(_ name: String, holdsModel: Bool) throws -> ModelSpec {
        let spec = ModelSpec(repository: "test/\(name)", title: name)
        try FileManager.default.createDirectory(at: spec.folderURL, withIntermediateDirectories: true)
        if holdsModel { try Data("x".utf8).write(to: spec.folderURL.appendingPathComponent("m-00001-of-00001.gguf")) }
        return spec
    }

    func testListsOnlyFoldersThatHoldAModelOnce() throws {
        let present = try model("present", holdsModel: true)
        let empty = try model("empty", holdsModel: false)
        let items = Cleanup.modelItems(models: [present, empty, present], configuredModel: present.folderURL.path)
        XCTAssertEqual(items.map(\.title), ["present"], "no empty folder, no duplicate")
        XCTAssertTrue(items[0].isModel)
        XCTAssertTrue(Cleanup.modelItems(models: [], configuredModel: "owner/repo").isEmpty, "a Hub id is no folder")
    }

    func testDeletingAModelRemovesOnlyItsFolder() throws {
        let keep = try model("keep", holdsModel: true)
        let drop = try model("drop", holdsModel: true)
        let item = try XCTUnwrap(Cleanup.modelItems(models: [drop], configuredModel: "").first)
        try Cleanup.remove(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: drop.folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.folderURL.path))
    }

    func testTheAppBundleIsNeverDeletedDirectly() throws {
        let app = root.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Cleanup.remove(CleanupItem(kind: .app, url: app))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "it goes to the Trash through NSWorkspace")
    }

    func testCollectionsAreRejectedButNotLargeModels() {
        let collection = Data(#"[{"type":"file","path":"Q4_K_M/m-00001-of-00002.gguf","size":5},{"type":"file","path":"IQ2/m.gguf","size":5}]"#.utf8)
        if case .unsupported(let reason) = ModelCheck.layout(ofTree: collection).layout {
            XCTAssertTrue(reason.contains("sub-folders"))
        } else { XCTFail("a multi-variant collection must be rejected") }
        let huge = Data(#"[{"type":"file","path":"m.gguf","size":300000000000}]"#.utf8)
        XCTAssertEqual(ModelCheck.layout(ofTree: huge).layout, .gguf(firstShard: "m.gguf", hasMTP: false),
                       "one 300 GB model is one model; a bigger Mac serves it")
        let sideBySide = Data(#"[{"type":"file","path":"m.Q4_0.gguf","size":5},{"type":"file","path":"m.Q8_0.gguf","size":5}]"#.utf8)
        if case .unsupported(let reason) = ModelCheck.layout(ofTree: sideBySide).layout {
            XCTAssertTrue(reason.contains("not one model"))
        } else { XCTFail("two quantisations side by side must be rejected") }
    }
}

final class AppUpdateTests: XCTestCase {
    private let notes = """
    ## Changes

    - Check for updates and update the app from the menu
    - Uninstall and Cleanup in Settings

    ## Install
    - not a change
    """

    func testReadsTheLatestRelease() throws {
        let json = """
        {"tag_name": "v26.10.1", "html_url": "https://github.com/o/r/releases/tag/v26.10.1",
         "body": \(String(data: try JSONEncoder().encode(notes), encoding: .utf8)!),
         "assets": [
           {"name": "Slipstream-Menubar.app.26.10.1.zip", "size": 1234,
            "browser_download_url": "https://example.com/a.zip"},
           {"name": "SHA256SUMS.26.10.1.txt", "browser_download_url": "https://example.com/sums"}]}
        """
        let release = try XCTUnwrap(AppRelease(json: Data(json.utf8)))
        XCTAssertEqual(release.version, "26.10.1")
        XCTAssertEqual(release.changes, ["Check for updates and update the app from the menu",
                                         "Uninstall and Cleanup in Settings"])
        XCTAssertEqual(release.assets[release.zipName]?.absoluteString, "https://example.com/a.zip")
        XCTAssertEqual(release.sizes[release.zipName], 1234)
        XCTAssertNotNil(release.assets[release.checksumsName])
        XCTAssertNil(AppRelease(json: Data("{}".utf8)))
        XCTAssertEqual(AppRelease.changes(fromNotes: "Just text"), [])
    }

    func testOffersOnlyNewerRealVersions() {
        XCTAssertTrue(AppUpdate.isNewer("26.10.1", than: "26.10.0"))
        XCTAssertTrue(AppUpdate.isNewer("26.11.0", than: "26.10.9"))
        XCTAssertTrue(AppUpdate.isNewer("26.10.10", than: "26.10.9"), "numeric, not text order")
        XCTAssertFalse(AppUpdate.isNewer("26.10.0", than: "26.10.0"))
        XCTAssertFalse(AppUpdate.isNewer("26.9.0", than: "26.10.0"))
        XCTAssertFalse(AppUpdate.isNewer("26.10.1", than: "0.0.0"), "a development build is never offered one")
        XCTAssertFalse(AppUpdate.isNewer("nightly", than: "26.10.0"))
    }

    func testChecksAboutOnceADayAndRetriesHourly() {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        XCTAssertTrue(AppUpdate.isCheckDue(lastCheck: nil, lastAttempt: nil, now: now))
        XCTAssertFalse(AppUpdate.isCheckDue(lastCheck: ago(1), lastAttempt: ago(1), now: now))
        XCTAssertTrue(AppUpdate.isCheckDue(lastCheck: ago(21), lastAttempt: ago(21), now: now))
        XCTAssertTrue(AppUpdate.isCheckDue(lastCheck: ago(-1), lastAttempt: ago(-1), now: now), "clock moved back")
        // Offline: the checks fail, and the next try waits an hour, not one poll.
        XCTAssertFalse(AppUpdate.isCheckDue(lastCheck: nil, lastAttempt: ago(0.01), now: now))
        XCTAssertFalse(AppUpdate.isCheckDue(lastCheck: ago(30), lastAttempt: ago(0.5), now: now))
        XCTAssertTrue(AppUpdate.isCheckDue(lastCheck: ago(30), lastAttempt: ago(1.1), now: now))
    }

    func testFindsTheZipsChecksum() {
        let sums = """
        AAAA1111  Slipstream-Menubar.app.26.10.1.zip
        bbbb2222  Slipstream-Menubar.app.26.10.1.dmg
        """
        XCTAssertEqual(AppUpdate.checksum(for: "Slipstream-Menubar.app.26.10.1.zip", in: sums), "aaaa1111")
        XCTAssertNil(AppUpdate.checksum(for: "Slipstream-Menubar.app.26.10.2.zip", in: sums))
    }

    func testSwapPutsTheNewBundleInPlaceOrRestoresTheOld() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("It's an App.app")  // a quote, as a path may have
        let staged = root.appendingPathComponent("staged/New.app")
        let backup = root.appendingPathComponent("staged/previous.app")
        for (folder, marker) in [(app, "old"), (staged, "new")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try marker.write(to: folder.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try shell(AppUpdate.swapCommand(app: app, staged: staged, backup: backup)), 0)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("marker"), encoding: .utf8), "old")

        // A staged bundle that is gone: the old one must come back.
        try FileManager.default.removeItem(at: backup)
        let missing = root.appendingPathComponent("staged/Missing.app")
        XCTAssertNotEqual(try shell(AppUpdate.swapCommand(app: app, staged: missing, backup: backup)), 0)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8), "new")
    }

    private func shell(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
