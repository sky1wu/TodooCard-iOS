import Foundation

/// 一圈活动圆环：当前值与目标值。系统还没给出目标时（goal 为 0）按“未开始”处理，
/// 而不是让百分比变成无穷大。
public struct ActivityRingMetric: Equatable, Sendable {
    public let value: Double
    public let goal: Double

    public init(value: Double, goal: Double) {
        self.value = value.isFinite ? max(0, value) : 0
        self.goal = goal.isFinite ? max(0, goal) : 0
    }

    /// 当前这一圈画到哪里，0–1。超过目标的部分不再多画一圈，交给 percent 说明。
    public var fraction: Double {
        guard goal > 0 else { return 0 }
        return min(1, max(0, value / goal))
    }

    public var isComplete: Bool { goal > 0 && value >= goal }

    /// 完成百分比，超过目标后继续往上走。
    public var percent: Int {
        guard goal > 0 else { return 0 }
        return Int((value / goal * 100).rounded())
    }
}

/// 昨晚各睡眠阶段的累计时长。只有 Apple Watch 会分出深度 / 核心 / REM，
/// 仅有 iPhone 或第三方 App 记录时全部落在 unspecified 上。
public struct SleepStageTotals: Equatable, Sendable {
    public var deep: TimeInterval
    public var core: TimeInterval
    public var rem: TimeInterval
    public var unspecified: TimeInterval
    public var awake: TimeInterval

    public init(
        deep: TimeInterval = 0,
        core: TimeInterval = 0,
        rem: TimeInterval = 0,
        unspecified: TimeInterval = 0,
        awake: TimeInterval = 0
    ) {
        self.deep = max(0, deep)
        self.core = max(0, core)
        self.rem = max(0, rem)
        self.unspecified = max(0, unspecified)
        self.awake = max(0, awake)
    }

    public var asleep: TimeInterval { deep + core + rem + unspecified }
    public var inBed: TimeInterval { asleep + awake }
    public var hasStageDetail: Bool { deep > 0 || core > 0 || rem > 0 }
}

public enum SleepGrade: String, Sendable {
    case excellent
    case good
    case fair
    case poor

    public var title: String {
        switch self {
        case .excellent: return "优秀"
        case .good: return "良好"
        case .fair: return "一般"
        case .poor: return "欠佳"
        }
    }
}

/// 「健康」App 不通过 HealthKit 暴露睡眠评分，这里的分数是本机按时长、阶段占比和
/// 连续性估算出来的，卡片上也照实标注。
public struct SleepScore: Equatable, Sendable {
    public let value: Int
    public let grade: SleepGrade
    /// 有没有拿到深度 / 核心 / REM 分段。没有时只按时长和连续性打分。
    public let usesStageDetail: Bool

    public init(value: Int, grade: SleepGrade, usesStageDetail: Bool) {
        self.value = value
        self.grade = grade
        self.usesStageDetail = usesStageDetail
    }
}

public enum SleepScoring {
    public static let targetSleep: TimeInterval = 8 * 3_600
    /// 成人参考区间的中位数：深度约 13%–23%，REM 约 20%–25%。
    public static let idealDeepRatio = 0.17
    public static let idealREMRatio = 0.21
    /// 超过这个时长后再睡就开始扣分。
    public static let oversleepThreshold: TimeInterval = 10 * 3_600

    public static func score(totals: SleepStageTotals, awakenings: Int) -> SleepScore {
        let asleep = totals.asleep
        guard asleep > 0 else {
            return SleepScore(value: 0, grade: .poor, usesStageDetail: false)
        }

        var durationPoints = min(1, asleep / targetSleep)
        if asleep > oversleepThreshold {
            // 睡过头同样不是满分，但扣分有上限，免得一次赖床把整晚判成欠佳。
            let excessHours = (asleep - oversleepThreshold) / 3_600
            durationPoints -= min(0.2, excessHours * 0.1)
        }
        durationPoints = min(1, max(0, durationPoints))

        let continuity = continuityFactor(totals: totals, awakenings: awakenings)

        let total: Double
        if totals.hasStageDetail {
            let deepPoints = min(1, max(0, totals.deep / asleep / idealDeepRatio))
            let remPoints = min(1, max(0, totals.rem / asleep / idealREMRatio))
            total = durationPoints * 55 + deepPoints * 15 + remPoints * 15 + continuity * 15
        } else {
            total = durationPoints * 75 + continuity * 25
        }

        let value = min(100, max(0, Int(total.rounded())))
        return SleepScore(value: value, grade: grade(for: value), usesStageDetail: totals.hasStageDetail)
    }

    public static func grade(for value: Int) -> SleepGrade {
        switch value {
        case 85...: return .excellent
        case 70 ..< 85: return .good
        case 55 ..< 70: return .fair
        default: return .poor
        }
    }

    /// 清醒时长占比和醒来次数各占一部分：整夜零星醒几次很正常，长时间清醒才要扣分。
    private static func continuityFactor(totals: SleepStageTotals, awakenings: Int) -> Double {
        let inBed = totals.inBed
        let awakeRatio = inBed > 0 ? totals.awake / inBed : 0
        let awakePart = min(1, max(0, 1 - awakeRatio / 0.2))
        let countPart = min(1, max(0, 1 - Double(max(0, awakenings)) / 6))
        return awakePart * 0.6 + countPart * 0.4
    }
}

/// “7 小时 32 分”。不足一小时时只写分钟。
public func formatSleepDuration(_ seconds: TimeInterval) -> String {
    let minutes = roundedMinutes(seconds)
    let hours = minutes / 60
    let remainder = minutes % 60
    guard hours > 0 else { return "\(remainder) 分" }
    guard remainder > 0 else { return "\(hours) 小时" }
    return "\(hours) 小时 \(remainder) 分"
}

/// “7时32分”。给阶段图例这种横向空间紧张的地方用。
public func formatCompactDuration(_ seconds: TimeInterval) -> String {
    let minutes = roundedMinutes(seconds)
    let hours = minutes / 60
    let remainder = minutes % 60
    guard hours > 0 else { return "\(remainder)分" }
    return "\(hours)时\(remainder)分"
}

/// “12,486”。卡片上的数字要一眼看出量级，千分位比 NumberFormatter 的区域设置更可控。
public func formatGroupedNumber(_ value: Int) -> String {
    let digits = Array(String(value.magnitude))
    var grouped = ""
    for (offset, digit) in digits.enumerated() {
        if offset > 0, (digits.count - offset).isMultiple(of: 3) { grouped.append(",") }
        grouped.append(digit)
    }
    return (value < 0 ? "-" : "") + grouped
}

private func roundedMinutes(_ seconds: TimeInterval) -> Int {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int((seconds / 60).rounded())
}
