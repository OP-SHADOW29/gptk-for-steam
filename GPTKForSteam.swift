// GPTK for Steam: installs Apple Game Porting Toolkit versions as Steam compatibility tools,
// gives each one the Wine core it needs, connects games to Steam (client + cloud saves),
// and turns on Steam Play either in the installed Steam or in a second copy of Steam.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appending(path: "Library/Application Support/gptk-steam")
    static let backup = support.appending(path: "backup")
    static let bridge = support.appending(path: "bridge")
    static let cachedDylib = support.appending(path: "notproton.dylib")
    static let tools = home.appending(path: "Library/Application Support/Steam/compatibilitytools.d")
    static let defaultSlot = tools.appending(path: "notproton")
    static let notProtonSupport = home.appending(path: "Library/Application Support/notproton")
    static let notProtonBridge = notProtonSupport.appending(path: "bridge")
    static let macSteamClient = home.appending(path: "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS")
    // Files shipped inside this app.
    static func bundled(_ path: String) -> URL? {
        guard let u = Bundle.main.resourceURL?.appending(path: path), exists(u) else { return nil }
        return u
    }
    static let gameHubWines = home.appending(path: "Library/Application Support/com.gamemac.www/wine-engine/containers/wine_installations")
    static let steam = URL(filePath: "/Applications/Steam.app")
    static let secondSteam = URL(filePath: "/Applications/Steam (GPTK).app")
    static let downloads = home.appending(path: "Downloads")
    static let dylibName = "notproton.dylib"
    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path(percentEncoded: false)) }
}

// MARK: - Shell

struct ShellError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@discardableResult
func sh(_ exe: String, _ args: [String], env: [String: String]? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(filePath: exe)
    p.arguments = args
    if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self)
    if p.terminationStatus != 0 {
        throw ShellError(message: "\(URL(filePath: exe).lastPathComponent) failed: \(out.suffix(400))")
    }
    return out
}

// APFS clone where possible, so copies of Wine cost no disk space.
func cloneTree(_ src: URL, _ dst: URL) throws {
    do { try sh("/bin/cp", ["-Rc", src.path, dst.path]) }
    catch { try sh("/usr/bin/ditto", [src.path, dst.path]) }
}

func fileContains(_ url: URL, _ needle: String) -> Bool {
    guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
    return d.range(of: Data(needle.utf8)) != nil
}

// MARK: - Wine cores

// Each GPTK version is built for a different Wine interface:
// GPTK 3 calls __wine_unix_call (Wine 7.7, Apple's GPTK Wine).
// GPTK 4 calls __wine_unix_call_dispatcher and needs winemac's macdrv_functions table,
// which only a GPTK-patched Wine 11 has. A Proton-based one also carries the Steam bridge loader.
enum Core: String, CaseIterable, Identifiable {
    case wine77 = "wine"
    case wine11 = "wine-11-gptk"
    var id: String { rawValue }
    var dir: URL { Paths.support.appending(path: rawValue) }
    var title: String { self == .wine77 ? "Wine 7.7 (for GPTK 3)" : "Wine 11, GPTK-patched (for GPTK 4)" }
    var installed: Bool {
        Paths.exists(dir.appending(path: "bin/wine64")) || Paths.exists(dir.appending(path: "bin/wine"))
    }
    static func forGPTK(major: Int) -> Core { major >= 4 ? .wine11 : .wine77 }

    static let wine77URL = "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz"
    static let wine77File = "game-porting-toolkit-3.0-3.tar.xz (239 MB)"

    static func downloadWine77(log: (String) -> Void) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "gptk-steam-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let archive = tmp.appending(path: "wine.tar.xz")
        log("Downloading Wine 7.7 core (239 MB)…")
        try sh("/usr/bin/curl", ["-fsSL", "-o", archive.path, wine77URL])
        log("Unpacking the wine folder only…")
        let inner = "Game Porting Toolkit.app/Contents/Resources/wine"
        try sh("/usr/bin/tar", ["-xJf", archive.path, "-C", tmp.path, inner])
        try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? fm.removeItem(at: Core.wine77.dir)
        try fm.moveItem(at: tmp.appending(path: inner), to: Core.wine77.dir)
        log("Wine 7.7 core installed.")
    }

    // A Wine 11 that GPTK 4 can run on: it must export macdrv_functions from winemac.so.
    static func isGPTKWine11(_ root: URL) -> Bool {
        let unix = root.appending(path: "lib/wine/x86_64-unix")
        return Paths.exists(root.appending(path: "bin/wine"))
            && fileContains(unix.appending(path: "winemac.so"), "_macdrv_functions")
            && fileContains(root.appending(path: "lib/wine/x86_64-windows/ntdll.dll"), "__wine_unix_call_dispatcher")
    }

    // The GPTK-patched, Proton-based Wine 11 that ships inside this app (from GameHub; see its NOTICE.txt).
    static var bundledWine11: URL? {
        guard let r = Bundle.main.resourceURL?.appending(path: "wine-11-gptk"), isGPTKWine11(r) else { return nil }
        return r
    }

    // GameHub ships a GPTK-patched, Proton-based Wine 11. Use the newest one it has.
    static func findGameHubWine11() -> URL? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.gameHubWines, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return dirs.filter(isGPTKWine11).sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.first
    }

    static func importWine11(from root: URL, log: (String) -> Void) throws {
        guard isGPTKWine11(root) else {
            throw ShellError(message: "\(root.lastPathComponent) isn't a GPTK-patched Wine 11 (winemac.so has no macdrv_functions).")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let tmp = Paths.support.appending(path: "wine-11-gptk.new")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for d in ["bin", "lib", "share"] where Paths.exists(root.appending(path: d)) {
            log("Copying \(d)…")
            try cloneTree(root.appending(path: d), tmp.appending(path: d))
        }
        for f in ["NOTICE.txt", "LICENSE-LGPL-2.1.txt"] where Paths.exists(root.appending(path: f)) {
            try fm.copyItem(at: root.appending(path: f), to: tmp.appending(path: f))
        }
        try "Copied from \(root.path) on \(Date())\n".write(to: tmp.appending(path: "SOURCE.txt"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: Core.wine11.dir)
        try fm.moveItem(at: tmp, to: Core.wine11.dir)
        log("Wine 11 core installed.")
    }
}

// MARK: - Steam bridge

// Valve's Windows Steam files plus the lsteamclient bridge. On a Proton-based Wine the loader
// swaps lsteamclient in whenever a game loads Valve's steamclient, so steam_api, DRM checks and
// Steam Cloud behave as on Windows.
enum Bridge {
    static let files = ["steamclient64.dll", "steamclient.dll", "tier0_s64.dll", "vstdlib_s64.dll", "steam.exe",
                        "x86_64-windows/lsteamclient.dll", "i386-windows/lsteamclient.dll", "x86_64-unix/lsteamclient.so"]

    static var ready: Bool { files.allSatisfy { Paths.exists(Paths.bridge.appending(path: $0)) } }
    static var missing: [String] { files.filter { !Paths.exists(Paths.bridge.appending(path: $0)) } }

    // Where a good copy of each file can come from, best first. Valve's own files are never
    // shipped in this app: they come from the player's Steam or from Valve's servers.
    static func localSources(_ f: String) -> [URL] {
        var out: [URL] = []
        switch f {
        case "steamclient64.dll", "steamclient.dll":
            out.append(Paths.macSteamClient.appending(path: "legacycompat/\(f)"))
        case "tier0_s64.dll", "vstdlib_s64.dll":
            break
        default:
            if let b = Paths.bundled("notproton/bridge/\(f)") { out.append(b) }
        }
        out.append(Paths.notProtonBridge.appending(path: f))
        return out.filter { Paths.exists($0) }
    }

    static func restore(log: (String) -> Void) throws {
        let fm = FileManager.default
        var needValve: [String] = []
        for f in missing {
            let dst = Paths.bridge.appending(path: f)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let src = localSources(f).first {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            } else {
                needValve.append(f)
            }
        }
        if !needValve.isEmpty {
            let got = try Valve.fetchWin64(needValve, log: log)
            for (f, url) in got {
                let dst = Paths.bridge.appending(path: f)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: url, to: dst)
            }
        }
        let still = missing
        if !still.isEmpty { throw ShellError(message: "Couldn't restore: \(still.joined(separator: ", "))") }
        log("Steam connection files restored.")
    }
}

// Valve's public client packages, pinned by hash (the same ones NotProton uses).
enum Valve {
    static let bases = ["https://client-update.akamai.steamstatic.com", "https://steamcdn-a.akamaihd.net/client",
                        "https://media.steampowered.com/client"]
    static let win64Package = "bins_win64.zip.36f5d9202e79ab2aa3e3c5902e84bbd799d31fc0"
    static let win64SHA = "93f5b6bea0267fd85dc8cc823fdab5c5fb55d7f3a1deab0598acefef0e133bce"
    static let fileSHA = ["tier0_s64.dll": "30f7bb8d9b86006852493c26124ba253bd9e7ffd40a8b3c7254f86a9032c3be3",
                          "vstdlib_s64.dll": "99efb4c2ad47f90c803b5ee0bd6424916b28facb9fa2568845b1b1f58a36062a"]

    static func sha256(_ u: URL) -> String? {
        (try? sh("/usr/bin/shasum", ["-a", "256", u.path]))?.split(separator: " ").first.map(String.init)
    }

    static func fetchWin64(_ wanted: [String], log: (String) -> Void) throws -> [String: URL] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "gptk-valve-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appending(path: "bins_win64.zip")
        log("Downloading Valve's Windows Steam files…")
        var ok = false
        for base in bases {
            if (try? sh("/usr/bin/curl", ["-fsSL", "-o", zip.path, "\(base)/\(win64Package)"])) != nil, sha256(zip) == win64SHA {
                ok = true; break
            }
        }
        guard ok else { throw ShellError(message: "Couldn't download Valve's Windows Steam files.") }
        let out = tmp.appending(path: "x")
        try sh("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        var got: [String: URL] = [:]
        for f in wanted {
            let u = out.appending(path: f)
            if let want = fileSHA[f], sha256(u) == want { got[f] = u }
        }
        return got
    }
}

// NotProton's Steam Play enabler reads these from its own folder.
enum NotProtonSupport {
    static let needed = ["signatures", "appinfo", "iconmaker", "overlay-shim.dylib", "dylib.version"]
    static var missing: [String] { needed.filter { !Paths.exists(Paths.notProtonSupport.appending(path: $0)) } }

    static func restore(log: (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.notProtonSupport, withIntermediateDirectories: true)
        for f in missing {
            guard let src = Paths.bundled("notproton/support/\(f)") else { continue }
            try fm.copyItem(at: src, to: Paths.notProtonSupport.appending(path: f))
        }
        if missing.isEmpty { log("Steam Play support files restored.") }
        else { throw ShellError(message: "Couldn't restore Steam Play support files: \(missing.joined(separator: ", "))") }
    }
}

// Valve's official Mac installer, for when Steam itself is gone.
enum SteamInstaller {
    static let dmg = "https://cdn.akamai.steamstatic.com/client/installer/steam.dmg"

    static func install(log: (String) -> Void) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "gptk-steam-dmg-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let file = tmp.appending(path: "steam.dmg")
        log("Downloading Steam from Valve…")
        try sh("/usr/bin/curl", ["-fsSL", "-o", file.path, dmg])
        // stdin is closed, so a disk image that asks to accept a license fails here
        // instead of being accepted silently.
        let mp = try Tools.attach(file)
        defer { Tools.detach(mp) }
        guard let app = (try fm.contentsOfDirectory(at: mp, includingPropertiesForKeys: nil)).first(where: { $0.lastPathComponent == "Steam.app" }) else {
            throw ShellError(message: "Valve's installer had no Steam.app. Install Steam from steampowered.com.")
        }
        // Only install what macOS itself accepts as Valve's signed, notarized app.
        guard (try? sh("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])) != nil else {
            throw ShellError(message: "The downloaded Steam didn't pass macOS's checks. Install Steam from steampowered.com.")
        }
        try sh("/usr/bin/ditto", [app.path, Paths.steam.path])
        log("Steam installed in Applications.")
    }
}

// MARK: - Steam bundle state

enum SteamState: Equatable {
    case missing, clean, modified
}

enum SteamBundle {
    static func plist(_ app: URL) -> URL { app.appending(path: "Contents/Info.plist") }
    static func dylib(_ app: URL) -> URL { app.appending(path: "Contents/MacOS/\(Paths.dylibName)") }

    static func read(_ app: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: plist(app)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    static func state(_ app: URL) -> SteamState {
        guard Paths.exists(app), let dict = read(app) else { return .missing }
        let env = dict["LSEnvironment"] as? [String: Any] ?? [:]
        let insert = env["DYLD_INSERT_LIBRARIES"] as? String ?? ""
        return insert.contains(Paths.dylibName) && Paths.exists(dylib(app)) ? .modified : .clean
    }

    static var isRunning: Bool {
        (try? sh("/usr/bin/pgrep", ["-x", "steam_osx"])) != nil
    }

    // The Steam Play enabler is NotProton's library. Keep a copy so it survives Steam changes.
    static func enablerSource() -> URL? {
        for app in [Paths.steam, Paths.secondSteam] where Paths.exists(dylib(app)) {
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: Paths.cachedDylib)
            try? FileManager.default.copyItem(at: dylib(app), to: Paths.cachedDylib)
            break
        }
        if Paths.exists(Paths.cachedDylib) { return Paths.cachedDylib }
        return Paths.bundled("notproton/\(Paths.dylibName)")
    }

    static func write(_ dict: [String: Any], _ app: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plist(app), options: .atomic)
    }

    static func inject(_ app: URL) throws {
        guard let src = enablerSource() else {
            throw ShellError(message: "The Steam Play enabler (NotProton) isn't on this Mac. Install NotProton first: brew install --cask notprotonnot/notproton/notproton")
        }
        let target = dylib(app)
        if src.standardizedFileURL != target.standardizedFileURL {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: src, to: target)
        }
        guard var dict = read(app) else { throw ShellError(message: "Can't read \(plist(app).path)") }
        var env = dict["LSEnvironment"] as? [String: Any] ?? [:]
        env["DYLD_INSERT_LIBRARIES"] = target.path(percentEncoded: false)
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        dict["LSEnvironment"] = env
        try write(dict, app)
        try resign(app)
        register(app)
    }

    static func uninject(_ app: URL) throws {
        guard var dict = read(app) else { return }
        var env = dict["LSEnvironment"] as? [String: Any] ?? [:]
        env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        dict["LSEnvironment"] = env.isEmpty ? nil : env
        try write(dict, app)
        try? FileManager.default.removeItem(at: dylib(app))
        try resign(app)
        register(app)
    }

    static func makeSecondCopy() throws {
        if Paths.exists(Paths.secondSteam) { try FileManager.default.removeItem(at: Paths.secondSteam) }
        try sh("/bin/cp", ["-Rc", Paths.steam.path, Paths.secondSteam.path])
        guard var dict = read(Paths.secondSteam) else { throw ShellError(message: "Copy failed") }
        dict["CFBundleName"] = "Steam (GPTK)"
        dict["CFBundleDisplayName"] = "Steam (GPTK)"
        try write(dict, Paths.secondSteam)
        try inject(Paths.secondSteam)
    }

    // Editing Info.plist breaks the bundle's signature, and macOS then refuses to open
    // a bundle it hasn't seen before (error -54). A local ad-hoc signature fixes that.
    static func resign(_ app: URL) throws {
        try sh("/usr/bin/codesign", ["--force", "--deep", "--preserve-metadata=entitlements", "-s", "-", app.path])
    }

    static func register(_ app: URL) {
        let ls = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try? sh(ls, ["-f", app.path])
    }
}

// MARK: - Tools

struct InstalledTool: Identifiable {
    let dir: String        // folder in compatibilitytools.d
    let display: String
    let isDefault: Bool
    var id: String { dir }
}

enum Tools {
    static let slotMarker = "gptk-slot"   // holds the tool's own name while it sits in the default slot

    static func display(of dir: URL) -> String? {
        guard let text = try? String(contentsOf: dir.appending(path: "compatibilitytool.vdf"), encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n")
            .first { $0.contains("display_name") }?
            .components(separatedBy: "\"").dropLast().last
    }

    static func installed() -> [InstalledTool] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.tools.path)) ?? []
        return names.sorted().compactMap { n in
            let dir = Paths.tools.appending(path: n)
            let isSlot = n == "notproton" && slotState() != .crossOver
            guard n.hasPrefix("gptk") || isSlot, let shown = display(of: dir) else { return nil }
            return InstalledTool(dir: n, display: shown, isDefault: isSlot)
        }
    }

    // The enabler's own default-tool slot, which windows-only games get when nothing else is chosen.
    enum SlotState: Equatable { case empty, crossOver, gptk(String) }
    static func slotState() -> SlotState {
        guard Paths.exists(Paths.defaultSlot) else { return .empty }
        if let name = try? String(contentsOf: Paths.defaultSlot.appending(path: slotMarker), encoding: .utf8) {
            return .gptk(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Set up by hand without the marker: a GPTK name in the slot still counts as ours.
        if let shown = display(of: Paths.defaultSlot), shown.hasPrefix("GPTK"), let m = major(in: shown) {
            return .gptk("gptk\(m)")
        }
        return .crossOver
    }

    // GPTK's graphics files ship inside this app (Apple's redistributables, shared under
    // Apple's GPTK license for non-commercial use; the license files are in gptk/LICENSES).
    struct Source {
        enum Kind { case folder(URL) }
        let kind: Kind
        let major: Int
        let label: String
    }

    // "Game_Porting_Toolkit_4.0_beta_3.dmg", "Evaluation_environment_..._3.0.dmg", "gptk-4.0-2" -> 4, 3, 4
    static func major(in name: String) -> Int? {
        for token in name.split(whereSeparator: { !$0.isNumber && $0 != "." }) where token.contains(".") {
            if let m = Int(token.split(separator: ".").first ?? ""), (1...20).contains(m) { return m }
        }
        return nil
    }

    static func sources() -> [Int: Source] {
        guard let root = Bundle.main.resourceURL?.appending(path: "gptk") else { return [:] }
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter {
            Paths.exists($0.appending(path: "wine/x86_64-windows/d3d12.dll"))
                && Paths.exists($0.appending(path: "external/libd3dshared.dylib"))
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var best: [Int: Source] = [:]
        for d in dirs {
            if let m = major(in: d.lastPathComponent), best[m] == nil {
                best[m] = Source(kind: .folder(d), major: m, label: "GPTK \(d.lastPathComponent) (included)")
            }
        }
        return best
    }

    // Major versions already set up, including the one sitting in the default slot.
    static func installedMajors() -> Set<Int> {
        var out = Set<Int>()
        for t in installed() {
            let name = t.isDefault ? (slotName() ?? "") : t.dir
            if let m = Int(name.replacingOccurrences(of: "gptk", with: "")) { out.insert(m) }
        }
        return out
    }

    static func slotName() -> String? {
        if case .gptk(let n) = slotState() { return n }
        return nil
    }

    static func attach(_ dmg: URL) throws -> URL {
        let out = try sh("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        guard let d = out.data(using: .utf8),
              let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let ents = pl["system-entities"] as? [[String: Any]],
              let mp = ents.compactMap({ $0["mount-point"] as? String }).first
        else { throw ShellError(message: "Couldn't open \(dmg.lastPathComponent)") }
        return URL(filePath: mp)
    }

    static func detach(_ mp: URL) { _ = try? sh("/usr/bin/hdiutil", ["detach", "-quiet", mp.path]) }

    static func lock(_ dir: URL, _ on: Bool) {
        let files = ["compatibilitytool.vdf", "toolmanifest.vdf", "run"].map { dir.appending(path: $0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { return }
        _ = try? sh("/usr/bin/chflags", [on ? "uchg" : "nouchg"] + files)
    }

    static func writeDeclaration(_ dir: URL, key: String, display: String) throws {
        let vdf = """
        "compatibilitytools"
        {
          "compat_tools"
          {
            "\(key)"
            {
              "install_path" "."
              "display_name" "\(display)"
              "from_oslist" "windows"
              "to_oslist" "macos"
            }
          }
        }

        """
        try vdf.write(to: dir.appending(path: "compatibilitytool.vdf"), atomically: false, encoding: .utf8)
        let manifest = "\"manifest\"\n{\n  \"version\" \"2\"\n  \"commandline\" \"/run %verb%\"\n}\n"
        try manifest.write(to: dir.appending(path: "toolmanifest.vdf"), atomically: false, encoding: .utf8)
    }

    static func writeRun(_ dir: URL) throws {
        guard let run = Bundle.main.url(forResource: "run", withExtension: nil) else {
            throw ShellError(message: "The launch script is missing from this app.")
        }
        let dst = dir.appending(path: "run")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: run, to: dst)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
    }

    // Installs one GPTK version as a Steam tool. A DMG may be the full Game_Porting_Toolkit
    // image (with the evaluation image inside) or the evaluation image itself.
    static func install(_ src: Source, log: (String) -> Void) throws -> String {
        switch src.kind {
        case .folder(let dir):
            return try installRedist(dir, version: dir.lastPathComponent, major: src.major, log: log)
        }
    }

    // `redist` holds external/ and wine/ (Apple's redist/lib layout).
    static func installRedist(_ redist: URL, version: String, major: Int, log: (String) -> Void) throws -> String {
        guard Paths.exists(redist.appending(path: "external")), Paths.exists(redist.appending(path: "wine")) else {
            throw ShellError(message: "No GPTK graphics files in \(redist.path)")
        }
        let name = "gptk\(major)"
        let core = Core.forGPTK(major: major)
        let display = "GPTK \(version)"

        // A version that already sits in the default slot is updated in place.
        let inSlot = slotState() == .gptk(name)
        let dir = inSlot ? Paths.defaultSlot : Paths.tools.appending(path: name)
        log("Installing \(display) (Wine core: \(core.rawValue))")

        let fm = FileManager.default
        if inSlot { lock(dir, false) } else { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: dir.appending(path: "gptk"))
        try sh("/usr/bin/ditto", [redist.path, dir.appending(path: "gptk").path])
        try writeDeclaration(dir, key: inSlot ? "notproton" : name, display: display)
        try writeRun(dir)
        try core.rawValue.write(to: dir.appending(path: "core"), atomically: true, encoding: .utf8)
        try "pfx".write(to: dir.appending(path: "prefix"), atomically: true, encoding: .utf8)
        let marker = dir.appending(path: "steam-bridge")
        if core == .wine11 {
            try "Proton-style Steam bridge (lsteamclient)\n".write(to: marker, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: marker)
        }
        if inSlot { lock(dir, true) }
        return display
    }

    // Moves a tool into the enabler's default slot, replacing CrossOver Preview. The files the
    // enabler rewrites on every Steam start are locked so it can't put CrossOver back.
    static func makeDefault(_ name: String, log: (String) -> Void) throws {
        let fm = FileManager.default
        let src = Paths.tools.appending(path: name)
        guard Paths.exists(src), let display = display(of: src) else { throw ShellError(message: "\(name) isn't installed.") }
        try fm.createDirectory(at: Paths.backup, withIntermediateDirectories: true)

        switch slotState() {
        case .crossOver:
            let keep = Paths.backup.appending(path: "notproton-crossover-tool")
            if !Paths.exists(keep) { try fm.copyItem(at: Paths.defaultSlot, to: keep) }
            try fm.removeItem(at: Paths.defaultSlot)
        case .gptk(let old):
            // Put the current default back under its own name.
            lock(Paths.defaultSlot, false)
            let back = Paths.tools.appending(path: old)
            try? fm.removeItem(at: back)
            try fm.moveItem(at: Paths.defaultSlot, to: back)
            try? fm.removeItem(at: back.appending(path: slotMarker))
            if let d = Tools.display(of: back) { try writeDeclaration(back, key: old, display: d) }
            log("\(old) is no longer the default.")
        case .empty:
            break
        }

        lock(src, false)
        try fm.moveItem(at: src, to: Paths.defaultSlot)
        try writeDeclaration(Paths.defaultSlot, key: "notproton", display: display)
        try name.write(to: Paths.defaultSlot.appending(path: slotMarker), atomically: true, encoding: .utf8)
        lock(Paths.defaultSlot, true)
        log("\(display) is now the default for Windows games.")
    }

    static func remove(_ tool: InstalledTool) throws {
        let dir = Paths.tools.appending(path: tool.dir)
        _ = try? sh("/usr/bin/chflags", ["-R", "nouchg", dir.path])
        try FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Setup

// Everything Set Up does, in order. Each step skips what is already in place, so running it
// again only repairs what is missing and never touches a working tool.
enum Setup {
    static func run(log: (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let sources = Tools.sources()
        var have = Tools.installedMajors()

        // Wine cores
        if !Core.wine11.installed {
            if let root = Core.bundledWine11 ?? Core.findGameHubWine11() {
                try Core.importWine11(from: root, log: log)
            } else {
                log("GPTK 4 needs a GPTK-patched Wine 11, and this copy of the app doesn't include one.")
            }
        }
        let wantsGPTK3 = have.contains(3) || sources[3] != nil
        if wantsGPTK3 && !Core.wine77.installed {
            try Core.downloadWine77(log: log)
        }

        // Steam client and cloud saves
        if !Bridge.ready { try Bridge.restore(log: log) }
        if !NotProtonSupport.missing.isEmpty { try NotProtonSupport.restore(log: log) }

        // GPTK versions
        for major in [3, 4] where !have.contains(major) {
            guard let src = sources[major] else {
                log("This copy of the app doesn't include GPTK \(major).")
                continue
            }
            if !Core.forGPTK(major: major).installed {
                log("Skipping GPTK \(major): its Wine core isn't installed.")
                continue
            }
            log("Using \(src.label)")
            let shown = try Tools.install(src, log: log)
            have.insert(major)
            log("\(shown) added.")
        }

        // Default tool: GPTK 4 replaces CrossOver Preview.
        switch Tools.slotState() {
        case .crossOver, .empty:
            if have.contains(4), Paths.exists(Paths.tools.appending(path: "gptk4")) {
                try Tools.makeDefault("gptk4", log: log)
            } else if have.contains(3), Paths.exists(Paths.tools.appending(path: "gptk3")) {
                try Tools.makeDefault("gptk3", log: log)
            }
        case .gptk:
            break
        }
    }

    static let modeFile = Paths.support.appending(path: "steam-mode")

    // Rebuilds whatever is missing and replaces whatever is broken, from the copies inside this
    // app, the player's Steam, or Valve's servers. Each step carries on if another one fails.
    static func repair(log: @escaping (String) -> Void) throws {
        let before = issues()
        var failures: [String] = []
        func step(_ what: String, _ body: () throws -> Void) {
            do { try body() } catch { failures.append("\(what): \(error.localizedDescription)"); log("\(what) failed: \(error.localizedDescription)") }
        }

        // 1. Steam itself.
        if !Paths.exists(Paths.steam) { step("Reinstalling Steam") { try SteamInstaller.install(log: log) } }

        // 2. Steam Play's enabler and the files it reads.
        if !NotProtonSupport.missing.isEmpty { step("Restoring Steam Play files") { try NotProtonSupport.restore(log: log) } }

        // 3. Steam connection files.
        if !Bridge.ready { step("Restoring Steam connection files") { try Bridge.restore(log: log) } }

        // 4. GPTK tools: replace any that are broken, then add any that are missing.
        for t in Tools.installed() {
            let dir = Paths.tools.appending(path: t.dir)
            let name = t.isDefault ? (Tools.slotName() ?? t.dir) : t.dir
            guard let major = Int(name.replacingOccurrences(of: "gptk", with: "")) else { continue }
            let broken = !Paths.exists(dir.appending(path: "gptk/external/libd3dshared.dylib"))
                || !Paths.exists(dir.appending(path: "gptk/wine/x86_64-windows/d3d12.dll"))
                || !Paths.exists(dir.appending(path: "compatibilitytool.vdf"))
                || !Paths.exists(dir.appending(path: "core"))
            if broken, let src = Tools.sources()[major] {
                step("Replacing \(t.display)") { _ = try Tools.install(src, log: log) }
                continue
            }
            if !FileManager.default.isExecutableFile(atPath: dir.appending(path: "run").path) {
                step("Restoring \(t.display)'s launcher") {
                    Tools.lock(dir, false); try Tools.writeRun(dir); if t.isDefault { Tools.lock(dir, true) }
                }
            }
            let files = dir.appending(path: "files")
            if Paths.exists(files) && !(Paths.exists(files.appending(path: "bin/wine")) || Paths.exists(files.appending(path: "bin/wine64"))) {
                try? FileManager.default.removeItem(at: files.appending(path: ".gptk-stamp"))
                log("\(t.display): its Wine copy will be rebuilt on the next launch.")
            }
        }
        // Wine cores, missing GPTK versions and the default tool (what Set Up does).
        step("Setting up missing pieces") { try run(log: log) }

        // 5. The default tool must say GPTK and stay locked.
        if let name = Tools.slotName() {
            let slot = Paths.defaultSlot
            if !(Tools.display(of: slot)?.hasPrefix("GPTK") ?? false), let m = Int(name.replacingOccurrences(of: "gptk", with: "")),
               let src = Tools.sources()[m] {
                step("Putting GPTK \(m) back as the default") { _ = try Tools.install(src, log: log) }
            }
            Tools.lock(slot, true)
        }

        // 6. The Steam that carries Steam Play: recreate it if it's gone, re-enable, re-sign.
        let mode = (try? String(contentsOf: modeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == "second" || (mode == nil && Paths.exists(Paths.secondSteam)) {
            if !Paths.exists(Paths.secondSteam) {
                step("Recreating Steam (GPTK)") {
                    guard Paths.exists(Paths.steam) else { throw ShellError(message: "Steam isn't installed.") }
                    try SteamBundle.makeSecondCopy()
                    log("Steam (GPTK) recreated in Applications.")
                }
            }
            fixSteamPlay(Paths.secondSteam, step: step, log: log)
        } else if mode == "installed" {
            fixSteamPlay(Paths.steam, step: step, log: log)
        }

        let after = issues()
        let fixed = before.filter { !after.contains($0) }.count
        if after.isEmpty {
            log(before.isEmpty ? "Nothing needed fixing." : "Fixed everything (\(fixed) issue\(fixed == 1 ? "" : "s")).")
        } else {
            log("Still not fixed: " + after.joined(separator: " "))
        }
        if SteamBundle.isRunning && !before.isEmpty { log("Quit Steam (⌘Q) and open it again so it picks up the repairs.") }
    }

    private static func fixSteamPlay(_ app: URL, step: (String, () throws -> Void) -> Void, log: @escaping (String) -> Void) {
        guard Paths.exists(app) else { return }
        let name = app.deletingPathExtension().lastPathComponent
        if SteamBundle.state(app) != .modified {
            step("Turning Steam Play back on in \(name)") { try SteamBundle.inject(app); log("Steam Play is on in \(name).") }
        } else if (try? sh("/usr/bin/codesign", ["--verify", app.path])) == nil {
            step("Re-signing \(name)") { try SteamBundle.resign(app); log("Re-signed \(name) so macOS opens it.") }
        }
    }

    static var isSetUp: Bool { Paths.exists(modeFile) || !Tools.installed().isEmpty }

    // Which Steam the player chose to carry Steam Play.
    static var steamPlayApp: URL? {
        let mode = (try? String(contentsOf: modeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == "installed" { return Paths.steam }
        if mode == "second" || Paths.exists(Paths.secondSteam) { return Paths.secondSteam }
        return SteamBundle.state(Paths.steam) == .modified ? Paths.steam : nil
    }

    // Problems a player would hit: missing pieces, broken copies, or a Steam that won't open.
    static func issues() -> [String] {
        guard isSetUp else { return [] }
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }
        let fm = FileManager.default
        let tools = Tools.installed()
        let majors = Tools.installedMajors()

        if !Paths.exists(Paths.steam) { add("Steam isn't in Applications.") }
        if !NotProtonSupport.missing.isEmpty { add("Files Steam Play needs are missing.") }
        for m in [3, 4] where !majors.contains(m) && sourcesHave(m) { add("GPTK \(m) is missing from Steam's menu.") }

        for t in tools {
            let dir = Paths.tools.appending(path: t.dir)
            let coreName = (try? String(contentsOf: dir.appending(path: "core"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "wine"
            let core = Paths.support.appending(path: coreName)
            if !(Paths.exists(core.appending(path: "bin/wine")) || Paths.exists(core.appending(path: "bin/wine64"))) {
                add("\(t.display) is missing its Wine.")
            }
            if !fm.isExecutableFile(atPath: dir.appending(path: "run").path) { add("\(t.display) is missing its launcher.") }
            if !Paths.exists(dir.appending(path: "gptk/external/libd3dshared.dylib")) { add("\(t.display) is missing its GPTK files.") }
            let files = dir.appending(path: "files")
            if Paths.exists(files) && !(Paths.exists(files.appending(path: "bin/wine")) || Paths.exists(files.appending(path: "bin/wine64"))) {
                add("\(t.display)'s Wine copy is broken.")
            }
            if Paths.exists(dir.appending(path: "steam-bridge")) && !Bridge.ready { add("Files games need to see Steam are missing.") }
        }

        // The default slot must stay GPTK and stay locked, or NotProton writes its own tool back.
        if !tools.isEmpty {
            switch Tools.slotState() {
            case .crossOver, .empty:
                add("Windows games no longer default to GPTK.")
            case .gptk:
                let vdf = Paths.defaultSlot.appending(path: "compatibilitytool.vdf")
                let locked = (try? fm.attributesOfItem(atPath: vdf.path)[.immutable] as? Bool) ?? false
                if !(Tools.display(of: Paths.defaultSlot)?.hasPrefix("GPTK") ?? false) { add("Windows games no longer default to GPTK.") }
                else if !locked { add("The default GPTK tool can be overwritten by NotProton.") }
            }
        }

        // The Steam that carries Steam Play: present, enabled, and signed so macOS opens it.
        if let app = steamPlayApp {
            let name = app.deletingPathExtension().lastPathComponent
            if !Paths.exists(app) { add("\(name) is missing.") }
            else if SteamBundle.state(app) != .modified { add("Steam Play is off in \(name).") }
            else if (try? sh("/usr/bin/codesign", ["--verify", app.path])) == nil { add("macOS may refuse to open \(name).") }
        } else {
            add("Steam Play is off.")
        }
        return out
    }

    private static func sourcesHave(_ major: Int) -> Bool { Tools.sources()[major] != nil }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var steamState: SteamState = .missing
    @Published var secondState: SteamState = .missing
    @Published var hasEnabler = false
    @Published var tools: [InstalledTool] = []
    @Published var slot: Tools.SlotState = .empty
    @Published var bridgeReady = false
    @Published var wine77 = false
    @Published var wine11 = false
    @Published var log: [String] = []
    @Published var busy = false
    @Published var askSteamMode = false
    @Published var error: String?
    @Published var health: Health = .checking

    enum Health: Equatable { case checking, notSetUp, ok, issues([String]) }

    enum SteamMode: String, Identifiable {
        case modifyInstalled, secondCopy, restoreOriginal
        var id: String { rawValue }
    }

    init() { refresh(); check() }

    // Runs off the main thread: verifying Steam's signature takes a moment.
    func check() {
        if case .issues = health {} else { health = .checking }
        Task.detached {
            let setUp = Setup.isSetUp
            let list = setUp ? Setup.issues() : []
            await MainActor.run {
                self.health = !setUp ? .notSetUp : list.isEmpty ? .ok : .issues(list)
            }
        }
    }

    // Check before opening, and report it if macOS won't open Steam.
    func openSteam() {
        guard let app = Setup.steamPlayApp else { check(); return }
        health = .checking
        Task.detached {
            let list = Setup.issues()
            await MainActor.run {
                if !list.isEmpty { self.health = .issues(list); return }
                self.health = .ok
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                    guard let err else { return }
                    Task { @MainActor in
                        self.health = .issues(["\(app.deletingPathExtension().lastPathComponent) didn't open: \(err.localizedDescription)"])
                    }
                }
            }
        }
    }

    func refresh() {
        steamState = SteamBundle.state(Paths.steam)
        secondState = SteamBundle.state(Paths.secondSteam)
        hasEnabler = SteamBundle.enablerSource() != nil
        tools = Tools.installed()
        slot = Tools.slotState()
        bridgeReady = Bridge.ready
        wine77 = Core.wine77.installed
        wine11 = Core.wine11.installed
    }

    var steamPlayOn: Bool { steamState == .modified || secondState == .modified }

    func tool(_ major: Int) -> InstalledTool? {
        tools.first { t in
            let name = t.isDefault ? (Tools.slotName() ?? "") : t.dir
            return name == "gptk\(major)"
        }
    }

    var allReady: Bool {
        steamPlayOn && tool(3) != nil && tool(4) != nil && bridgeReady && slot != .crossOver && slot != .empty
    }

    func say(_ s: String) { log.append(s) }

    func work(_ title: String, then: (@MainActor () -> Void)? = nil,
              _ job: @escaping @Sendable (@escaping @Sendable (String) -> Void) throws -> Void) {
        busy = true
        say("— \(title)")
        Task.detached {
            let logger: @Sendable (String) -> Void = { m in Task { @MainActor in self.say(m) } }
            do {
                try job(logger)
                await MainActor.run { self.busy = false; self.refresh(); self.check(); then?() }
            } catch {
                await MainActor.run {
                    self.say("Failed: \(error.localizedDescription)")
                    self.error = error.localizedDescription
                    self.busy = false
                    self.refresh()
                    self.check()
                }
            }
        }
    }

    func setUp() {
        work("Setting up", then: { [self] in
            if !steamPlayOn {
                if hasEnabler { askSteamMode = true }
                else { say("Steam Play needs the NotProton enabler. Install NotProton, then run Set Up again.") }
            } else {
                say("All set. Quit Steam completely (⌘Q) and open it again to see the GPTK versions.")
            }
        }) { log in try Setup.run(log: log) }
    }

    func repair() {
        work("Repairing") { log in try Setup.repair(log: log) }
    }

    func apply(_ mode: SteamMode) {
        guard !SteamBundle.isRunning else {
            error = "Quit Steam first (Steam ▸ Quit Steam), then press Set Up again."
            return
        }
        switch mode {
        case .modifyInstalled:
            work("Turning on Steam Play in your installed Steam") { log in
                try SteamBundle.inject(Paths.steam)
                try? "installed".write(to: Setup.modeFile, atomically: true, encoding: .utf8)
                log("Steam Play is on. Open Steam to see the GPTK versions.")
            }
        case .secondCopy:
            work("Creating Steam (GPTK)") { log in
                let wasModified = SteamBundle.state(Paths.steam) == .modified
                _ = SteamBundle.enablerSource()
                if wasModified {
                    try SteamBundle.uninject(Paths.steam)
                    log("Your original Steam is back to normal (Steam Play off).")
                }
                try SteamBundle.makeSecondCopy()
                try? "second".write(to: Setup.modeFile, atomically: true, encoding: .utf8)
                log("Open \"Steam (GPTK)\" from Applications to use GPTK.")
            }
        case .restoreOriginal:
            work("Restoring your installed Steam") { log in
                _ = SteamBundle.enablerSource()
                try SteamBundle.uninject(Paths.steam)
                log("Installed Steam no longer has Steam Play.")
            }
        }
    }
}

// MARK: - Warnings

enum Warning {
    static let modify = """
    What changes in your installed Steam:
    • Steam Play turns on for every game. Windows-only games become installable and use GPTK by default.
    • Mac games keep using their Mac version unless you choose a GPTK version for that game. The enabler removes itself before games start, so Mac games run as before.
    • Choosing GPTK for a game downloads its Windows version. Choosing No Compatibility Tool downloads the Mac version again.
    • Steam is re-signed locally instead of by Valve. Steam still opens, but a Steam update can switch Steam Play off again or, rarely, stop Steam from starting until the enabler is updated.
    • VAC games run through GPTK in insecure mode: no online matchmaking.
    • Modifying the Steam client is against Valve's terms in principle. Use at your own risk.
    """

    static let second = """
    What a second Steam means:
    • Your installed Steam stays (or goes back to) having Steam Play off. If it was modified before, only reinstalling Steam brings back Valve's own signature.
    • "Steam (GPTK)" in Applications is a modified copy with Steam Play on. It keeps Steam's icon and takes almost no extra space.
    • Both use the same account, settings and game library on disk, and only one can run at a time.
    • In your normal Steam, games you switched to GPTK may show "update required" or want to download their Mac version. Windows-only games installed with GPTK won't be playable there.
    • steam:// links and the Dock may open either copy.
    • The same Steam-update and VAC limits as modifying your installed Steam apply to the copy.
    """
}

// MARK: - UI

struct Row: View {
    let ok: Bool
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    @State var showLog = false

    var steamDetail: String {
        switch (m.steamState, m.secondState) {
        case (.missing, _): return "Steam isn't in Applications. Install Steam first."
        case (_, .modified) where m.steamState == .clean: return "On in \"Steam (GPTK)\". Your installed Steam is untouched."
        case (.modified, .modified): return "On in your installed Steam and in \"Steam (GPTK)\"."
        case (.modified, _): return "On in your installed Steam."
        default: return "Off. Set Up asks how to turn it on."
        }
    }

    func toolDetail(_ major: Int) -> String {
        guard let t = m.tool(major) else { return "Not set up yet." }
        let core = major >= 4 ? "Wine 11" : "Wine 7.7"
        return "\(t.display) on \(core)" + (t.isDefault ? ", the default for Windows games" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPTK for Steam").font(.largeTitle.bold())
                    Text("Adds GPTK 3 and GPTK 4 to Steam's compatibility menu.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Row(ok: m.steamPlayOn, title: "Steam Play", detail: steamDetail)
                    Row(ok: m.tool(3) != nil, title: "GPTK 3", detail: toolDetail(3))
                    Row(ok: m.tool(4) != nil, title: "GPTK 4", detail: toolDetail(4))
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 10) {
                if m.busy {
                    ProgressView(m.log.last ?? "Working…").controlSize(.small)
                } else {
                    switch m.health {
                    case .checking:
                        ProgressView("Checking…").controlSize(.small)
                    case .notSetUp:
                        Button { m.setUp() } label: {
                            Text("Set Up").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.10, green: 0.45, blue: 0.75))
                        .disabled(m.steamState == .missing)
                    case .ok:
                        HStack {
                            Label("All set", systemImage: "checkmark.seal.fill")
                                .font(.title3.bold()).foregroundStyle(.green)
                            Spacer()
                            if Setup.steamPlayApp == Paths.secondSteam {
                                Button("Open Steam (GPTK)") { m.openSteam() }.controlSize(.large)
                            }
                        }
                    case .issues(let list):
                        Label("Issue detected", systemImage: "exclamationmark.triangle.fill")
                            .font(.title3.bold()).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(list, id: \.self) { Text("• \($0)").font(.callout) }
                        }
                        Button { m.repair() } label: {
                            Text("Repair").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
            }
            if !m.wine77 && !m.busy {
                Text("The first Set Up downloads Wine 7.7 for GPTK 3 (about 240 MB) from Gcenx's free release on GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("After Set Up, quit Steam (⌘Q) and open it again. Games with a Mac version run natively; Windows-only games use GPTK 4. To change one game: right-click it ▸ Properties ▸ Compatibility ▸ choose GPTK 3, GPTK 4 or No Compatibility Tool.")
                .font(.callout).foregroundStyle(.secondary)

            DisclosureGroup(isExpanded: $showLog) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(m.log.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 140)
            } label: {
                Text("Details").foregroundStyle(.secondary)
            }
            .tint(.secondary)
            .focusEffectDisabled()
        }
        .padding(22)
        .frame(width: 600)
        .focusEffectDisabled()
        .sheet(isPresented: $m.askSteamMode) { SteamChoice(m: m) }
        .alert("Something went wrong", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(m.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !m.busy { m.refresh(); m.check() }
        }
    }
}

struct SteamChoice: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) var dismiss
    @State var pick: Model.SteamMode = .secondCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How should Steam show GPTK?").font(.title2.bold())
            Text("Steam only shows compatibility tools when Steam Play is on, which means modifying a copy of Steam. This can affect games that don't use GPTK, so choose how:")
                .font(.callout)

            Picker("", selection: $pick) {
                Text("Make a second Steam, keep mine unmodified (recommended)").tag(Model.SteamMode.secondCopy)
                Text("Modify my installed Steam").tag(Model.SteamMode.modifyInstalled)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            ScrollView {
                Text(pick == .modifyInstalled ? Warning.modify : Warning.second)
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if m.steamState == .modified && pick == .secondCopy {
                Label("Your installed Steam is already modified (by NotProton). This restores it and moves Steam Play to the copy.",
                      systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("I understand, continue") { dismiss(); m.apply(pick) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

@main
struct GPTKForSteamApp: App {
    init() {
        // `GPTK for Steam --check` prints what the window would show, for scripts and testing.
        if CommandLine.arguments.contains("--repair") {
            do { try Setup.repair(log: { print($0) }) } catch { print("Repair failed: \(error.localizedDescription)") }
            exit(Setup.issues().isEmpty ? 0 : 1)
        }
        if CommandLine.arguments.contains("--check") {
            let list = Setup.issues()
            print(!Setup.isSetUp ? "Not set up" : list.isEmpty ? "All set" : "Issue detected:\n" + list.map { "- " + $0 }.joined(separator: "\n"))
            exit(list.isEmpty ? 0 : 1)
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
    }
}
