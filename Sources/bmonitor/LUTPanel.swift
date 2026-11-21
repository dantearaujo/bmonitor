import AppKit
import MonitorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class LUTLibrary {
    let preview = LUTPreview()
    private(set) var names: [String] = []
    private(set) var selected: String?
    private(set) var error: String?
    private(set) var busy = false

    private static let directory = URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "com.dantearaujo.bmonitor")
        .appending(path: "LUTs", directoryHint: .isDirectory)

    init() {
        refresh()
        if let name = UserDefaults.standard.string(forKey: "previewLUT"), names.contains(name) {
            select(name)
        }
    }

    func select(_ name: String?) {
        guard !busy else { return }
        guard let name else {
            activate(nil, cube: nil)
            return
        }
        guard names.contains(name), name != selected else { return }
        let url = Self.directory.appending(path: name)
        load(url, importing: false)
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.load(url, importing: true)
        }
    }

    private func load(_ url: URL, importing: Bool) {
        guard !busy else { return }
        busy = true
        error = nil
        let directory = Self.directory
        Task {
            defer { busy = false }
            do {
                let (name, cube) = try await Task.detached(priority: .userInitiated) {
                    let cube = try ColorCube(contentsOf: url)
                    guard importing else { return (url.lastPathComponent, cube) }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let base = url.deletingPathExtension().lastPathComponent
                    var target = directory.appending(path: base + ".cube")
                    var index = 2
                    while FileManager.default.fileExists(atPath: target.path) {
                        target = directory.appending(path: "\(base) (\(index)).cube")
                        index += 1
                    }
                    try FileManager.default.copyItem(at: url, to: target)
                    return (target.lastPathComponent, cube)
                }.value
                refresh()
                activate(name, cube: cube)
            } catch is ColorCube.FormatError {
                error = String(localized: "Este arquivo não é um LUT 3D .cube compatível.")
            } catch {
                self.error = String(localized: "Não foi possível abrir o LUT: \(error.localizedDescription)")
            }
        }
    }

    private func refresh() {
        names = ((try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "cube" }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func activate(_ name: String?, cube: ColorCube?) {
        selected = name
        error = nil
        preview.setCube(cube)
        UserDefaults.standard.set(name, forKey: "previewLUT")
    }
}

struct LUTPanel: View {
    let library: LUTLibrary

    var body: some View {
        PanelSection(title: String(localized: "LUT de visualização no Mac")) {
            Picker("LUT", selection: Binding(get: { library.selected }, set: { library.select($0) })) {
                Text("Sem LUT").tag(nil as String?)
                ForEach(library.names, id: \.self) { name in
                    Text(verbatim: String(name.dropLast(5))).tag(Optional(name))
                }
            }
            .labelsHidden()
            Button("Importar LUT .cube…") { library.chooseFile() }
            if library.busy { ProgressView().controlSize(.small) }
            if let error = library.error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(library.busy)
    }
}
