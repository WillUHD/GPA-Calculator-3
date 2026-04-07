//
//  Updater.swift
//  GPACalc
//
//  Created by willuhd on 3/4/26.
//  Original project by LegitMichel777
//
//  Copyright (c) 2026, under the GPA Calculator project.
//  Proprietary, internal use only. All Rights Reserved.
//

import Foundation

final class Updater {
    static let shared = Updater()
    static let fileName = "Courses"
    static let fileExt = "gpa"

    private init() {}

    func stripCommentLines(from data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) else { return data }
        let lines = s.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
            return !trimmedLeading.hasPrefix("//")
        }
        let joined = filtered.joined(separator: "\n")
        return Data(joined.utf8)
    }

    /// Checks for catalog updates from the remote repository.
    /// Accepts the currently loaded version to avoid redundant file I/O and JSON decoding.
    func checkForUpdates(currentVersion: String? = nil) {
        guard let url = URL(string: "https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/WillUHD/CourseResources/refs/heads/main/" + Updater.fileName + "." + Updater.fileExt)
        else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Updater: fetch failed: \(error.localizedDescription)")
                return
            }
            guard let data = data else { return }

            do {
                let filteredRemoteData = self.stripCommentLines(from: data)
                let newRoot = try JSONDecoder().decode(CourseModel.self, from: filteredRemoteData)
                let _: String? = currentVersion ?? self.readLocalVersion()

                if let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let fileURL = docDir.appendingPathComponent(Updater.fileName + "." + Updater.fileExt)
                    try data.write(to: fileURL, options: .atomic)
                    print("Updater: downloaded version \(newRoot.version ?? "unknown")")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: Notification.Name("CoursesUpdated"),
                            object: nil,
                            userInfo: ["strippedData": filteredRemoteData]
                        )
                    }
                }
            } catch {
                print("Updater: invalid data received: \(error.localizedDescription)")
            }
        }
        task.resume()
    }

    /// Reads the local catalog version from saved file or bundle (fallback only).
    private func readLocalVersion() -> String? {
        if let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let savedURL = docDir.appendingPathComponent(Updater.fileName + "." + Updater.fileExt)
            if let savedData = try? Data(contentsOf: savedURL) {
                let filtered = stripCommentLines(from: savedData)
                if let root = try? JSONDecoder().decode(CourseModel.self, from: filtered) {
                    return root.version
                }
            }
        }
        if let bundleURL = Bundle.main.url(forResource: Updater.fileName, withExtension: Updater.fileExt),
           let bundleData = try? Data(contentsOf: bundleURL) {
            let filtered = stripCommentLines(from: bundleData)
            if let root = try? JSONDecoder().decode(CourseModel.self, from: filtered) {
                return root.version
            }
        }
        return nil
    }
}
