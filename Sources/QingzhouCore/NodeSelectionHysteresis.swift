import Foundation

/// 运行时与离线回放共用的综合分数黏性。延迟只是评分的一维，不再另设延迟否决闸。
public struct NodeSelectionHysteresis: Sendable {
    public enum Decision: Sendable, Equatable {
        case proceed, holdForMargin
        case holdForStreak(completed: Int, required: Int)
    }
    public private(set) var decision: Decision = .proceed
    public static let defaultMargin: Double = 8
    public static let defaultRounds = 2
    private var challenger: String?
    private var incumbent: String?
    private var winningRounds = 0

    public init() {}

    public mutating func reset() {
        challenger = nil; incumbent = nil; winningRounds = 0
        decision = .proceed
    }

    public mutating func shouldHold(
        challenger challengerID: String, incumbent incumbentID: String?,
        challengerScore: Double, incumbentScore: Double,
        incumbentViable: Bool,
        margin: Double = Self.defaultMargin, rounds: Int = Self.defaultRounds
    ) -> Bool {
        guard let incumbentID, incumbentID != challengerID, incumbentViable else {
            reset(); return false
        }
        guard challengerScore - incumbentScore >= margin else {
            reset(); decision = .holdForMargin; return true
        }
        if challenger == challengerID, incumbent == incumbentID {
            winningRounds += 1
        } else {
            challenger = challengerID; incumbent = incumbentID; winningRounds = 1
        }
        if winningRounds >= max(1, rounds) { reset(); return false }
        decision = .holdForStreak(completed: winningRounds, required: max(1, rounds))
        return true
    }
}
