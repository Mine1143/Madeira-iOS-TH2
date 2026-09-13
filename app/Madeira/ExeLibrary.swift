// ExeLibrary.swift — game library + custom EXE launcher for Madeira.
//
// Scans Documents/wine/drive_c/ (where users drop game folders via the
// Files app / SideStore / afc) for .exe files, remembers recently played
// titles, and launches any of them with optional args — the same env-var
// path the built-in buttons use (MADEIRA_EXE / MADEIRA_ARGS /
// MADEIRA_DESKTOP), so EVERY x86-64 game that Wine+DXMT can run becomes
// launchable without a per-title button.

import Foundation

struct GameExe: Identifiable, Hashable {
    let id = UUID()
    let winePath: String     // C:\Program Files\Game\game.exe
    let displayName: String   // game.exe
    let folder: String       // Game
    let sizeMB: Double
}

final class ExeLibrary: ObservableObject {
    static let shared = ExeLibrary()

    @Published var games: [GameExe] = []
    @Published var scanning = false

    private let docs: URL

    init() {
        docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var driveC: URL {
        docs.appendingPathComponent("wine/drive_c")
    }

    func scan() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var found: [GameExe] = []
            let fm = FileManager.default
            var stack = [driveC]
            var seen = Set<URL>()
            let skipDirs: Set<String> = ["windows", "users", "__pycache__", "dotnet"]

            while let dir = stack.popLast() {
                guard seen.insert(dir).inserted else { continue }
                guard let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]) else { continue }

                for e in entries {
                    if var isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory, isDir {
                        let n = e.lastPathComponent.lowercased()
                        // Skip Wine's own dirs; cap depth to keep the scan fast
                        if e.pathComponents.count - driveC.pathComponents.count < 6,
                           !skipDirs.contains(n) {
                            stack.append(e)
                        }
                    } else if e.pathExtension.lowercased() == "exe" {
                        // Filter Wine's own executables at the root level
                        let inWindowsDir = e.path.contains("/windows/")
                        let isLauncherHelper = ["explorer.exe","cmd.exe","regedit.exe",
                                                "services.exe","rpcss.exe","plugplay.exe",
                                                "conhost.exe","wineboot.exe","msiexec.exe",
                                                "svchost.exe","taskmgr.exe","uninstaller.exe"]
                            .contains(e.lastPathComponent.lowercased())
                        guard !inWindowsDir, !isLauncherHelper else { continue }
                        let size = (try? e.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        let winePath = "C:\\" + e.path
                            .replacingOccurrences(of: driveC.path + "/", with: "")
                            .replacingOccurrences(of: "/", with: "\\")
                        found.append(GameExe(
                            winePath: winePath,
                            displayName: e.deletingPathExtension().lastPathComponent,
                            folder: e.deletingLastPathComponent().lastPathComponent,
                            sizeMB: Double(size) / 1_048_576))
                    }
                }
            }

            found.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
            DispatchQueue.main.async {
                self.games = found
                self.scanning = false
            }
        }
    }

    /// Launch via the same env-var contract as the built-in buttons.
    /// desktop=true wraps in a 1280x720 virtual desktop (safer for most
    /// fullscreen games, mirrors the Steam button's approach).
    func launch(_ game: GameExe, args: String = "", desktop: Bool = true) {
        setenv("MADEIRA_EXE", game.winePath, 1)
        if args.isEmpty {
            unsetenv("MADEIRA_ARGS")
        } else {
            setenv("MADEIRA_ARGS", args, 1)
        }
        if desktop {
            let w = 1280, h = 720
            setenv("MADEIRA_ARGS",
                   (args.isEmpty ? "" : args + " ")
                    + "/desktop=game,\(w)x\(h)", 1)
            setenv("MADEIRA_DESKTOP", "1", 1)
            setenv("MADEIRA_SCREEN_W", String(w), 1)
            setenv("MADEIRA_SCREEN_H", String(h), 1)
        } else {
            unsetenv("MADEIRA_DESKTOP")
            unsetenv("MADEIRA_SCREEN_W")
            unsetenv("MADEIRA_SCREEN_H")
        }
        // Reuse the run-sequence the built-in buttons use
        NotificationCenter.default.post(name: .madeiraLaunchSequence, object: nil)
    }
}

extension Notification.Name {
    static let madeiraLaunchSequence = Notification.Name("madeira.launch.sequence")
}
