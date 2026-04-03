//
//  Backend.swift
//  GPACalc
//
//  Created by willuhd on 3/4/26
//  Original project by LegitMichel777
//
//  Copyright (c) 2026, under the GPA Calculator project.
//  Proprietary, internal use only. All Rights Reserved.
//

import Foundation
import Combine
import SwiftUI

// MARK: - Collection extension
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - SelectionEntry
struct SelectionEntry {
    var itemIndex: Int
    var subjectId: String
}

// MARK: - RuleState
private struct RuleState {
    var disabledByModule: [Int: Set<Int>] = [:]
    var effectiveLimits: [Int: Int] = [:]
    var requirementWarning: String? = nil
    var requiredSubjects: Set<String> = []
    var modulesRequired: Set<Int> = []
    var invalid: Bool = false
}

// MARK: - Backend
final class Backend: ObservableObject {
    static let shared = Backend()

    @Published private(set) var root: CourseModel?
    @Published var currentPreset: CourseModel.Preset?
    @Published var activeSubjects: [CourseModel.Subject] = []
    @Published var calculationResultText: String = "whoops"
    @Published var scoreMapsById: [String: [CourseModel.ScoreEntry]] = [:]
    @Published var disabledIndicesByModule: [Int: Set<Int>] = [:]
    @Published var effectiveLimitsByModule: [Int: Int] = [:]
    @Published var requirementWarning: String? = nil
    @Published var requiredSubjectIDs: Set<String> = []
    @Published var modulesRequiringSelection: Set<Int> = []
    @Published var isInvalidated: Bool = false
    @Published var trackActive: Bool = true
    @Published var scoreDisplay: ScoreDisplay = .percentage { didSet { persistSelections() } }

    private var defaultScoreMapId: String = "default"
    private var selectedScoreMapIdBySubject: [String: String] = [:]
    private var selectedLevelIndicesBySubject: [String: Int] = [:]
    private var selectedScoreIndicesBySubject: [String: Int] = [:]
    private var selectionsByModule: [Int: [SelectionEntry]] = [:]
    private var trackToggleByPreset: [String: Bool] = [:]
    private var hasLoadedInitialData = false

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleExternalUpdate(_:)), name: Notification.Name("CoursesUpdated"), object: nil)
    }

    func checkForUpdates() { Updater.shared.checkForUpdates(currentVersion: root?.version) }

    var choiceModules: [(modIndex: Int, module: CourseModel.Module)] {
        currentPreset?.modules.enumerated().compactMap { $0.1.type == "choice" ? ($0.0, $0.1) : nil } ?? []
    }

    func activeAlternateMapIds() -> [String] {
        Array(Set(activeSubjects.compactMap { s in
            let id = s.scoreMapId
            return (id != nil && id != defaultScoreMapId && scoreMapsById[id!] != nil) ? id : nil
        })).sorted()
    }

    func publishedEffectiveLimit(for modIndex: Int) -> Int {
        effectiveLimitsByModule[modIndex] ?? currentPreset?.modules[safe: modIndex]?.limit ?? 1
    }

    func setTrackActive(_ isActive: Bool) {
        assert(Thread.isMainThread, "setTrackActive has to be on main")
        guard let p = currentPreset, p.track != nil else { trackActive = false; return }

        trackToggleByPreset[p.id] = isActive
        trackActive = isActive

        for subj in activeSubjects {
            let key = subjectKey(for: subj)
            let map = scoreMapForSubject(subj)
            if let c = selectedScoreIndicesBySubject[key], c >= map.count {
                selectedScoreIndicesBySubject[key] = max(0, map.count - 1)
            }
        }
        
        persistSelections()
        recomputeGPA()
    }

    // MARK: - Update loading
    func loadInitialData() {
        guard !hasLoadedInitialData else { return }
        hasLoadedInitialData = true
        
        let fm = FileManager.default
        let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        let savedURL = docDir?.appendingPathComponent(Updater.fileName + "." + Updater.fileExt)
        
        func tryLoad(from url: URL?) -> Bool {
            guard let url = url, let data = try? Data(contentsOf: url) else { return false }
            let stripped = Updater.shared.stripCommentLines(from: data)
            guard let parsed = try? JSONDecoder().decode(CourseModel.self, from: stripped) else { return false }
            applyRoot(parsed)
            Updater.shared.checkForUpdates(currentVersion: parsed.version)
            return true
        }

        if tryLoad(from: savedURL) { return }
        if savedURL != nil { try? fm.removeItem(at: savedURL!) }
        if tryLoad(from: Bundle.main.url(forResource: Updater.fileName, withExtension: Updater.fileExt)) { return }

        root = nil
        calculationResultText = "No catalog available"
    }

    func applyRoot(_ newRoot: CourseModel) {
        assert(Thread.isMainThread, "applyRoot must be called on main")
        let prevId = currentPreset?.id
        var root = newRoot

        // unique IDless names
        let tpls = Dictionary((root.templates ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (pIdx, p) in (root.presets ?? []).enumerated() {
            for (mIdx, m) in p.modules.enumerated() {
                for (sIdx, var s) in m.subjects.enumerated() {
                    if let t = tpls[s.template ?? ""] {
                        s.weight = s.weight ?? t.weight
                        s.levels = s.levels.isEmpty ? t.levels : s.levels
                        s.tags = (s.tags?.isEmpty ?? true) ? t.tags : s.tags
                        s.scoreMapId = (s.scoreMapId?.isEmpty ?? true) ? t.scoreMapId : s.scoreMapId
                        root.presets?[pIdx].modules[mIdx].subjects[sIdx] = s
                    }
                }
            }
        }

        self.root = root
        self.scoreMapsById = root.scoreMaps ?? (root.scoreMap.map { ["default": $0] } ?? [:])
        self.defaultScoreMapId = self.scoreMapsById.keys.contains("default") ? "default" : (self.scoreMapsById.keys.sorted().first ?? "default")

        if let p = root.presets?.first(where: { $0.id == prevId }) ?? root.presets?.first {
            selectPreset(p.id)
        } else {
            currentPreset = nil
            activeSubjects = []
            calculationResultText = "No presets in catalog"
        }
    }

    @objc private func handleExternalUpdate(_ note: Notification) {
        let apply = { [weak self] (data: Data) in
            guard let self = self else { return }
            if let parsed = try? JSONDecoder().decode(CourseModel.self, from: data), parsed.version != self.root?.version {
                self.applyRoot(parsed)
            }
        }
        
        var targetData = note.userInfo?["strippedData"] as? Data
        if targetData == nil,
           let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Courses.gpa"),
           let rawData = try? Data(contentsOf: url) {
            targetData = Updater.shared.stripCommentLines(from: rawData)
        }
        
        if let validData = targetData {
            Thread.isMainThread ? apply(validData) : DispatchQueue.main.async { apply(validData) }
        }
    }

    // MARK: - Preset selection
    func selectPreset(_ id: String) {
        assert(Thread.isMainThread, "selectPreset must be called on main")
        guard let p = root?.presets?.first(where: { $0.id == id }) else { return }
        currentPreset = p

        selectionsByModule.removeAll()
        for (i, m) in p.modules.enumerated() {
            let ids = UserDefaults.standard.stringArray(forKey: "config_\(p.id)_mod_ids_\(i)")
            let legacy = UserDefaults.standard.array(forKey: "config_\(p.id)_mod_\(i)") as? [Int]
            
            selectionsByModule[i] = (ids?.compactMap { sid in
                m.subjects.firstIndex(where: { subjectKey(for: $0) == sid }).map { SelectionEntry(itemIndex: $0, subjectId: sid) }
            }) ?? (legacy?.compactMap { idx in
                m.subjects.indices.contains(idx) ? SelectionEntry(itemIndex: idx, subjectId: subjectKey(for: m.subjects[idx])) : nil
            }) ?? []
        }

        rebuildActiveSubjects()

        let loadDict = { (key: String) -> [String: Int] in
            guard let d = UserDefaults.standard.data(forKey: key), let dict = try? JSONDecoder().decode([String: Int].self, from: d) else { return [:] }
            return dict
        }
        
        selectedLevelIndicesBySubject = loadDict("config_\(p.id)_levels")
        ensureDefaultIndices(for: activeSubjects, in: &selectedLevelIndicesBySubject)
        
        selectedScoreIndicesBySubject = loadDict("config_\(p.id)_scores")
        ensureDefaultIndices(for: activeSubjects, in: &selectedScoreIndicesBySubject)

        selectedScoreMapIdBySubject = (try? JSONDecoder().decode([String: String].self, from: UserDefaults.standard.data(forKey: "config_\(p.id)_scoreMapChoice") ?? Data())) ?? [:]
        
        let trackKey = "config_\(p.id)_trackToggle"
        trackToggleByPreset[p.id] = UserDefaults.standard.object(forKey: trackKey) as? Bool ?? (p.track != nil)
        trackActive = trackToggleByPreset[p.id] ?? false
        
        validateRulesAndRecompute()
    }

    private func rebuildActiveSubjects() {
        guard let p = currentPreset else { activeSubjects = []; return }
        activeSubjects = p.modules.enumerated().flatMap { (mIdx, m) in
            m.type == "core" ? m.subjects : (selectionsByModule[mIdx]?.compactMap { m.subjects[safe: $0.itemIndex] } ?? [])
        }
        ensureDefaultIndices(for: activeSubjects, in: &selectedLevelIndicesBySubject)
        ensureDefaultIndices(for: activeSubjects, in: &selectedScoreIndicesBySubject)
    }

    func selectedLevelIndex(for subjectIndex: Int) -> Int {
        activeSubjects[safe: subjectIndex].flatMap { selectedLevelIndicesBySubject[subjectKey(for: $0)] } ?? 0
    }

    func setLevelIndex(_ idx: Int, for subjectIndex: Int) {
        guard let subj = activeSubjects[safe: subjectIndex] else { return }
        selectedLevelIndicesBySubject[subjectKey(for: subj)] = idx

        let key = subjectKey(for: subj)
        let map = scoreMapForSubject(subj)
        if let currentScore = selectedScoreIndicesBySubject[key], currentScore >= map.count {
            selectedScoreIndicesBySubject[key] = max(0, map.count - 1)
        }

        persistSelections()
        rebuildActiveSubjects()
        validateRulesAndRecompute()
    }

    func selectedScoreIndex(for subjectIndex: Int) -> Int {
        activeSubjects[safe: subjectIndex].flatMap { selectedScoreIndicesBySubject[subjectKey(for: $0)] } ?? 0
    }

    func setScoreIndex(_ idx: Int, for subjectIndex: Int) {
        guard let subj = activeSubjects[safe: subjectIndex] else { return }
        selectedScoreIndicesBySubject[subjectKey(for: subj)] = idx
        persistSelections()
        recomputeGPA()
    }

    func toggleSelection(modIndex: Int, itemIndex: Int) {
        guard let p = currentPreset,
              let module = p.modules[safe: modIndex],
              let subj = module.subjects[safe: itemIndex], // safe check
              publishedEffectiveLimit(for: modIndex) > 0 else { return }
        
        var entries = selectionsByModule[modIndex] ?? []
        _ = subjectKey(for: subj)
        
        if let existing = entries.firstIndex(where: { $0.itemIndex == itemIndex }) {
            entries.remove(at: existing)
        } else {
            let subj = module.subjects[itemIndex]
            let sKey = subjectKey(for: subj)
            
            var tags = Set(subj.tags ?? [])
            tags.formUnion(subj.levels[safe: selectedLevelIndicesBySubject[sKey] ?? 0]?.tags ?? [])
            
            if let lims = p.rules?.tagLimits {
                for tag in tags where lims.contains(where: { $0.tag == tag && $0.limit == 1 }) {
                    if let idx = entries.firstIndex(where: { entryHasTag($0, tag: tag, in: p) }) {
                        entries.remove(at: idx)
                    } else {
                        removeFirstEntryWithTag(tag, in: p, excludingSubjectId: sKey)
                    }
                }
            }
            
            entries.append(SelectionEntry(itemIndex: itemIndex, subjectId: sKey))
            selectionsByModule[modIndex] = entries
            
            // limit defaults to a good floor
            let dryLimit = max(0, evaluateRulesInternal().effectiveLimits[modIndex] ?? (module.limit ?? 1))
            if entries.count > dryLimit { entries.removeFirst(entries.count - dryLimit) }
        }
        
        selectionsByModule[modIndex] = entries
        persistSelections()
        rebuildActiveSubjects()
        validateRulesAndRecompute()
    }

    func isSelected(modIndex: Int, itemIndex: Int) -> Bool {
        selectionsByModule[modIndex]?.contains { $0.itemIndex == itemIndex } ?? false
    }

    func isDisabled(modIndex: Int, itemIndex: Int) -> Bool {
        guard let m = currentPreset?.modules[safe: modIndex], m.subjects.indices.contains(itemIndex) else { return true }
        if publishedEffectiveLimit(for: modIndex) == 0 || disabledIndicesByModule[modIndex]?.contains(itemIndex) == true { return true }
        let key = subjectKey(for: m.subjects[itemIndex])
        return !key.isEmpty && !isSelected(modIndex: modIndex, itemIndex: itemIndex) && selectedIdsSet().contains(key)
    }

    private func validateRulesAndRecompute() {
        assert(Thread.isMainThread, "validateRulesAndRecompute must be called on main")
        var state = evaluateRulesInternal()
        var needsRebuild = true
        var loops = 0

        while needsRebuild && loops < 5 {
            needsRebuild = false
            loops += 1

            for (mod, limit) in state.effectiveLimits {
                if let entries = selectionsByModule[mod], entries.count > limit {
                    
                    // prevent crashes on negative module limits
                    let safeLimit = max(0, limit)
                    if entries.count > safeLimit {
                        selectionsByModule[mod] = Array(entries.prefix(safeLimit))
                        needsRebuild = true
                    }
                    needsRebuild = true
                }
            }

            if needsRebuild {
                persistSelections()
                rebuildActiveSubjects()
                state = evaluateRulesInternal()
            }
        }

        for (mod, limit) in state.effectiveLimits where limit == 0 {
            NotificationCenter.default.post(name: Notification.Name("ModuleShouldCollapse"), object: nil, userInfo: ["moduleIndex": mod])
        }

        applyRuleState(state)
        recomputeGPA()
    }

    private func evaluateRulesInternal() -> RuleState {
        guard let p = currentPreset else { return RuleState() }

        let activeTags = activeTagsCounts()
        var modCounts = [Int: Int]()
        var subjLocs = [String: [(Int, Int)]]()
        
        for (mIdx, m) in p.modules.enumerated() {
            modCounts[mIdx] = m.type == "core" ? m.subjects.count : (selectionsByModule[mIdx]?.count ?? 0)
            for (sIdx, subj) in m.subjects.enumerated() {
                subjLocs[subjectKey(for: subj), default: []].append((mIdx, sIdx))
            }
        }
        
        let allIds = selectedIdsSet()
        var excludedTags = Set<String>(), excludedIds = Set<String>(), cappedTags = Set<String>()
        var effLimits = [Int: Int]()
        var reqWarnings = [String](), reqSubjs = Set<String>(), modsReq = Set<Int>()

        for i in p.modules.indices { effLimits[i] = p.modules[i].limit ?? 1 }

        if let rules = p.rules {
            rules.exclusionTags?.filter { $0.contains { activeTags[$0, default: 0] > 0 } }
                .forEach { $0.filter { activeTags[$0, default: 0] == 0 }.forEach { excludedTags.insert($0) } }
            
            rules.exclusionIds?.filter { $0.contains { allIds.contains($0) } }
                .forEach { $0.filter { !allIds.contains($0) }.forEach { excludedIds.insert($0) } }
            
            rules.tagLimits?.filter { $0.limit > 1 && activeTags[$0.tag, default: 0] >= $0.limit }
                .forEach { cappedTags.insert($0.tag) }
            
            rules.dynamicLimits?.filter { matchesCondition(count: modCounts[$0.triggerModuleIndex] ?? 0, condition: $0.triggerCondition) }
                .forEach { r in r.targetModuleIndices.forEach { effLimits[$0] = r.newLimit } }
            
            rules.requirements?.filter { activeTags[$0.triggerTag, default: 0] > 0 && !$0.requiredAnyTag.contains(where: { activeTags[$0, default: 0] > 0 }) }
                .forEach { req in
                    reqWarnings.append(req.errorMessage)
                    p.modules.filter { $0.type != "core" }.flatMap { $0.subjects }.forEach { s in
                        let combined = Set(s.tags ?? []).union(s.levels.flatMap { $0.tags ?? [] })
                        if !combined.isDisjoint(with: req.requiredAnyTag) { reqSubjs.insert(subjectKey(for: s)) }
                    }
                }
            
            rules.conditionalRequirements?.forEach { cond in
                if evaluateConditionalTrigger(cond.trigger, allIds: allIds, modCounts: modCounts, subjLocs: subjLocs, p: p) {
                    cond.enforceModuleLimits?.forEach { effLimits[$0.moduleIndex] = $0.newLimit }
                    if let reqAny = cond.requiresAnyOfSubjectIds, !reqAny.isEmpty {
                        let validReqs = reqAny.filter { subjLocs[$0]?.contains { effLimits[$0.0] ?? 1 > 0 } ?? true }
                        if !validReqs.isEmpty && !validReqs.contains(where: allIds.contains) {
                            reqWarnings.append(cond.errorMessage ?? "Requirement not met")
                            validReqs.forEach { reqSubjs.insert($0) }
                        }
                    }
                }
            }
        }

        for (i, m) in p.modules.enumerated() where (m.minSelection ?? 0) > (selectionsByModule[i]?.count ?? 0) {
            modsReq.insert(i)
        }

        var disabled = [Int: Set<Int>]()
        for (mIdx, m) in p.modules.enumerated() {
            var d = Set<Int>()
            let sel = Set(selectionsByModule[mIdx]?.map { $0.itemIndex } ?? [])
            for (sIdx, subj) in m.subjects.enumerated() where !sel.contains(sIdx) {
                let key = subjectKey(for: subj)
                if effLimits[mIdx] == 0 || excludedIds.contains(key) || allIds.contains(key) {
                    d.insert(sIdx); continue
                }
                
                // toggle swapping
                if let tags = subj.tags {
                    if !Set(tags).isDisjoint(with: excludedTags) || !Set(tags).isDisjoint(with: cappedTags) {
                        d.insert(sIdx)
                    }
                }
            }
            disabled[mIdx] = d
        }

        return RuleState(disabledByModule: disabled, effectiveLimits: effLimits, requirementWarning: reqWarnings.first, requiredSubjects: reqSubjs, modulesRequired: modsReq, invalid: !reqWarnings.isEmpty || !modsReq.isEmpty)
    }

    private func applyRuleState(_ state: RuleState) {
        disabledIndicesByModule = state.disabledByModule
        effectiveLimitsByModule = state.effectiveLimits
        requirementWarning = state.requirementWarning
        requiredSubjectIDs = state.requiredSubjects
        modulesRequiringSelection = state.modulesRequired
        isInvalidated = state.invalid
    }

    private func evaluateConditionalTrigger(_ t: CourseModel.PresetTrigger, allIds: Set<String>, modCounts: [Int: Int], subjLocs: [String: [(Int, Int)]], p: CourseModel.Preset) -> Bool {
        let idTrig = t.selectedSubjectIds?.contains { allIds.contains($0) } ?? false
        var modTrig = false
        
        if let mc = t.moduleConditions, !mc.isEmpty {
            modTrig = mc.allSatisfy { cond in
                let c = modCounts[cond.moduleIndex] ?? 0
                if let exact = cond.exactCount, c != exact { return false }
                if let minSel = cond.minSelected, c < minSel { return false }
                if let rTag = cond.requireTag, let m = p.modules[safe: cond.moduleIndex] {
                    if m.type == "core" {
                        return m.subjects.contains { s in Set(s.tags ?? []).union(s.levels[safe: selectedLevelIndicesBySubject[subjectKey(for: s)] ?? 0]?.tags ?? []).contains(rTag) }
                    } else {
                        return selectionsByModule[cond.moduleIndex]?.contains { e in
                            guard let loc = subjLocs[e.subjectId]?.first(where: { $0.0 == cond.moduleIndex }), let s = p.modules[safe: loc.0]?.subjects[safe: loc.1] else { return false }
                            return Set(s.tags ?? []).union(s.levels[safe: selectedLevelIndicesBySubject[subjectKey(for: s)] ?? 0]?.tags ?? []).contains(rTag)
                        } ?? false
                    }
                }
                return true
            }
        }
        if t.selectedSubjectIds != nil && t.moduleConditions != nil { return idTrig && modTrig }
        return t.selectedSubjectIds != nil ? idTrig : modTrig
    }

    func scoreMapForSubject(_ subj: CourseModel.Subject) -> [CourseModel.ScoreEntry] {
        if let custom = subj.customMap, !custom.isEmpty { return custom }
        if let p = currentPreset, let track = p.track, let lvl = subj.levels[safe: selectedLevelIndicesBySubject[subjectKey(for: subj)] ?? 0],
           lvl.tags?.contains(track.id) == true, trackToggleByPreset[p.id] ?? true, let map = scoreMapsById[track.scoreMapId] {
            return map
        }
        return scoreMapsById[subj.scoreMapId ?? ""] ?? scoreMapsById[defaultScoreMapId] ?? []
    }

    func moduleStatusText(modIndex: Int) -> String {
        guard let m = currentPreset?.modules[safe: modIndex] else { return "" }
        let sel = selectionsByModule[modIndex]?.count ?? 0
        if publishedEffectiveLimit(for: modIndex) == 0 { return "Disabled" }
        return m.minSelection.flatMap { $0 > 0 ? "\(sel) selected (min \($0))" : nil } ?? "\(sel) selected"
    }

    func moduleStatusColor(modIndex: Int) -> Color {
        publishedEffectiveLimit(for: modIndex) == 0 ? .gray : (modulesRequiringSelection.contains(modIndex) ? .red : .secondary)
    }

    func resetSelections() {
        guard let p = currentPreset else { return }
        p.modules.indices.forEach { i in
            selectionsByModule[i] = []
            UserDefaults.standard.removeObject(forKey: "config_\(p.id)_mod_\(i)")
            UserDefaults.standard.removeObject(forKey: "config_\(p.id)_mod_ids_\(i)")
        }
        persistSelections()
        rebuildActiveSubjects()
        validateRulesAndRecompute()
    }

    private func persistSelections() {
        guard let p = currentPreset else { return }
        let valid = Set(p.modules.flatMap { $0.subjects }.map { subjectKey(for: $0) })
        
        selectedLevelIndicesBySubject = selectedLevelIndicesBySubject.filter { valid.contains($0.key) }
        selectedScoreIndicesBySubject = selectedScoreIndicesBySubject.filter { valid.contains($0.key) }
        selectedScoreMapIdBySubject = selectedScoreMapIdBySubject.filter { valid.contains($0.key) }

        if let data = try? JSONEncoder().encode(selectedLevelIndicesBySubject) { UserDefaults.standard.set(data, forKey: "config_\(p.id)_levels") }
        if let data = try? JSONEncoder().encode(selectedScoreIndicesBySubject) { UserDefaults.standard.set(data, forKey: "config_\(p.id)_scores") }
        if let data = try? JSONEncoder().encode(selectedScoreMapIdBySubject) { UserDefaults.standard.set(data, forKey: "config_\(p.id)_scoreMapChoice") }
        UserDefaults.standard.set(trackToggleByPreset[p.id] ?? true, forKey: "config_\(p.id)_trackToggle")

        for i in p.modules.indices {
            UserDefaults.standard.set(selectionsByModule[i]?.map { $0.subjectId } ?? [], forKey: "config_\(p.id)_mod_ids_\(i)")
        }
    }

    // GPA algorithm: (weight_i / ∑weights) * (gpa - offset)
    private func recomputeGPA() {
        assert(Thread.isMainThread, "recomputeGPA must be called on main")
        guard currentPreset != nil else { calculationResultText = "whoops"; return }

        var pts = 0.0, wgt = 0.0
        for subj in activeSubjects {
            let lvl = subj.levels[safe: selectedLevelIndicesBySubject[subjectKey(for: subj)] ?? 0] ?? CourseModel.Level(name: "", offset: 0, tags: nil)
            let baseGPA = scoreMapForSubject(subj)[safe: selectedScoreIndicesBySubject[subjectKey(for: subj)] ?? 0]?.gpa ?? 0.0
            let w = lvl.weightOverride ?? subj.weight ?? 0.0
            
            pts += max(0.0, baseGPA - max(0.0, lvl.offset)) * w
            wgt += w
        }
        calculationResultText = wgt > 0 ? String(format: "Your GPA: %.3f", pts / wgt) : "whoops"
    }

    func resetAllLevelsAndScores() {
        selectedLevelIndicesBySubject.removeAll()
        selectedScoreIndicesBySubject.removeAll()
        selectedScoreMapIdBySubject.removeAll()
        ensureDefaultIndices(for: activeSubjects, in: &selectedLevelIndicesBySubject)
        ensureDefaultIndices(for: activeSubjects, in: &selectedScoreIndicesBySubject)
        persistSelections()
        rebuildActiveSubjects()
        validateRulesAndRecompute()
    }

    private func subjectKey(for subj: CourseModel.Subject) -> String { subj.id.isEmpty ? subj.name : subj.id }

    private func activeTagsCounts() -> [String: Int] {
        var counts = [String: Int]()
        for subj in activeSubjects {
            var tags = Set(subj.tags ?? [])
            if let lvl = subj.levels[safe: selectedLevelIndicesBySubject[subjectKey(for: subj)] ?? 0] { tags.formUnion(lvl.tags ?? []) }
            for t in tags { counts[t, default: 0] += 1 }
        }
        return counts
    }

    private func selectedIdsSet() -> Set<String> {
        Set((currentPreset?.modules.enumerated().flatMap { (mIdx, m) in
            m.type == "core" ? m.subjects.map { subjectKey(for: $0) } : (selectionsByModule[mIdx]?.map { $0.subjectId } ?? [])
        }) ?? [])
    }

    private func ensureDefaultIndices(for subjects: [CourseModel.Subject], in dict: inout [String: Int]) {
        subjects.forEach { dict[subjectKey(for: $0)] = dict[subjectKey(for: $0)] ?? 0 }
    }

    private func matchesCondition(count: Int, condition: String) -> Bool {
        if condition.hasPrefix(">="), let v = Int(condition.dropFirst(2).trimmingCharacters(in: .whitespaces)) { return count >= v }
        if condition.hasPrefix("=="), let v = Int(condition.dropFirst(2).trimmingCharacters(in: .whitespaces)) { return count == v }
        return false
    }

    private func entryHasTag(_ entry: SelectionEntry, tag: String, in p: CourseModel.Preset) -> Bool {
        p.modules.contains { m in
            guard let s = m.subjects.first(where: { subjectKey(for: $0) == entry.subjectId }) else { return false }
            return Set(s.tags ?? []).union(s.levels[safe: selectedLevelIndicesBySubject[entry.subjectId] ?? 0]?.tags ?? []).contains(tag)
        }
    }

    @discardableResult private func removeFirstEntryWithTag(_ tag: String, in p: CourseModel.Preset, excludingSubjectId: String? = nil) -> Bool {
        for mIdx in p.modules.indices {
            if var entries = selectionsByModule[mIdx], let idx = entries.firstIndex(where: { $0.subjectId != excludingSubjectId && entryHasTag($0, tag: tag, in: p) }) {
                entries.remove(at: idx)
                selectionsByModule[mIdx] = entries
                return true
            }
        }
        return false
    }
}
