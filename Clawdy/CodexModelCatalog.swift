//
//  CodexModelCatalog.swift
//  Clawdy
//
//  The models the Codex CLI offers, read from Codex's OWN catalog cache
//  (`~/.codex/models_cache.json`, written by the CLI: `models[] { slug, display_name,
//  visibility, priority }`) plus the user's default from `~/.codex/config.toml`
//  (`model = "…"`). Pure parsing over injected file contents so it's unit-testable and
//  never invents model names: only what Codex itself lists (`visibility: "list"`) is
//  offered, in the CLI's own priority order. If the cache is missing, the picker
//  degrades to just the config default.
//

import Foundation

struct CodexModelOption: Equatable, Identifiable {
    /// The `-m` value.
    let slug: String
    let displayName: String
    var id: String { slug }
}

enum CodexModelCatalog {
    static func defaultCacheURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectoryPath).appendingPathComponent(".codex/models_cache.json")
    }

    static func defaultConfigURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectoryPath).appendingPathComponent(".codex/config.toml")
    }

    /// The listed models, best first. Empty if the cache can't be read.
    static func parseListedModels(cacheJSON: Data) -> [CodexModelOption] {
        guard let root = try? JSONSerialization.jsonObject(with: cacheJSON) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
                return CodexModelOption(slug: slug, displayName: model["display_name"] as? String ?? slug)
            }
    }

    /// The `model = "…"` at the top level of config.toml, or nil.
    static func parseDefaultModel(configTOML: String) -> String? {
        for rawLine in configTOML.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Stop at the first table header: `model` under `[model_providers.x]` isn't the default.
            if line.hasPrefix("[") { break }
            guard line.hasPrefix("model") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "model" else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// What the panel shows: the config default first (labelled), then the rest of the
    /// listed models. Reads both files fresh each time (cheap; Codex keeps them current).
    static func load(
        cacheURL: URL = defaultCacheURL(),
        configURL: URL = defaultConfigURL()
    ) -> (defaultSlug: String?, options: [CodexModelOption]) {
        let listed = (try? Data(contentsOf: cacheURL)).map(parseListedModels(cacheJSON:)) ?? []
        let defaultSlug = (try? String(contentsOf: configURL, encoding: .utf8)).flatMap(parseDefaultModel(configTOML:))
        return (defaultSlug, listed)
    }
}
