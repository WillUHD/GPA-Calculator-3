//
//  ContentView.swift
//  GPACalc
//
//  Created by willuhd on 3/4/26
//  Original project by LegitMichel777
//
//  Copyright (c) 2026, under the GPA Calculator project.
//  Proprietary, internal use only. All Rights Reserved.
//

import SwiftUI
import Combine
import UIKit

enum ScoreDisplay: Int, CaseIterable, Hashable {
    case percentage = 0
    case letter = 1
}

struct ContentView: View {
    @StateObject private var backend = Backend.shared
    @State private var showingCustomize = false

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Text("GPA Calculator")
                            .font(.system(size: 32, weight: .semibold))
                            .padding(.top, 20)
                        Text(backend.calculationResultText)
                            .font(.system(size: 18))
                            .foregroundColor(backend.isInvalidated ? .red : .secondary)
                    }

                    HStack(spacing: 16) {
                        Button(action: { Haptic.medium(); showingCustomize = true }) {
                            Text("Customize")
                                .font(.system(size: 18, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(10)

                        Button(action: {
                            Haptic.medium()
                            backend.resetAllLevelsAndScores()
                        }) {
                            Text("Reset")
                                .font(.system(size: 18, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                    }.padding(.horizontal, 16)

                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(Array(backend.activeSubjects.enumerated()), id: \.1.stableId) { idx, subject in
                                SubjectRowView(subject: subject, index: idx, backend: backend)
                                    .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 0)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("")
            .sheet(isPresented: $showingCustomize) { CustomizeView().environmentObject(backend) }
            .onAppear { backend.loadInitialData() }
        }.navigationViewStyle(StackNavigationViewStyle())
    }
}

struct SubjectRowView: View {
    let subject: CourseModel.Subject
    let index: Int
    @ObservedObject var backend: Backend

    private var liveSubject: CourseModel.Subject {
        backend.activeSubjects.indices.contains(index) ? backend.activeSubjects[index] : subject
    }

    var body: some View {
        let currentSubj = liveSubject
        
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Text(currentSubj.name).font(.system(size: 24, weight: .regular)).lineLimit(1).layoutPriority(1)
                    .foregroundColor(backend.requiredSubjectIDs.contains(currentSubj.id) ? .red : .primary)

                // Animations remain disabled here as requested (Selector uses UIView.performWithoutAnimation)
                ResponsiveSelector(
                    items: currentSubj.levels.map { $0.name },
                    selectedIndex: Binding(get: { backend.selectedLevelIndex(for: index) }, set: { backend.setLevelIndex($0, for: index) })
                ).frame(maxWidth: .infinity)
            }

            ResponsiveSelector(
                items: backend.scoreMapForSubject(currentSubj).map { backend.scoreDisplay == .percentage ? $0.percent : $0.letter },
                selectedIndex: Binding(get: { backend.selectedScoreIndex(for: index) }, set: { backend.setScoreIndex($0, for: index) })
            )
        }
        .padding(.vertical, 20).padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground)).cornerRadius(12)
    }
}

struct CustomizeView: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        scoreFormatBar
                        
                        if let warn = backend.requirementWarning {
                            Text(warn).foregroundColor(.red).padding(.horizontal)
                        }

                        presetGrid
                        
                        VStack(spacing: 16) {
                            ForEach(backend.choiceModules, id: \.modIndex) { mod in
                                ModuleSelector(module: mod.module, modIndex: mod.modIndex, backend: backend).padding(.horizontal)
                            }
                        }
                        
                        Text("\(backend.root?.catalogName ?? "Unspecified catalog")\nVersion \(backend.root?.version ?? "??"), last updated \(backend.root?.lastUpdated ?? "idk")\n\(backend.root?.credit ?? "Original project by Michel")")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.top, 8).padding(.horizontal)
                    }.padding(.vertical, 20)
                }
            }
            .navigationTitle("Customize").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { Haptic.medium(); presentationMode.wrappedValue.dismiss() }
                }
            }
        }.navigationViewStyle(StackNavigationViewStyle())
    }

    private var scoreFormatBar: some View {
        HStack(spacing: 12) {
            Text("Score Format").font(.system(size: 16, weight: .semibold)).layoutPriority(1)
            
            if let track = backend.currentPreset?.track {
                Button("Use \(track.displayName)") {
                    Haptic.medium()
                    var t = Transaction(); t.animation = nil
                    withTransaction(t) { backend.setTrackActive(!backend.trackActive) }
                }
                .font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(backend.trackActive ? Color.blue : Color(UIColor.systemGray4)))
                .foregroundColor(backend.trackActive ? .white : .secondary)
                .layoutPriority(1)
            }

            ResponsiveSelector(
                items: ["Percentage", "Letter"],
                selectedIndex: Binding(get: { backend.scoreDisplay.rawValue }, set: { if let n = ScoreDisplay(rawValue: $0) { backend.scoreDisplay = n } })
            ).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(Color(UIColor.secondarySystemGroupedBackground)).cornerRadius(10).padding(.horizontal, 16)
    }

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)], spacing: 13) {
            ForEach(backend.root?.presets ?? [], id: \.id) { p in
                let isSelected = (backend.currentPreset?.id == p.id)

                Button(action: {
                    Haptic.medium()
                    var t = Transaction(); t.animation = nil
                    withTransaction(t) { backend.selectPreset(p.id) }
                }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name).font(.system(size: 20, weight: .semibold)).foregroundColor(isSelected ? .white : .blue).frame(maxWidth: .infinity, alignment: .leading)
                            Text(p.subtitle ?? "\(p.modules.reduce(0) { $0 + $1.subjects.count }) items")
                                .font(.system(size: 13)).foregroundColor(isSelected ? .white.opacity(0.8) : .secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).foregroundColor(isSelected ? .white : .gray)
                    }
                    .padding().frame(height: 80).frame(maxWidth: .infinity)
                    .background(isSelected ? Color.blue : Color(UIColor.secondarySystemGroupedBackground)).cornerRadius(12)
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 16)
    }
}

struct ModuleSelector: View {
    let module: CourseModel.Module
    let modIndex: Int
    @ObservedObject var backend: Backend
    @State private var expanded = false

    var body: some View {
        let isLocked = backend.publishedEffectiveLimit(for: modIndex) == 0
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.name ?? "Module").font(.system(size: 18, weight: .bold))
                        .foregroundColor(backend.modulesRequiringSelection.contains(modIndex) ? .red : (isLocked ? .gray : .primary))
                    Text(backend.moduleStatusText(modIndex: modIndex)).font(.system(size: 14)).foregroundColor(backend.moduleStatusColor(modIndex: modIndex))
                }
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundColor(.gray)
            }
            .padding(.vertical, 18).padding(.horizontal, 16).background(Color(UIColor.secondarySystemGroupedBackground)).contentShape(Rectangle())
            .onTapGesture {
                if isLocked { Haptic.error() } else { Haptic.light(); withAnimation { expanded.toggle() } }
            }

            if expanded {
                VStack(spacing: 0) {
                    Divider()
                    ForEach(Array(module.subjects.enumerated()), id: \.1.stableId) { idx, subj in
                        let disabled = backend.isDisabled(modIndex: modIndex, itemIndex: idx)
                        let isSelected = backend.isSelected(modIndex: modIndex, itemIndex: idx)
                        
                        Button(action: { Haptic.medium(); backend.toggleSelection(modIndex: modIndex, itemIndex: idx) }) {
                            HStack {
                                Text(subj.name).font(.system(size: 16))
                                    .foregroundColor(backend.requiredSubjectIDs.contains(subj.id) ? .red : (disabled ? .gray : .primary))
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : (disabled ? "lock.fill" : "circle"))
                                    .foregroundColor(isSelected ? .blue : .gray)
                            }
                            .padding(.vertical, 14).padding(.horizontal, 16)
                        }
                        .disabled(disabled || isLocked).opacity((disabled || isLocked) ? 0.5 : 1.0)
                        
                        if idx < module.subjects.count - 1 { Divider().padding(.leading, 16) }
                    }
                }.background(Color(UIColor.secondarySystemGroupedBackground))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12)).opacity(isLocked ? 0.6 : 1.0)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ModuleShouldCollapse"))) { note in
            if let info = note.userInfo, let idx = info["moduleIndex"] as? Int, idx == modIndex {
                withAnimation { expanded = false }
            }
        }
    }
}

struct ResponsiveSelector: View {
    let items: [String]
    @Binding var selectedIndex: Int

    private let fontSize: CGFloat = 13
    private let itemHorizontalPadding: CGFloat = 12
    private let interItemSpacing: CGFloat = 4
    private let containerOuterMargin: CGFloat = 8
    private let componentHeight: CGFloat = 32
    private let evenModePadding: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width
            let textWidths = items.map { $0.width(usingFont: .systemFont(ofSize: fontSize, weight: .medium)) }
            let totalTextWidth = textWidths.reduce(0, +)
            let totalPadding = CGFloat(items.count) * itemHorizontalPadding
            let totalSpacing = CGFloat(max(0, items.count - 1)) * interItemSpacing
            let minRequiredWidth = totalTextWidth + totalPadding + totalSpacing + containerOuterMargin
            let maxTextWidth = textWidths.max() ?? 0
            let evenWidth = (maxTextWidth + evenModePadding) * CGFloat(items.count) + containerOuterMargin

            Group {
                if items.isEmpty {
                    EmptyView()
                } else if availableWidth < minRequiredWidth && items.count > 1 {
                    dropdownMenu
                } else {
                    Selector(
                        items: items,
                        selectedIndex: $selectedIndex,
                        evenlySpaced: availableWidth >= evenWidth
                    )
                    .frame(width: availableWidth, height: componentHeight)
                }
            }
        }
        .frame(height: componentHeight)
    }

    private var dropdownMenu: some View {
        Menu {
            ForEach(0..<items.count, id: \.self) { i in
                Button(items[i]) {
                    Haptic.light()
                    selectedIndex = i
                }
            }
        } label: {
            HStack {
                Text(items[safe: selectedIndex] ?? items.first ?? "")
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.systemGray5))
            .cornerRadius(6)
        }
    }
}

struct Selector: UIViewRepresentable {
    let items: [String]
    @Binding var selectedIndex: Int
    let evenlySpaced: Bool

    func makeUIView(context: Context) -> UISegmentedControl {
        let sc = UISegmentedControl(items: items)
        sc.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .valueChanged)
        return sc
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        UIView.performWithoutAnimation {
            if uiView.numberOfSegments != items.count {
                uiView.removeAllSegments()
                for (i, title) in items.enumerated() {
                    uiView.insertSegment(withTitle: title, at: i, animated: false)
                }
            } else {
                for (i, title) in items.enumerated() {
                    uiView.setTitle(title, forSegmentAt: i)
                }
            }
            uiView.selectedSegmentIndex = selectedIndex
            uiView.layoutIfNeeded()
        }
        uiView.apportionsSegmentWidthsByContent = !evenlySpaced
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        var parent: Selector
        init(_ parent: Selector) { self.parent = parent }
        @objc func changed(_ sc: UISegmentedControl) { parent.selectedIndex = sc.selectedSegmentIndex; Haptic.light() }
    }
}

// MARK: - Helpers
enum Haptic {
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

private extension String {
    func width(usingFont font: UIFont) -> CGFloat {
        ceil((self as NSString).size(withAttributes: [.font: font]).width)
    }
}
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
