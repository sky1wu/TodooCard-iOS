import Foundation
import HealthKit
#if canImport(TodooCore)
  import TodooCore
#endif

/// 一次读取到的今日健康摘要。每一项都可能为空：用户可以只授权其中几项，
/// 没有 Apple Watch 时也拿不到圆环和睡眠阶段。
struct HealthSummarySnapshot: Sendable {
  let generatedAt: Date
  let move: ActivityRingMetric?
  let exercise: ActivityRingMetric?
  let stand: ActivityRingMetric?
  /// 「健康」里把活动圆环设成“移动时间”而不是“活动能量”时为真，单位要跟着换。
  let usesMoveTime: Bool
  let steps: Double?
  let distanceMeters: Double?
  let flights: Double?
  let restingHeartRate: Double?
  let sleep: SleepSummary?

  var hasAnyData: Bool {
    move != nil || exercise != nil || stand != nil
      || steps != nil || distanceMeters != nil || flights != nil
      || restingHeartRate != nil || sleep != nil
  }
}

/// 昨晚的主睡眠段。start / end 是这一段的实际入睡与起床时刻；数据由快捷指令传进来时
/// 通常只有时长，没有具体时刻，卡片会略过那一行。
struct SleepSummary: Sendable {
  let start: Date?
  let end: Date?
  let totals: SleepStageTotals
  let awakenings: Int
  let score: SleepScore
}

enum HealthSummaryError: LocalizedError {
  case unavailable
  case missingEntitlement
  case authorizationFailed(String)
  case noData
  case noShortcutInput

  /// HealthKit 只在错误里给一句英文原文，这里把最常见的一种翻成能照着做的说明。
  static func from(_ error: Error) -> HealthSummaryError {
    let description = error.localizedDescription
    if description.contains("com.apple.developer.healthkit")
      || description.localizedCaseInsensitiveContains("entitlement")
    {
      return .missingEntitlement
    }
    return .authorizationFailed(description)
  }

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "这台设备不支持「健康」数据。"
    case .missingEntitlement:
      return "这份安装包没有带上 HealthKit 权限，系统不允许它读取健康数据。用 Xcode 安装时，"
        + "在 TodooCard target 的 Signing & Capabilities 里加上 HealthKit 再重装；用 SideStore "
        + "重签名时，重签过程可能会剥掉这项权限。其他功能不受影响。"
    case .authorizationFailed(let message):
      return "无法读取「健康」数据：\(message)"
    case .noData:
      return "没有读到今天的健康数据。请在「设置 → 隐私与安全性 → 健康 → TodooCard」中允许读取活动、步数与睡眠。"
    case .noShortcutInput:
      return "快捷指令没有传入任何健康数据，请至少填写其中一项。"
    }
  }
}

enum HealthSummaryReader {
  private static let store = HKHealthStore()
  /// 从这么久以前开始找昨晚的睡眠段，足够覆盖“昨天下午睡到今天早上”的各种作息。
  private static let sleepLookback: TimeInterval = 36 * 3_600
  /// 两段睡眠之间空开这么久就算两次睡眠，用来把午睡和昨晚分开。
  private static let sleepSessionGap: TimeInterval = 3 * 3_600
  /// 太短的一段当作打盹，不拿来当昨晚的睡眠。
  private static let minimumSleepSession: TimeInterval = 30 * 60

  private static var readTypes: Set<HKObjectType> {
    var types: Set<HKObjectType> = [HKObjectType.activitySummaryType()]
    let quantities: [HKQuantityTypeIdentifier] = [
      .stepCount, .distanceWalkingRunning, .flightsClimbed, .restingHeartRate,
      .activeEnergyBurned, .appleExerciseTime, .appleStandTime,
    ]
    for identifier in quantities {
      if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
    }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
    return types
  }

  /// 已经授权过时这一步不会再弹窗，可以每次生成前都调用。
  static func requestAuthorization() async throws {
    guard HKHealthStore.isHealthDataAvailable() else { throw HealthSummaryError.unavailable }
    do {
      try await store.requestAuthorization(toShare: [], read: readTypes)
    } catch {
      throw HealthSummaryError.from(error)
    }
  }

  static func fetchToday(now: Date = Date()) async throws -> HealthSummarySnapshot {
    guard HKHealthStore.isHealthDataAvailable() else { throw HealthSummaryError.unavailable }

    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: now)
    let rings = await activityRings(on: now, calendar: calendar)

    async let steps = sum(.stepCount, unit: .count(), from: dayStart, to: now)
    async let distance = sum(.distanceWalkingRunning, unit: .meter(), from: dayStart, to: now)
    async let flights = sum(.flightsClimbed, unit: .count(), from: dayStart, to: now)
    async let restingHeartRate = latestQuantity(
      .restingHeartRate,
      unit: HKUnit.count().unitDivided(by: .minute()),
      since: now.addingTimeInterval(-7 * 24 * 3_600),
      until: now
    )
    async let sleep = lastNightSleep(now: now)

    let snapshot = await HealthSummarySnapshot(
      generatedAt: now,
      move: rings.move,
      exercise: rings.exercise,
      stand: rings.stand,
      usesMoveTime: rings.usesMoveTime,
      steps: steps,
      distanceMeters: distance,
      flights: flights,
      restingHeartRate: restingHeartRate,
      sleep: sleep
    )
    guard snapshot.hasAnyData else { throw HealthSummaryError.noData }
    return snapshot
  }

  // MARK: - 活动圆环

  private struct ActivityRings {
    var move: ActivityRingMetric?
    var exercise: ActivityRingMetric?
    var stand: ActivityRingMetric?
    var usesMoveTime = false
  }

  private static func activityRings(on date: Date, calendar: Calendar) async -> ActivityRings {
    var components = calendar.dateComponents([.era, .year, .month, .day], from: date)
    components.calendar = calendar
    let predicate = HKQuery.predicate(
      forActivitySummariesBetweenStart: components,
      end: components
    )

    let summary: HKActivitySummary? = await withCheckedContinuation { continuation in
      let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, _ in
        continuation.resume(returning: summaries?.last)
      }
      store.execute(query)
    }
    guard let summary else { return ActivityRings() }

    var rings = ActivityRings()
    if summary.activityMoveMode == .appleMoveTime {
      rings.usesMoveTime = true
      rings.move = ActivityRingMetric(
        value: summary.appleMoveTime.doubleValue(for: .minute()),
        goal: summary.appleMoveTimeGoal.doubleValue(for: .minute())
      )
    } else {
      rings.move = ActivityRingMetric(
        value: summary.activeEnergyBurned.doubleValue(for: .kilocalorie()),
        goal: summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
      )
    }
    rings.exercise = ActivityRingMetric(
      value: summary.appleExerciseTime.doubleValue(for: .minute()),
      goal: summary.appleExerciseTimeGoal.doubleValue(for: .minute())
    )
    rings.stand = ActivityRingMetric(
      value: summary.appleStandHours.doubleValue(for: .count()),
      goal: summary.appleStandHoursGoal.doubleValue(for: .count())
    )
    return rings
  }

  // MARK: - 数值统计

  private static func sum(
    _ identifier: HKQuantityTypeIdentifier,
    unit: HKUnit,
    from start: Date,
    to end: Date
  ) async -> Double? {
    guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
    let predicate = HKQuery.predicateForSamples(
      withStart: start,
      end: end,
      options: [.strictStartDate]
    )
    return await withCheckedContinuation { continuation in
      let query = HKStatisticsQuery(
        quantityType: type,
        quantitySamplePredicate: predicate,
        options: .cumulativeSum
      ) { _, statistics, _ in
        continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
      }
      store.execute(query)
    }
  }

  private static func latestQuantity(
    _ identifier: HKQuantityTypeIdentifier,
    unit: HKUnit,
    since start: Date,
    until end: Date
  ) async -> Double? {
    guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
    return await withCheckedContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: type,
        predicate: predicate,
        limit: 1,
        sortDescriptors: [sort]
      ) { _, samples, _ in
        let sample = samples?.first as? HKQuantitySample
        continuation.resume(returning: sample?.quantity.doubleValue(for: unit))
      }
      store.execute(query)
    }
  }

  // MARK: - 睡眠

  private static func lastNightSleep(now: Date) async -> SleepSummary? {
    guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
    let predicate = HKQuery.predicateForSamples(
      withStart: now.addingTimeInterval(-sleepLookback),
      end: now,
      options: []
    )
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
    let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: type,
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [sort]
      ) { _, samples, _ in
        continuation.resume(returning: samples as? [HKCategorySample] ?? [])
      }
      store.execute(query)
    }
    return summarize(samples)
  }

  /// 一条睡眠记录归到哪个桶里。`inBed` 只是躺着，不参与统计，否则会和实际睡眠重复计时。
  private enum SleepBucket: CaseIterable {
    case deep
    case core
    case rem
    case unspecified
    case awake

    init?(value: Int) {
      switch HKCategoryValueSleepAnalysis(rawValue: value) {
      case .asleepDeep: self = .deep
      case .asleepCore: self = .core
      case .asleepREM: self = .rem
      case .asleepUnspecified: self = .unspecified
      case .awake: self = .awake
      default: return nil
      }
    }

    var isAsleep: Bool { self != .awake }
  }

  private struct SleepEntry {
    let bucket: SleepBucket
    let sample: HKCategorySample

    var duration: TimeInterval { sample.endDate.timeIntervalSince(sample.startDate) }
  }

  private struct SleepSession {
    var entries: [SleepEntry] = []
    var totals = SleepStageTotals()
    var awakenings = 0
  }

  private static func summarize(_ samples: [HKCategorySample]) -> SleepSummary? {
    let usable = samples.compactMap { sample -> SleepEntry? in
      guard let bucket = SleepBucket(value: sample.value) else { return nil }
      guard sample.endDate > sample.startDate else { return nil }
      return SleepEntry(bucket: bucket, sample: sample)
    }
    guard !usable.isEmpty else { return nil }

    // 手表、手机和第三方 App 会各写一份，叠在一起算就会睡出二十几个小时。
    // 只保留睡眠时长最多的那个来源。
    var asleepBySource: [String: TimeInterval] = [:]
    for entry in usable where entry.bucket.isAsleep {
      asleepBySource[entry.sample.sourceRevision.source.bundleIdentifier, default: 0] += entry.duration
    }
    guard let dominant = asleepBySource.max(by: { $0.value < $1.value })?.key else { return nil }
    let sorted = usable
      .filter { $0.sample.sourceRevision.source.bundleIdentifier == dominant }
      .sorted { $0.sample.startDate < $1.sample.startDate }

    // 中间空开三小时以上就当成两次睡眠，午睡不会被算进昨晚。
    var sessions: [[SleepEntry]] = []
    var current: [SleepEntry] = []
    var currentEnd = Date.distantPast
    for entry in sorted {
      if !current.isEmpty, entry.sample.startDate.timeIntervalSince(currentEnd) > sleepSessionGap {
        sessions.append(current)
        current = []
      }
      current.append(entry)
      currentEnd = max(currentEnd, entry.sample.endDate)
    }
    if !current.isEmpty { sessions.append(current) }

    let candidates = sessions
      .map { summarize(session: $0) }
      .filter { $0.totals.asleep >= minimumSleepSession }
    guard let best = candidates.max(by: { $0.totals.asleep < $1.totals.asleep }) else { return nil }

    let starts = best.entries.map { $0.sample.startDate }
    let ends = best.entries.map { $0.sample.endDate }
    guard let start = starts.min(), let end = ends.max() else { return nil }
    return SleepSummary(
      start: start,
      end: end,
      totals: best.totals,
      awakenings: best.awakenings,
      score: SleepScoring.score(totals: best.totals, awakenings: best.awakenings)
    )
  }

  /// 同一来源内偶尔也会有重叠的记录，按阶段合并区间之后再累加。
  private static func summarize(session entries: [SleepEntry]) -> SleepSession {
    var intervals: [SleepBucket: [(start: Date, end: Date)]] = [:]
    for entry in entries {
      intervals[entry.bucket, default: []].append((entry.sample.startDate, entry.sample.endDate))
    }
    var durations: [SleepBucket: TimeInterval] = [:]
    var awakenings = 0
    for bucket in SleepBucket.allCases {
      let merged = merge(intervals[bucket] ?? [])
      durations[bucket] = merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
      if bucket == .awake { awakenings = merged.count }
    }
    return SleepSession(
      entries: entries,
      totals: SleepStageTotals(
        deep: durations[.deep] ?? 0,
        core: durations[.core] ?? 0,
        rem: durations[.rem] ?? 0,
        unspecified: durations[.unspecified] ?? 0,
        awake: durations[.awake] ?? 0
      ),
      awakenings: awakenings
    )
  }

  private static func merge(_ intervals: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
    let sorted = intervals.sorted { $0.start < $1.start }
    var merged: [(start: Date, end: Date)] = []
    for interval in sorted {
      if let last = merged.last, interval.start <= last.end {
        merged[merged.count - 1].end = max(last.end, interval.end)
      } else {
        merged.append(interval)
      }
    }
    return merged
  }
}
