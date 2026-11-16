import Foundation

/// 内置课来自安卓已审阅的结构侧车；生成器检查每个单元原文指纹，运行时不拆分标点。
enum NivoCoachCurriculum {
    static let protocolVersion = "coach-curriculum-v3"

    private struct Catalogue: Decodable {
        var `protocol`: String
        var courses: [NivoCoachCourse]
    }

    /// 资源缺失或损坏时显式失败，不能静默显示一个看似正常的空能力地图。
    static func seededTracks() throws -> [NivoCoachTrack] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        let url = bundle.url(forResource: "coach-curriculum", withExtension: "json")
            ?? bundle.url(forResource: "coach-curriculum", withExtension: "json", subdirectory: "Resources")
        guard let url else { throw NivoLifeError.notFound("coach_curriculum") }
        let catalogue = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: url))
        guard catalogue.protocol == protocolVersion, !catalogue.courses.isEmpty else { throw NivoLifeError.corruptStore }
        return try catalogue.courses.map { course in
            try NivoCoachDraftRules.validate(course)
            guard let first = course.units.first else { throw NivoLifeError.corruptStore }
            return NivoCoachTrack(course: course, currentUnitID: first.id)
        }
    }

    /// 只更新原文仍与内置源一致的路径，自定义课程和历史课程快照保持可回看。
    static func migrate(_ original: NivoCoachState, seeds: [NivoCoachTrack]) throws -> NivoCoachState {
        var state = original
        var changed = Set<String>()
        for index in state.tracks.indices {
            let track = state.tracks[index]
            guard let seed = seeds.first(where: { $0.id == track.id }), seed.course.source == track.course.source,
                  seed.course.version != track.course.version else { continue }
            state.tracks[index].course = seed.course
            state.tracks[index].demonstrated = []
            if !seed.course.units.contains(where: { $0.id == track.currentUnitID }) { state.tracks[index].currentUnitID = seed.currentUnitID }
            changed.insert(track.id)
        }
        let existing = Set(state.tracks.map(\.id))
        state.tracks.append(contentsOf: seeds.filter { !existing.contains($0.id) })
        for index in state.sessions.indices where changed.contains(state.sessions[index].course.id) {
            if state.sessions[index].status != "complete" { state.sessions[index].status = "paused" }
            state.sessions[index].requiresCourseReview = true
            state.sessions[index].revision = try NivoCoachReducer.increment(state.sessions[index].revision)
        }
        return state
    }
}
