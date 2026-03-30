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

    // MARK: Published states
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
    @Published var scoreDisplay: ScoreDisplay = .percentage {
        didSet { persistSelections() }
    }

    // MARK: Private states
    private var defaultScoreMapId: String = "default"
    private var globalScoringChoiceByMapId: [String: Int] = [:]
    private var selectedScoreMapIdBySubject: [String: String] = [:]
    private var selectedLevelIndicesBySubject: [String: Int] = [:]
    private var selectedScoreIndicesBySubject: [String: Int] = [:]
    private var selectionsByModule: [Int: [SelectionEntry]] = [:]
    private var trackToggleByPreset: [String: Bool] = [:]

    // MARK: init
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalUpdate(_:)),
            name: Notification.Name("CoursesUpdated"),
            object: nil
        )
    }

    // MARK: - api
    func checkForUpdates() {
        Updater.shared.checkForUpdates(currentVersion: root?.version)
    }

    // all "choice" Ms in the current preset with their indices
    var choiceModules: [(modIndex: Int, module: CourseModel.Module)] {
        guard let p = currentPreset else { return [] }
        return p.modules.enumerated().compactMap { idx, m in
            m.type == "choice" ? (idx, m) : nil
        }
    }

    // alt ScoreMap IDs actually in use by active subjects
    func activeAlternateMapIds() -> [String] {
        guard currentPreset != nil else { return [] }
        var mapIds = Set<String>()
        for subj in activeSubjects {
            if let sid = subj.scoreMapId,
               sid != defaultScoreMapId,
               scoreMapsById[sid] != nil {
                mapIds.insert(sid)
            }
        }
        return Array(mapIds).sorted()
    }

    func globalChoice(forMapId id: String) -> Int {
        globalScoringChoiceByMapId[id] ?? 0
    }

    func setGlobalChoice(_ choice: Int, forMapId id: String) {
        globalScoringChoiceByMapId[id] = max(0, min(choice, 2))
        persistSelections()
        recomputeGPA()
    }

    // effective limit for a module (reading from computed rule state)
    func publishedEffectiveLimit(for modIndex: Int) -> Int {
        if let v = effectiveLimitsByModule[modIndex] { return v }
        guard let p = currentPreset, p.modules.indices.contains(modIndex) else { return 1 }
        return p.modules[modIndex].limit ?? 1
    }

    // MARK: - Tracks
    // if a course is specified to be a certain track (eg. "AP")
    // the user can toggle to use the AP ScoreMap for AP courses in that track
    
    // sets whether the current preset's track score map is active
    // clamps score indices for affected subjects since map lengths differ
    func setTrackActive(_ isActive: Bool) {
        assert(Thread.isMainThread, "setTrackActive has to be on main")
        guard let p = currentPreset, p.track != nil else {
            trackActive = false
            return
        }

        trackToggleByPreset[p.id] = isActive
        trackActive = isActive

        // clamp score indices - the score map length changes when toggling
        for subj in activeSubjects {
            let key = subjectKey(for: subj)
            let map = scoreMapForSubject(subj)
            if let currentIdx = selectedScoreIndicesBySubject[key], currentIdx >= map.count {
                selectedScoreIndicesBySubject[key] = max(0, map.count - 1)
            }
        }

        persistSelections()
        recomputeGPA()
    }

    // MARK: - Update loading
    func loadInitialData() {
        if let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let savedURL = docDir.appendingPathComponent("Courses.json")
            if FileManager.default.fileExists(atPath: savedURL.path) {
                do {
                    let data = try Data(contentsOf: savedURL)
                    let stripped = Updater.shared.stripCommentLines(from: data)
                    let parsed = try JSONDecoder().decode(CourseModel.self, from: stripped)
                    applyRoot(parsed)
                    Updater.shared.checkForUpdates(currentVersion: parsed.version)
                    return
                } catch {
                    print("Backend: failed to decode saved Courses.json: \(error)")
                }
            }
        }

        if let bundleURL = Bundle.main.url(forResource: "Courses", withExtension: "json") {
            do {
                let data = try Data(contentsOf: bundleURL)
                let stripped = Updater.shared.stripCommentLines(from: data)
                let parsed = try JSONDecoder().decode(CourseModel.self, from: stripped)
                applyRoot(parsed)
                Updater.shared.checkForUpdates(currentVersion: parsed.version)
                return
            } catch {
                print("Backend: failed to decode bundled Courses.json: \(error)")
            }
        }

        root = nil
        scoreMapsById = [:]
        currentPreset = nil
        activeSubjects = []
        calculationResultText = "No catalog available"
    }

    // applies a new root catalog:
    // populates templates, score maps, and selects the first preset
    // (the app's default start state)
    func applyRoot(_ newRoot: CourseModel) {
        assert(Thread.isMainThread, "applyRoot must be called on main")
        var populated = newRoot

        // expand templates into subjects
        var templatesById: [String: CourseModel.Template] = [:]
        if let tpls = newRoot.templates {
            for t in tpls { templatesById[t.id] = t }
        }

        if var presets = populated.presets {
            for pIndex in presets.indices {
                for mIndex in presets[pIndex].modules.indices {
                    for sIndex in presets[pIndex].modules[mIndex].subjects.indices {
                        var subj = presets[pIndex].modules[mIndex].subjects[sIndex]
                        if let tplId = subj.template, let tpl = templatesById[tplId] {
                            if subj.weight == 0 { subj.weight = tpl.weight }
                            if subj.levels.isEmpty { subj.levels = tpl.levels }
                            if subj.tags == nil || subj.tags?.isEmpty == true, let tTags = tpl.tags {
                                subj.tags = tTags
                            }
                            if subj.scoreMapId == nil || subj.scoreMapId?.isEmpty == true, let tMap = tpl.scoreMapId {
                                subj.scoreMapId = tMap
                            }
                            presets[pIndex].modules[mIndex].subjects[sIndex] = subj
                        }
                    }
                }
            }
            populated.presets = presets
        }

        // publish
        root = populated

        if let maps = populated.scoreMaps, !maps.isEmpty {
            scoreMapsById = maps
            defaultScoreMapId = maps.keys.contains("default") ? "default" : (maps.keys.first ?? "default")
        } else if let legacy = populated.scoreMap, !legacy.isEmpty {
            scoreMapsById = ["default": legacy]
            defaultScoreMapId = "default"
        } else {
            scoreMapsById = [:]
        }

        if let first = populated.presets?.first {
            selectPreset(first.id)
        } else {
            currentPreset = nil
            activeSubjects = []
            calculationResultText = "No presets in catalog"
        }
    }

    @objc private func handleExternalUpdate(_ note: Notification) {
        let apply = { (data: Data) in
            if let parsed = try? JSONDecoder().decode(CourseModel.self, from: data),
               parsed.version != self.root?.version {
                self.applyRoot(parsed)
            }
        }

        // prefer the pre-stripped data from the notification
        if let stripped = note.userInfo?["strippedData"] as? Data {
            if Thread.isMainThread { apply(stripped) }
            else { DispatchQueue.main.async { apply(stripped) } }
            return
        }

        // fallback, reread from disk
        if let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = docDir.appendingPathComponent("Courses.json")
            if let data = try? Data(contentsOf: fileURL) {
                let stripped = Updater.shared.stripCommentLines(from: data)
                if Thread.isMainThread { apply(stripped) }
                else { DispatchQueue.main.async { apply(stripped) } }
            }
        }
    }

    // MARK: - Preset selection
    func selectPreset(_ id: String) {
        assert(Thread.isMainThread, "selectPreset must be called on main")
        guard let root = root, let p = root.presets?.first(where: { $0.id == id }) else { return }
        currentPreset = p

        // restore module selections from defaults
        selectionsByModule.removeAll()
        for (i, module) in p.modules.enumerated() {
            selectionsByModule[i] = []
            let key = "config_\(p.id)_mod_\(i)"
            if let arr = UserDefaults.standard.array(forKey: key) as? [Int] {
                for idx in arr where idx >= 0 && idx < module.subjects.count {
                    let subj = module.subjects[idx]
                    selectionsByModule[i]?.append(SelectionEntry(itemIndex: idx, subjectId: subj.id))
                }
            }
        }

        rebuildActiveSubjects()

        // restore per-subject selections
        let levelKey = "config_\(p.id)_levels"
        let scoreKey = "config_\(p.id)_scores"
        let mapChoiceKey = "config_\(p.id)_scoreMapChoice"
        let globalKey = "config_\(p.id)_globalScoringByMap"
        let trackKey = "config_\(p.id)_trackToggle"

        if let data = UserDefaults.standard.data(forKey: levelKey),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            selectedLevelIndicesBySubject = dict
        } else {
            ensureDefaultIndices(for: activeSubjects, in: &selectedLevelIndicesBySubject)
        }
        if let data = UserDefaults.standard.data(forKey: scoreKey),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            selectedScoreIndicesBySubject = dict
        } else {
            ensureDefaultIndices(for: activeSubjects, in: &selectedScoreIndicesBySubject)
        }

        if let data = UserDefaults.standard.data(forKey: mapChoiceKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            selectedScoreMapIdBySubject = dict
        } else {
            selectedScoreMapIdBySubject = [:]
        }

        if let data = UserDefaults.standard.data(forKey: globalKey),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            globalScoringChoiceByMapId = dict
        } else {
            globalScoringChoiceByMapId = [:]
        }

        // restore track toggle (default true)
        if let saved = UserDefaults.standard.object(forKey: trackKey) as? Bool {
            trackToggleByPreset[p.id] = saved
        } else if p.track != nil {
            trackToggleByPreset[p.id] = true
        } else {
            trackToggleByPreset[p.id] = false
        }
        
        trackActive = p.track != nil ? (trackToggleByPreset[p.id] ?? true) : false
        validateRulesAndRecompute()
    }

    // MARK: - Active subjects
    private func rebuildActiveSubjects() {
        guard let p = currentPreset else { activeSubjects = []; return }
        var active: [CourseModel.Subject] = []
        for (modIndex, module) in p.modules.enumerated() {
            if module.type == "core" {
                active.append(contentsOf: module.subjects)
            } else {
                let selected = selectionsByModule[modIndex]?.map { $0.itemIndex } ?? []
                for idx in selected where idx < module.subjects.count {
                    active.append(module.subjects[idx])
                }
            }
        }
        
        activeSubjects = active
        ensureDefaultIndices(for: activeSubjects, in: &selectedLevelIndicesBySubject)
        ensureDefaultIndices(for: activeSubjects, in: &selectedScoreIndicesBySubject)
    }

    // MARK: - Level/score accessors
    func selectedLevelIndex(for subjectIndex: Int) -> Int {
        guard subjectIndex < activeSubjects.count else { return 0 }
        return selectedLevelIndicesBySubject[subjectKey(for: activeSubjects[subjectIndex])] ?? 0
    }

    func setLevelIndex(_ idx: Int, for subjectIndex: Int) {
        guard subjectIndex < activeSubjects.count else { return }
        selectedLevelIndicesBySubject[subjectKey(for: activeSubjects[subjectIndex])] = idx

        // when level changes, the score map may change (e.g. switching to/from AP level).
        // so clamp the score index to the new map's bounds.
        let subj = activeSubjects[subjectIndex]
        let key = subjectKey(for: subj)
        let map = scoreMapForSubject(subj)
        if let currentScore = selectedScoreIndicesBySubject[key], currentScore >= map.count {
            selectedScoreIndicesBySubject[key] = max(0, map.count - 1)
        }

        persistSelections()
        validateRulesAndRecompute()
    }

    func selectedScoreIndex(for subjectIndex: Int) -> Int {
        guard subjectIndex < activeSubjects.count else { return 0 }
        return selectedScoreIndicesBySubject[subjectKey(for: activeSubjects[subjectIndex])] ?? 0
    }

    func setScoreIndex(_ idx: Int, for subjectIndex: Int) {
        guard subjectIndex < activeSubjects.count else { return }
        selectedScoreIndicesBySubject[subjectKey(for: activeSubjects[subjectIndex])] = idx
        persistSelections()
        recomputeGPA()
    }

    // MARK: - Module selection toggles

    func toggleSelection(modIndex: Int, itemIndex: Int) {
        guard let p = currentPreset, modIndex < p.modules.count else { return }
        if publishedEffectiveLimit(for: modIndex) == 0 { return }

        let module = p.modules[modIndex]
        var entries = selectionsByModule[modIndex] ?? []

        // deselect if already selected
        if let existing = entries.firstIndex(where: { $0.itemIndex == itemIndex }) {
            entries.remove(at: existing)
            selectionsByModule[modIndex] = entries
            persistSelections()
            rebuildActiveSubjects()
            validateRulesAndRecompute()
            return
        }

        // tag-limit displacement using fifo
        var tagLimits: [String: Int] = [:]
        if let lims = p.rules?.tagLimits {
            for l in lims { tagLimits[l.tag] = l.limit }
        }

        let subj = module.subjects[itemIndex]
        if let tags = subj.tags {
            for tag in tags where tagLimits[tag] == 1 {
                // try same module first
                if let idx = entries.firstIndex(where: { entryHasTag($0, tag: tag, in: p) }) {
                    entries.remove(at: idx)
                    selectionsByModule[modIndex] = entries
                } else {
                    // for cross-module, remove first entry found with this tag
                    removeFirstEntryWithTag(tag, in: p)
                }
            }
        }

        // append new entry
        let newEntry = SelectionEntry(itemIndex: itemIndex, subjectId: subj.id)
        entries.append(newEntry)

        // enforce module limit
        if let maxLim = module.limit, entries.count > maxLim {
            entries.removeFirst(entries.count - maxLim)
        }

        selectionsByModule[modIndex] = entries
        persistSelections()
        rebuildActiveSubjects()
        validateRulesAndRecompute()
    }

    func isSelected(modIndex: Int, itemIndex: Int) -> Bool {
        selectionsByModule[modIndex]?.contains(where: { $0.itemIndex == itemIndex }) ?? false
    }

    // determines if a subject in a choice module should be grayed out / locked
    // relies on the pre-computed disabledIndicesByModule from rule evaluation
    // + a live check for cross-module ID uniqueness and module-level locks
    func isDisabled(modIndex: Int, itemIndex: Int) -> Bool {
        guard let p = currentPreset else { return true }
        guard p.modules.indices.contains(modIndex) else { return true }
        let module = p.modules[modIndex]
        guard module.subjects.indices.contains(itemIndex) else { return true }

        // already disabled by rule evaluation (exclusion tags/IDs, capped tags, limit == 0)
        if disabledIndicesByModule[modIndex]?.contains(itemIndex) == true {
            return true
        }

        // module is locked
        if publishedEffectiveLimit(for: modIndex) == 0 {
            return true
        }

        // cross-module duplicate ID check
        let subj = module.subjects[itemIndex]
        if !subj.id.isEmpty && !isSelected(modIndex: modIndex, itemIndex: itemIndex) {
            if selectedIdsSet().contains(subj.id) {
                return true
            }
        }

        return false
    }

    // MARK: - Rule checks

    // evaluates all rules, publishes state, clears locked modules, and recomputes GPA
    // the ONLY function that applies rule state
    private func validateRulesAndRecompute() {
        assert(Thread.isMainThread, "validateRulesAndRecompute must be called on main")
        var state = evaluateRulesInternal()

        // if any modules became locked (limit == 0), clear their selections and re-evaluate
        let modulesToClear = state.effectiveLimits.filter { $0.value == 0 }.map { $0.key }
        if !modulesToClear.isEmpty {
            for mod in modulesToClear {
                NotificationCenter.default.post(
                    name: Notification.Name("ModuleShouldCollapse"),
                    object: nil,
                    userInfo: ["moduleIndex": mod]
                )
                selectionsByModule[mod] = []
            }
            persistSelections()
            rebuildActiveSubjects()
            state = evaluateRulesInternal()
        }

        applyRuleState(state)
        recomputeGPA()
    }

    private func evaluateRulesInternal() -> RuleState {
        guard let p = currentPreset else { return RuleState() }

        let activeTags = activeTagsCounts()
        var moduleSelectionCounts: [Int: Int] = [:]
        for i in p.modules.indices { moduleSelectionCounts[i] = selectionsByModule[i]?.count ?? 0 }
        let allSelectedIds = selectedIdsSet()

        // build the subject ID : location map
        var subjectIdToLocation: [String: (Int, Int)] = [:]
        for (mIdx, module) in p.modules.enumerated() {
            for (sIdx, subj) in module.subjects.enumerated() {
                subjectIdToLocation[subj.id] = (mIdx, sIdx)
            }
        }

        // exclusion tags
        var excludedTags = Set<String>()
        if let exclusionGroups = p.rules?.exclusionTags {
            for group in exclusionGroups {
                if group.contains(where: { activeTags[$0, default: 0] > 0 }) {
                    for tag in group where activeTags[tag, default: 0] == 0 {
                        excludedTags.insert(tag)
                    }
                }
            }
        }

        // exclusion IDs
        var excludedIds = Set<String>()
        if let exclusionIdGroups = p.rules?.exclusionIds {
            for group in exclusionIdGroups {
                if group.contains(where: { allSelectedIds.contains($0) }) {
                    for id in group where !allSelectedIds.contains(id) {
                        excludedIds.insert(id)
                    }
                }
            }
        }

        // capped tag limits
        var cappedTags = Set<String>()
        if let limits = p.rules?.tagLimits {
            for lim in limits where activeTags[lim.tag, default: 0] >= lim.limit {
                cappedTags.insert(lim.tag)
            }
        }

        // dynamic limits
        var effectiveLimits: [Int: Int] = [:]
        for (i, m) in p.modules.enumerated() { effectiveLimits[i] = m.limit ?? 1 }
        if let dynamic = p.rules?.dynamicLimits {
            for rule in dynamic {
                let count = moduleSelectionCounts[rule.triggerModuleIndex] ?? 0
                if matchesCondition(count: count, condition: rule.triggerCondition) {
                    for target in rule.targetModuleIndices {
                        effectiveLimits[target] = rule.newLimit
                    }
                }
            }
        }

        // direct requirements
        var requirementWarnings: [String] = []
        var requiredSubjects = Set<String>()
        var modulesRequired = Set<Int>()

        if let requirements = p.rules?.requirements {
            for req in requirements {
                if activeTags[req.triggerTag, default: 0] > 0 {
                    let met = req.requiredAnyTag.contains { activeTags[$0, default: 0] > 0 }
                    if !met {
                        requirementWarnings.append(req.errorMessage)
                        for module in p.modules where module.type != "core" {
                            for subj in module.subjects {
                                if let tags = subj.tags, tags.contains(where: { req.requiredAnyTag.contains($0) }) {
                                    requiredSubjects.insert(subj.id.isEmpty ? subj.name : subj.id)
                                }
                            }
                        }
                    }
                }
            }
        }

        // conditional requirements
        if let conds = p.rules?.conditionalRequirements {
            for cond in conds {
                let triggerFired = evaluateConditionalTrigger(
                    cond.trigger,
                    allSelectedIds: allSelectedIds,
                    moduleSelectionCounts: moduleSelectionCounts,
                    subjectIdToLocation: subjectIdToLocation,
                    preset: p
                )

                if triggerFired {
                    if let enforcements = cond.enforceModuleLimits {
                        for e in enforcements {
                            effectiveLimits[e.moduleIndex] = e.newLimit
                        }
                    }

                    if let requiredAny = cond.requiresAnyOfSubjectIds, !requiredAny.isEmpty {
                        let filteredRequiredAny = requiredAny.filter { id in
                            guard let loc = subjectIdToLocation[id] else { return true }
                            return effectiveLimits[loc.0] ?? 1 > 0
                        }

                        if !filteredRequiredAny.isEmpty && !filteredRequiredAny.contains(where: { allSelectedIds.contains($0) }) {
                            requirementWarnings.append(cond.errorMessage ?? "Requirement not met")
                            for rid in filteredRequiredAny {
                                requiredSubjects.insert(rid)
                            }
                        }
                    }
                }
            }
        }

        // minSelection requirements
        for (modIndex, module) in p.modules.enumerated() {
            if let minSel = module.minSelection {
                let current = selectionsByModule[modIndex]?.count ?? 0
                if current < minSel { modulesRequired.insert(modIndex) }
            }
        }

        // build disabled indices map
        var disabledByModule: [Int: Set<Int>] = [:]
        for (modIndex, module) in p.modules.enumerated() {
            var disabled: Set<Int> = []
            let selectedIndices = Set(selectionsByModule[modIndex]?.map { $0.itemIndex } ?? [])
            for (idx, subj) in module.subjects.enumerated() {
                if selectedIndices.contains(idx) { continue }
                if let tags = subj.tags, tags.contains(where: { excludedTags.contains($0) }) {
                    disabled.insert(idx); continue
                }
                if excludedIds.contains(subj.id) {
                    disabled.insert(idx); continue
                }
                if allSelectedIds.contains(subj.id) {
                    disabled.insert(idx); continue
                }
                if let tags = subj.tags, tags.contains(where: { cappedTags.contains($0) }) {
                    disabled.insert(idx); continue
                }
                if effectiveLimits[modIndex] == 0 {
                    disabled.insert(idx); continue
                }
            }
            disabledByModule[modIndex] = disabled
        }

        let invalid = !requirementWarnings.isEmpty || !modulesRequired.isEmpty
        return RuleState(
            disabledByModule: disabledByModule,
            effectiveLimits: effectiveLimits,
            requirementWarning: requirementWarnings.first,
            requiredSubjects: requiredSubjects,
            modulesRequired: modulesRequired,
            invalid: invalid
        )
    }

    private func applyRuleState(_ state: RuleState) {
        disabledIndicesByModule = state.disabledByModule
        effectiveLimitsByModule = state.effectiveLimits
        requirementWarning = state.requirementWarning
        requiredSubjectIDs = state.requiredSubjects
        modulesRequiringSelection = state.modulesRequired
        isInvalidated = state.invalid
    }

    // MARK: - Conditional trigger evaluation

    private func evaluateConditionalTrigger(
        _ trigger: CourseModel.PresetTrigger,
        allSelectedIds: Set<String>,
        moduleSelectionCounts: [Int: Int],
        subjectIdToLocation: [String: (Int, Int)],
        preset p: CourseModel.Preset
    ) -> Bool {
        let triggerSelectedIds = trigger.selectedSubjectIds ?? []

        var selectedIdsTrigger = false
        var moduleConditionsTrigger = false

        if !triggerSelectedIds.isEmpty {
            selectedIdsTrigger = triggerSelectedIds.contains(where: { allSelectedIds.contains($0) })
        }

        if let moduleConds = trigger.moduleConditions, !moduleConds.isEmpty {
            var allMet = true
            for mc in moduleConds {
                let count = moduleSelectionCounts[mc.moduleIndex] ?? 0
                if let exact = mc.exactCount, count != exact { allMet = false; break }
                if let minSel = mc.minSelected, count < minSel { allMet = false; break }
                if let reqTag = mc.requireTag {
                    var found = false
                    if let entries = selectionsByModule[mc.moduleIndex] {
                        for e in entries {
                            if let loc = subjectIdToLocation[e.subjectId] {
                                let subjDef = p.modules[loc.0].subjects[loc.1]
                                
                                // check subject's own tags
                                if subjDef.tags?.contains(reqTag) == true { found = true; break }
                                
                                // check selected level's tags
                                let sKey = subjectKey(for: subjDef)
                                if let lvlIdx = selectedLevelIndicesBySubject[sKey],
                                   subjDef.levels.indices.contains(lvlIdx),
                                   subjDef.levels[lvlIdx].tags?.contains(reqTag) == true {
                                    found = true; break
                                }
                            }
                        }
                    }
                    if !found { allMet = false; break }
                }
            }
            moduleConditionsTrigger = allMet
        }

        // both must validate if both are specified
        if trigger.selectedSubjectIds != nil && trigger.moduleConditions != nil {
            return selectedIdsTrigger && moduleConditionsTrigger
        } else if trigger.selectedSubjectIds != nil {
            return selectedIdsTrigger
        } else if trigger.moduleConditions != nil {
            return moduleConditionsTrigger
        }
        return false
    }

    // MARK: - Score maps

    // returns the ScoreMap for a Subject, considering Track overrides
    // PRIORITY:
    //  | customMap
    //  | track override (if level tag matches and track is active)
    //  | subject scoreMapID
    //  v default
    func scoreMapForSubject(_ subj: CourseModel.Subject) -> [CourseModel.ScoreEntry] {
        if let custom = subj.customMap, !custom.isEmpty { return custom }

        // if
        //  1) the preset has a track, the subject's selected level, AND
        //  2) has a tag matching the track ID, AND
        //  3) the track toggle is on:
        //    `--> use the track's score map
        if let p = currentPreset, let track = p.track {
            let key = subjectKey(for: subj)
            let lvlIdx = selectedLevelIndicesBySubject[key] ?? 0
            if subj.levels.indices.contains(lvlIdx) {
                let level = subj.levels[lvlIdx]
                if level.tags?.contains(track.id) == true,
                   trackToggleByPreset[p.id] ?? true,
                   let trackMap = scoreMapsById[track.scoreMapId] {
                    return trackMap
                }
            }
        }

        if let sid = subj.scoreMapId, let map = scoreMapsById[sid] { return map }
        return scoreMapsById[defaultScoreMapId] ?? []
    }

    // MARK: - UI module status

    func moduleStatusText(modIndex: Int) -> String {
        guard let p = currentPreset, p.modules.indices.contains(modIndex) else { return "" }
        let sel = selectionsByModule[modIndex]?.count ?? 0
        let limit = publishedEffectiveLimit(for: modIndex)
        if limit == 0 { return "Disabled" }
        if let minSel = p.modules[modIndex].minSelection, minSel > 0 {
            return "\(sel) selected (min \(minSel))"
        }
        return "\(sel) selected"
    }

    func moduleStatusColor(modIndex: Int) -> Color {
        if publishedEffectiveLimit(for: modIndex) == 0 { return .gray }
        if modulesRequiringSelection.contains(modIndex) { return .red }
        return .secondary
    }

    func resetSelections() {
        guard let p = currentPreset else { return }
        for i in p.modules.indices {
            selectionsByModule[i] = []
            UserDefaults.standard.removeObject(forKey: "config_\(p.id)_mod_\(i)")
        }
        persistSelections()
        rebuildActiveSubjects()
        validateRulesAndRecompute()
    }

    // MARK: - Persistence

    private func persistSelections() {
        guard let p = currentPreset else { return }

        if let data = try? JSONEncoder().encode(selectedLevelIndicesBySubject) {
            UserDefaults.standard.set(data, forKey: "config_\(p.id)_levels")
        }
        if let data = try? JSONEncoder().encode(selectedScoreIndicesBySubject) {
            UserDefaults.standard.set(data, forKey: "config_\(p.id)_scores")
        }
        if let data = try? JSONEncoder().encode(selectedScoreMapIdBySubject) {
            UserDefaults.standard.set(data, forKey: "config_\(p.id)_scoreMapChoice")
        }
        if let data = try? JSONEncoder().encode(globalScoringChoiceByMapId) {
            UserDefaults.standard.set(data, forKey: "config_\(p.id)_globalScoringByMap")
        }
        UserDefaults.standard.set(trackToggleByPreset[p.id] ?? true, forKey: "config_\(p.id)_trackToggle")

        for i in p.modules.indices {
            let arr = selectionsByModule[i]?.map { $0.itemIndex } ?? []
            UserDefaults.standard.set(arr, forKey: "config_\(p.id)_mod_\(i)")
        }
    }

    // MARK: - GPA algo

    private func recomputeGPA() {
        assert(Thread.isMainThread, "recomputeGPA must be called on main")

        guard currentPreset != nil else {
            calculationResultText = "whoops"
            return
        }

        var totalWeightedPoints: Double = 0.0
        var totalWeight: Double = 0.0

        // algorithm: (thisWeight / sumWeights) * (thisGPA - offset)
        for subj in activeSubjects {
            let key = subjectKey(for: subj)
            let lvlIdx = selectedLevelIndicesBySubject[key] ?? 0
            let safeLvlIdx = min(max(0, lvlIdx), subj.levels.count - 1)
            let level = subj.levels.indices.contains(safeLvlIdx)
                ? subj.levels[safeLvlIdx]
                : CourseModel.Level(name: "", offset: 0.0, weightOverride: nil, tags: nil)

            let scoreIdx = selectedScoreIndicesBySubject[key] ?? 0
            let map = scoreMapForSubject(subj)
            let baseGPA: Double = map.indices.contains(scoreIdx) ? map[scoreIdx].gpa : (map.last?.gpa ?? 0.0)

            let minOffset = subj.levels.map { $0.offset }.min() ?? 0.0
            let effectiveOffset = max(0.0, level.offset - minOffset)
            let subjectGPA = max(0.0, baseGPA - effectiveOffset)
            let weightForPoints = level.weightOverride ?? subj.weight
            let weightForCredits = subj.weight

            totalWeightedPoints += subjectGPA * weightForPoints
            totalWeight += weightForCredits
        }

        if totalWeight > 0 {
            let finalGPA = totalWeightedPoints / totalWeight
            calculationResultText = String(format: "Your GPA: %.3f", finalGPA)
        } else {
            calculationResultText = "whoops"
        }
    }

    // MARK: - helpers

    private func subjectKey(for subj: CourseModel.Subject) -> String {
        subj.id.isEmpty ? subj.name : subj.id
    }

    // counts active tags from both subject-level tags and selected level tags
    private func activeTagsCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for subj in activeSubjects {
            
            // subject-level tags: ALWAYS active
            if let tags = subj.tags {
                for t in tags { counts[t, default: 0] += 1 }
            }
            
            // selected level's tags: active ONLY when that level is chosen
            // eg. a Physics course is considered AP only if the AP level is chosen
            // otherwise, in S, H, etc. it's not considered AP
            let key = subjectKey(for: subj)
            if let lvlIdx = selectedLevelIndicesBySubject[key],
               subj.levels.indices.contains(lvlIdx),
               let lvlTags = subj.levels[lvlIdx].tags {
                for t in lvlTags {
                    counts[t, default: 0] += 1
                }
            }
        }
        return counts
    }

    private func selectedIdsSet() -> Set<String> {
        var s = Set<String>()
        for (_, entries) in selectionsByModule {
            for e in entries { s.insert(e.subjectId) }
        }
        return s
    }

    private func ensureDefaultIndices(for subjects: [CourseModel.Subject], in dict: inout [String: Int]) {
        for subj in subjects {
            let key = subjectKey(for: subj)
            if dict[key] == nil { dict[key] = 0 }
        }
    }

    private func matchesCondition(count: Int, condition: String) -> Bool {
        if condition.hasPrefix(">=") {
            if let val = Int(condition.dropFirst(2).trimmingCharacters(in: .whitespaces)) {
                return count >= val
            }
        } else if condition.hasPrefix("==") {
            if let val = Int(condition.dropFirst(2).trimmingCharacters(in: .whitespaces)) {
                return count == val
            }
        }
        return false
    }

    // checks if a SelectionEntry's subject has a given tag (looks up from preset definition)
    private func entryHasTag(_ entry: SelectionEntry, tag: String, in preset: CourseModel.Preset) -> Bool {
        for module in preset.modules {
            if let subj = module.subjects.first(where: { $0.id == entry.subjectId }) {
                return subj.tags?.contains(tag) == true
            }
        }
        return false
    }

    // removes the first entry across all modules that has the given tag, FIFO
    private func removeFirstEntryWithTag(_ tag: String, in preset: CourseModel.Preset) {
        for (mIdx, entries) in selectionsByModule {
            if let idx = entries.firstIndex(where: { entryHasTag($0, tag: tag, in: preset) }) {
                selectionsByModule[mIdx]?.remove(at: idx)
                return
            }
        }
    }
}
