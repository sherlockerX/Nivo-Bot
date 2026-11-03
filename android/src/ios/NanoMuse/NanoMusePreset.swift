//
//  NanoMusePreset.swift
//  nanoMuse
//
//  The personal build's starting state, the same as on Android: the skills it installs (a
//  course is a folder: SKILL.md and books/B01…B10), the agent's files about its owner and the
//  coach's steering sentence. Shipped as Resources/preset.json, written by
//  scripts/ios-preset.py from the Android app's assets/preset/ (a synchronized folder would
//  flatten the seven SKILL.md files into one name).
//
//  Nothing here overwrites what the owner or the agent wrote: a file is seeded once and only
//  when it is missing or blank; a skill is installed once, so one the owner deleted stays
//  deleted; one nobody edited follows a newer shipped version.
//  Android: preset/Preset.kt.
//

import Foundation

@MainActor
enum NanoMusePreset {
    private enum Keys {
        static let skills = "nanomuse.preset.skills"
        static let files = "nanomuse.preset.files"
        static let wroteAt = "nanomuse.preset.skill_at."
    }

    /// Relative path under assets/preset/ → text.
    private static let files: [String: String] = {
        guard let url = Bundle.main.url(forResource: "preset", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = object["files"] as? [String: String] else { return [:] }
        return files
    }()

    /// Both steps, at launch.
    static func apply() {
        ensureFiles()
        installSkills()
    }

    /// USER.md, GLOBAL.md and the coach's steering sentence, once each and only into an empty file.
    static func ensureFiles() {
        let defaults = UserDefaults.standard
        var seeded = Set(defaults.stringArray(forKey: Keys.files) ?? [])
        let targets: [(String, URL)] = [
            ("memory/USER.md", NanoMuseDirs.memory.appendingPathComponent("USER.md")),
            ("memory/GLOBAL.md", NanoMuseDirs.memory.appendingPathComponent("GLOBAL.md")),
            ("feed-preferences.md", NanoMuseDirs.root.appendingPathComponent("feed-preferences.md")),
        ]
        for (path, target) in targets where !seeded.contains(path) {
            // GLOBAL.md tells the agent which phone it runs on; the shared copy was written for Android.
            guard let text = files[path].map({ $0.replacingOccurrences(of: "Android 手机", with: "iPhone") }) else { continue }
            let existing = (try? String(contentsOf: target, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existing.isEmpty {
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: target, atomically: true, encoding: .utf8)
            }
            seeded.insert(path)
        }
        defaults.set(Array(seeded), forKey: Keys.files)
    }

    /// Each preset skill once, as an ordinary skill the owner can edit or delete, with its other files.
    static func installSkills() {
        let store = SkillStore.shared
        let defaults = UserDefaults.standard
        var seeded = Set(defaults.stringArray(forKey: Keys.skills) ?? [])
        let ids = Set(files.keys.compactMap { key -> String? in
            let parts = key.split(separator: "/")
            return parts.count >= 3 && parts[0] == "skills" ? String(parts[1]) : nil
        })
        for id in ids.sorted() {
            guard let text = files["skills/\(id)/SKILL.md"] else { continue }
            let version = frontMatterValue("version", in: text)
            if seeded.contains(id) {
                let since = upgrade(id, text: text, version: version)
                if store.skills.contains(where: { $0.id == id }) { copyExtras(id, replaceUntouchedSince: since) }
                continue
            }
            if !store.skills.contains(where: { $0.id == id }),
               let skill = try? store.importSkill(content: text, source: .file) {
                defaults.set(skill.updatedAt.timeIntervalSince1970, forKey: Keys.wroteAt + id)
            }
            if store.skills.contains(where: { $0.id == id }) { copyExtras(id, replaceUntouchedSince: nil) }
            seeded.insert(id)
        }
        defaults.set(Array(seeded), forKey: Keys.skills)
    }

    /// A preset skill nobody edited since this installer wrote it follows a newer shipped version.
    /// Returns when the installer had last written it, once it upgraded; nil when nothing changed.
    private static func upgrade(_ id: String, text: String, version: String?) -> Date? {
        let store = SkillStore.shared
        guard let installed = store.skills.first(where: { $0.id == id }),
              let version, compareVersions(version, installed.version) > 0 else { return nil }
        let stored = UserDefaults.standard.double(forKey: Keys.wroteAt + id)
        let wroteAt = stored > 0 ? Date(timeIntervalSince1970: stored) : installed.installedAt
        let file = store.skillDirectoryURL(for: id).appendingPathComponent("SKILL.md")
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date ?? wroteAt
        guard installed.updatedAt.timeIntervalSince(wroteAt) <= 1, modified.timeIntervalSince(wroteAt) <= 2,
              let upgraded = try? store.importSkill(content: text, source: .file) else { return nil }
        UserDefaults.standard.set(upgraded.updatedAt.timeIntervalSince1970, forKey: Keys.wroteAt + id)
        return wroteAt
    }

    /// The files a preset skill ships besides SKILL.md. FRAMEWORK.md and ADJUSTMENTS.md are the
    /// person's and never ship, so the coach's writes are never touched.
    private static func copyExtras(_ id: String, replaceUntouchedSince: Date?) {
        let prefix = "skills/\(id)/"
        for (key, text) in files where key.hasPrefix(prefix) {
            let relative = String(key.dropFirst(prefix.count))
            guard relative != "SKILL.md" else { continue }
            SkillStore.shared.nmWritePresetFile(skillId: id, relativePath: relative, content: text, replaceUntouchedSince: replaceUntouchedSince)
        }
    }

    private static func frontMatterValue(_ key: String, in text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces) == key {
                return line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            }
        }
        return nil
    }

    /// "2.0.0" against "1.0.0", part by part; a missing or odd part counts as 0.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d != 0 { return d }
        }
        return 0
    }
}
