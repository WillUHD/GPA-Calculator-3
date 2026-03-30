//
//  CourseModel.swift
//  GPACalc
//
//  Created by willuhd on 3/4/26
//  Original project by LegitMichel777
//
//  Copyright (c) 2026, under the GPA Calculator project.
//  Proprietary, internal use only. All Rights Reserved.
//

import Foundation

public struct CourseModel: Codable {
    public var catalogName: String?
    public var version: String?
    public var lastUpdated: String?
    public var credit: String?
    public var scoreMap: [ScoreEntry]?
    public var scoreMaps: [String: [ScoreEntry]]?
    public var templates: [Template]?
    public var presets: [Preset]?

    public struct ScoreEntry: Codable {
        public var percent: String
        public var letter: String
        public var gpa: Double
    }

    public struct Level: Codable {
        public var name: String
        public var offset: Double
        public var weightOverride: Double?
        public var tags: [String]?
    }

    public struct Template: Codable {
        public var id: String
        public var weight: Double
        public var levels: [Level]
        public var tags: [String]?
        public var scoreMapId: String?
    }

    public struct Subject: Codable, Identifiable {
        public var id: String
        public var name: String
        public var weight: Double
        public var levels: [Level]
        public var customMap: [ScoreEntry]?
        public var tags: [String]?
        public var scoreMapId: String?
        public var template: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            if let explicitId = try? container.decode(String.self, forKey: .id) {
                self.id = explicitId
            } else {
                self.id = self.name
            }
            self.weight = try container.decodeIfPresent(Double.self, forKey: .weight) ?? 0.0
            self.levels = try container.decodeIfPresent([Level].self, forKey: .levels) ?? []
            self.customMap = try? container.decode([ScoreEntry].self, forKey: .customMap)
            self.tags = try? container.decode([String].self, forKey: .tags)
            self.scoreMapId = try? container.decode(String.self, forKey: .scoreMapId)
            self.template = try? container.decode(String.self, forKey: .template)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(weight, forKey: .weight)
            try container.encode(levels, forKey: .levels)
            try container.encodeIfPresent(customMap, forKey: .customMap)
            try container.encodeIfPresent(tags, forKey: .tags)
            try container.encodeIfPresent(scoreMapId, forKey: .scoreMapId)
            try container.encodeIfPresent(template, forKey: .template)
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, weight, levels, customMap, tags, scoreMapId, template
        }
    }

    public struct Module: Codable {
        public var type: String // core or choice
        public var name: String?
        public var limit: Int?
        public var minSelection: Int?
        public var subjects: [Subject]
    }

    public struct TagLimit: Codable {
        public var tag: String
        public var limit: Int
    }

    public struct DynamicLimit: Codable {
        public var triggerModuleIndex: Int
        public var triggerCondition: String // ">= 2" or "== 1"
        public var targetModuleIndices: [Int]
        public var newLimit: Int
    }

    public struct PresetRequirement: Codable {
        public var triggerTag: String
        public var requiredAnyTag: [String]
        public var errorMessage: String
    }

    public struct PresetTriggerCondition: Codable {
        public var moduleIndex: Int
        public var minSelected: Int?
        public var exactCount: Int?
        public var requireTag: String?
    }

    public struct PresetTrigger: Codable {
        public var selectedSubjectIds: [String]?
        public var moduleConditions: [PresetTriggerCondition]?
    }

    public struct PresetModuleLimit: Codable {
        public var moduleIndex: Int
        public var newLimit: Int
    }

    public struct PresetConditional: Codable {
        public var id: String?
        public var trigger: PresetTrigger
        public var requiresAnyOfSubjectIds: [String]?
        public var enforceModuleLimits: [PresetModuleLimit]?
        public var errorMessage: String?
    }

    public struct PresetRules: Codable {
        public var exclusionTags: [[String]]?
        public var exclusionIds: [[String]]?
        public var tagLimits: [TagLimit]?
        public var dynamicLimits: [DynamicLimit]?
        public var requirements: [PresetRequirement]?
        public var conditionalRequirements: [PresetConditional]?
    }

    public struct PresetTrack: Codable {
        public var id: String
        public var scoreMapId: String
        public var displayName: String
    }

    public struct Preset: Codable, Identifiable {
        public var id: String
        public var name: String
        public var subtitle: String?
        public var modules: [Module]
        public var rules: PresetRules?
        public var track: PresetTrack?
    }
}

extension CourseModel.Subject {
    var stableId: String { id.isEmpty ? name : id }
}
