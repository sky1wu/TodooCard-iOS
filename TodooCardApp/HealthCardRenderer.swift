import UIKit
#if canImport(TodooCore)
  import TodooCore
#endif

enum HealthCardRenderError: LocalizedError {
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .encodingFailed: return "无法把健康摘要编码成图片。"
    }
  }
}

/// 六色电子纸只有黑、白、黄、红、蓝、绿六种墨水，没有灰阶。任何浅灰的分隔线和
/// 次要文字量化后都会直接变成白色消失，所以这张卡片只用纯色作画：文字一律纯黑，
/// 强调色一律取调色板里的原色，线宽不小于 2 点。画布按 1 倍比例输出，字号就是最终
/// 像素大小；实机上小于 15 的字很难辨认，因此正文不再使用更小的字号。
private enum Ink {
  static let black = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
  static let white = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
  static let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
  static let green = UIColor(red: 0, green: 1, blue: 0, alpha: 1)
  static let blue = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
  static let yellow = UIColor(red: 1, green: 1, blue: 0, alpha: 1)
}

enum HealthCardRenderer {
  private static let width = CGFloat(CardDisplay.width)
  private static let height = CGFloat(CardDisplay.height)
  private static let margin: CGFloat = 32
  private static let contentWidth = CGFloat(CardDisplay.width) - 64
  private static let contentRight = CGFloat(CardDisplay.width) - 32
  private static let hairline: CGFloat = 2

  static func renderPNG(_ snapshot: HealthSummarySnapshot) throws -> Data {
    guard let data = render(snapshot).pngData() else { throw HealthCardRenderError.encodingFailed }
    return data
  }

  /// 直接画在 528 × 792 的画布上，和卡片像素一一对应：再缩放一次会把文字糊掉。
  static func render(_ snapshot: HealthSummarySnapshot) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    format.preferredRange = .standard
    let size = CGSize(width: width, height: height)
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      let canvas = context.cgContext
      Ink.white.setFill()
      canvas.fill(CGRect(origin: .zero, size: size))
      drawHeader(snapshot)
      drawActivity(snapshot)
      drawSleep(snapshot)
      drawStats(snapshot)
    }
  }

  // MARK: - 页眉

  private static func drawHeader(_ snapshot: HealthSummarySnapshot) {
    let date = snapshot.generatedAt
    draw(text(dayFormatter.string(from: date), font(40, .bold)), at: CGPoint(x: margin, y: 20))
    let subtitle = "\(weekdayFormatter.string(from: date)) · 更新于 \(timeFormatter.string(from: date))"
    draw(text(subtitle, font(18, .semibold)), at: CGPoint(x: margin, y: 74))

    let label = text("健康摘要", font(18, .bold))
    let labelSize = label.size()
    draw(label, at: CGPoint(x: contentRight - labelSize.width, y: 34))
    let heart = symbol("heart.fill", pointSize: 20, weight: .bold, color: Ink.red)
    if let heart {
      heart.draw(at: CGPoint(x: contentRight - labelSize.width - 9 - heart.size.width, y: 36))
    }

    rule(y: 108)
  }

  // MARK: - 活动圆环

  private static func drawActivity(_ snapshot: HealthSummarySnapshot) {
    drawSectionTitle(symbol: "flame.fill", title: "活动", y: 126)

    let center = CGPoint(x: margin + 100, y: 262)
    let rings: [(metric: ActivityRingMetric?, color: UIColor)] = [
      (snapshot.move, Ink.red),
      (snapshot.exercise, Ink.green),
      (snapshot.stand, Ink.blue),
    ]
    for (index, ring) in rings.enumerated() {
      drawRing(
        center: center,
        outerRadius: 100 - CGFloat(index) * 29,
        thickness: 22,
        fraction: ring.metric?.fraction ?? 0,
        color: ring.color
      )
    }

    let legendX = margin + 236
    guard snapshot.move != nil || snapshot.exercise != nil || snapshot.stand != nil else {
      draw(text("未获取到活动圆环", font(18, .bold)), at: CGPoint(x: legendX, y: 224))
      draw(text("需要 Apple Watch", font(15, .semibold)), at: CGPoint(x: legendX, y: 254))
      draw(text("或「健身记录」数据", font(15, .semibold)), at: CGPoint(x: legendX, y: 276))
      return
    }

    let moveUnit = snapshot.usesMoveTime ? "分钟" : "千卡"
    let rows: [(title: String, color: UIColor, metric: ActivityRingMetric?, unit: String)] = [
      ("活动", Ink.red, snapshot.move, moveUnit),
      ("锻炼", Ink.green, snapshot.exercise, "分钟"),
      ("站立", Ink.blue, snapshot.stand, "小时"),
    ]
    for (index, row) in rows.enumerated() {
      drawRingLegend(row.title, color: row.color, metric: row.metric, unit: row.unit,
                     x: legendX, y: 168 + CGFloat(index) * 68)
    }
  }

  private static func drawRingLegend(
    _ title: String,
    color: UIColor,
    metric: ActivityRingMetric?,
    unit: String,
    x: CGFloat,
    y: CGFloat
  ) {
    chip(color: color, at: CGPoint(x: x, y: y + 3), side: 12)
    draw(text(title, font(18, .bold)), at: CGPoint(x: x + 20, y: y - 2))

    guard let metric, metric.goal > 0 else {
      draw(text("—", font(30, .bold, rounded: true)), at: CGPoint(x: x, y: y + 20))
      return
    }

    let percent = text("\(metric.percent)%", font(18, .bold, rounded: true))
    draw(percent, at: CGPoint(x: contentRight - percent.size().width, y: y - 2))

    let value = composed([
      (formatGroupedNumber(Int(metric.value.rounded())), font(30, .bold, rounded: true)),
      (" / \(formatGroupedNumber(Int(metric.goal.rounded()))) \(unit)", font(16, .semibold)),
    ])
    draw(value, at: CGPoint(x: x, y: y + 21))
  }

  /// 画一圈圆环：先描出整圈的黑色轮廓，再把已完成的那一段填成实色。
  /// 电子纸上没有半透明的底色可用，用“空心圈 + 实心扇形”来区分目标与进度最清楚。
  private static func drawRing(
    center: CGPoint,
    outerRadius: CGFloat,
    thickness: CGFloat,
    fraction: Double,
    color: UIColor
  ) {
    let innerRadius = outerRadius - thickness
    let start = -CGFloat.pi / 2

    if fraction > 0.001 {
      color.setFill()
      let path: UIBezierPath
      if fraction >= 0.999 {
        path = UIBezierPath(arcCenter: center, radius: outerRadius, startAngle: 0,
                            endAngle: .pi * 2, clockwise: true)
        path.append(UIBezierPath(arcCenter: center, radius: innerRadius, startAngle: 0,
                                 endAngle: .pi * 2, clockwise: true))
        path.usesEvenOddFillRule = true
      } else {
        let end = start + .pi * 2 * CGFloat(fraction)
        path = UIBezierPath()
        path.addArc(withCenter: center, radius: outerRadius, startAngle: start,
                    endAngle: end, clockwise: true)
        path.addArc(withCenter: center, radius: innerRadius, startAngle: end,
                    endAngle: start, clockwise: false)
        path.close()
      }
      path.fill()
    }

    Ink.black.setStroke()
    for radius in [outerRadius, innerRadius] {
      let outline = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0,
                                 endAngle: .pi * 2, clockwise: true)
      outline.lineWidth = hairline
      outline.stroke()
    }
  }

  // MARK: - 睡眠

  private static func drawSleep(_ snapshot: HealthSummarySnapshot) {
    rule(y: 380)
    drawSectionTitle(symbol: "bed.double.fill", title: "睡眠", y: 396)

    guard let sleep = snapshot.sleep else {
      draw(text("昨晚没有读到睡眠记录", font(19, .bold)), at: CGPoint(x: margin, y: 432))
      draw(text("戴表入睡或在「健康」中记录睡眠后，", font(16, .medium)),
           at: CGPoint(x: margin, y: 466))
      draw(text("这里会显示时长、阶段与评分。", font(16, .medium)),
           at: CGPoint(x: margin, y: 490))
      return
    }

    if let start = sleep.start, let end = sleep.end {
      let range = "\(timeFormatter.string(from: start)) → \(timeFormatter.string(from: end))"
      let rangeText = text(range, font(16, .semibold))
      draw(rangeText, at: CGPoint(x: contentRight - rangeText.size().width, y: 398))
    }

    let score = composed([
      ("\(sleep.score.value)", font(46, .bold, rounded: true)),
      (" 分", font(18, .semibold)),
    ])
    draw(score, at: CGPoint(x: margin, y: 424))
    chip(color: gradeColor(sleep.score.grade), at: CGPoint(x: margin + 1, y: 490), side: 10)
    draw(
      text("睡眠评分 · \(sleep.score.grade.title)", font(16, .semibold)),
      at: CGPoint(x: margin + 18, y: 483)
    )

    let duration = text(formatSleepDuration(sleep.totals.asleep), font(32, .bold, rounded: true))
    draw(duration, at: CGPoint(x: contentRight - duration.size().width, y: 434))
    // 醒来次数只有 HealthKit 分段才数得出来，快捷指令传进来的数据没有这一项。
    let awake: String
    if sleep.totals.awake <= 0 {
      awake = "整夜连续"
    } else if sleep.awakenings > 0 {
      awake = "清醒 \(formatCompactDuration(sleep.totals.awake)) · 醒来 \(sleep.awakenings) 次"
    } else {
      awake = "清醒 \(formatCompactDuration(sleep.totals.awake))"
    }
    let awakeText = text(awake, font(16, .semibold))
    draw(awakeText, at: CGPoint(x: contentRight - awakeText.size().width, y: 483))

    drawSleepStages(sleep)
  }

  private static func drawSleepStages(_ sleep: SleepSummary) {
    let totals = sleep.totals
    var segments: [(title: String, color: UIColor, seconds: TimeInterval)]
    if totals.hasStageDetail {
      segments = [
        ("深度", Ink.blue, totals.deep),
        ("核心", Ink.green, totals.core + totals.unspecified),
        ("REM", Ink.yellow, totals.rem),
        ("清醒", Ink.red, totals.awake),
      ]
    } else {
      segments = [
        ("睡眠", Ink.blue, totals.asleep),
        ("清醒", Ink.red, totals.awake),
      ]
    }
    segments = segments.filter { $0.seconds > 0 }

    let bar = CGRect(x: margin, y: 518, width: contentWidth, height: 22)
    let outline = UIBezierPath(roundedRect: bar, cornerRadius: 6)
    let total = segments.reduce(0.0) { $0 + $1.seconds }
    if total > 0 {
      UIGraphicsGetCurrentContext()?.saveGState()
      outline.addClip()
      var cursor = bar.minX
      for (index, segment) in segments.enumerated() {
        let isLast = index == segments.count - 1
        let end = isLast ? bar.maxX : (cursor + (bar.width * CGFloat(segment.seconds / total))).rounded()
        segment.color.setFill()
        UIRectFill(CGRect(x: cursor, y: bar.minY, width: max(0, end - cursor), height: bar.height))
        if !isLast {
          Ink.black.setFill()
          UIRectFill(CGRect(x: end - 1, y: bar.minY, width: 2, height: bar.height))
        }
        cursor = end
      }
      UIGraphicsGetCurrentContext()?.restoreGState()
    }
    Ink.black.setStroke()
    outline.lineWidth = hairline
    outline.stroke()

    guard !segments.isEmpty else { return }
    // 图例平分整行，标题和时长叠在一起，窄屏上也不会互相挤掉。
    let columnWidth = contentWidth / CGFloat(segments.count)
    for (index, segment) in segments.enumerated() {
      let x = margin + columnWidth * CGFloat(index)
      chip(color: segment.color, at: CGPoint(x: x, y: 553), side: 10)
      draw(text(segment.title, font(15, .bold)), at: CGPoint(x: x + 16, y: 547))
      draw(
        text(formatCompactDuration(segment.seconds), font(15, .semibold)),
        at: CGPoint(x: x + 16, y: 568)
      )
    }
  }

  private static func gradeColor(_ grade: SleepGrade) -> UIColor {
    switch grade {
    case .excellent, .good: return Ink.green
    case .fair: return Ink.yellow
    case .poor: return Ink.red
    }
  }

  // MARK: - 今日数据

  private static func drawStats(_ snapshot: HealthSummarySnapshot) {
    rule(y: 600)
    drawSectionTitle(symbol: "chart.bar.fill", title: "今日数据", y: 616)

    var tiles: [(symbol: String, title: String, value: String, unit: String)] = []
    if let steps = snapshot.steps, steps > 0 {
      tiles.append(("figure.walk", "步数", formatGroupedNumber(Int(steps.rounded())), "步"))
    }
    if let distance = snapshot.distanceMeters, distance > 0 {
      let kilometers = distance / 1_000
      let value = kilometers >= 10
        ? String(format: "%.1f", kilometers)
        : String(format: "%.2f", kilometers)
      tiles.append(("location.fill", "距离", value, "公里"))
    }
    if let rate = snapshot.restingHeartRate, rate > 0 {
      tiles.append(("heart.fill", "静息心率", "\(Int(rate.rounded()))", "次/分"))
    }
    if let flights = snapshot.flights, flights > 0 {
      tiles.append(("figure.stairs", "爬楼", "\(Int(flights.rounded()))", "层"))
    }

    guard !tiles.isEmpty else {
      draw(text("今天还没有步数或心率记录。", font(20, .semibold)), at: CGPoint(x: margin, y: 684))
      return
    }

    let visible = Array(tiles.prefix(3))
    let gap: CGFloat = 10
    let tileWidth = (contentWidth - gap * CGFloat(visible.count - 1)) / CGFloat(visible.count)
    for (index, tile) in visible.enumerated() {
      let frame = CGRect(
        x: margin + (tileWidth + gap) * CGFloat(index),
        y: 648,
        width: tileWidth,
        height: 126
      )
      let box = UIBezierPath(roundedRect: frame, cornerRadius: 16)
      Ink.black.setStroke()
      box.lineWidth = hairline
      box.stroke()

      var titleX = frame.minX + 14
      if let icon = symbol(tile.symbol, pointSize: 17, weight: .bold, color: Ink.black) {
        icon.draw(at: CGPoint(x: titleX, y: frame.minY + 20))
        titleX += icon.size.width + 5
      }
      draw(text(tile.title, font(17, .bold)), at: CGPoint(x: titleX, y: frame.minY + 17))
      // 三列时横向空间较紧；少于三列则把释放出来的宽度也交给主数值。
      let valueSize: CGFloat
      if visible.count == 3 {
        valueSize = tile.value.count >= 7 ? 24 : 28
      } else {
        valueSize = tile.value.count >= 7 ? 30 : 32
      }
      let value = composed([
        (tile.value, font(valueSize, .bold, rounded: true)),
        (" \(tile.unit)", font(17, .semibold)),
      ])
      draw(value, at: CGPoint(x: frame.minX + 14, y: frame.minY + 62))
    }
  }

  // MARK: - 绘制基元

  private static func drawSectionTitle(symbol name: String, title: String, y: CGFloat) {
    var x = margin
    if let icon = symbol(name, pointSize: 18, weight: .bold, color: Ink.black) {
      icon.draw(at: CGPoint(x: x, y: y + 2))
      x += icon.size.width + 7
    }
    draw(text(title, font(19, .bold)), at: CGPoint(x: x, y: y - 2))
  }

  private static func rule(y: CGFloat) {
    Ink.black.setFill()
    UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: hairline))
  }

  private static func chip(color: UIColor, at origin: CGPoint, side: CGFloat) {
    let rect = CGRect(x: origin.x, y: origin.y, width: side, height: side)
    let path = UIBezierPath(roundedRect: rect, cornerRadius: side / 3)
    color.setFill()
    path.fill()
    Ink.black.setStroke()
    path.lineWidth = hairline
    path.stroke()
  }

  private static func symbol(
    _ name: String,
    pointSize: CGFloat,
    weight: UIImage.SymbolWeight,
    color: UIColor
  ) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    return UIImage(systemName: name, withConfiguration: configuration)?
      .withTintColor(color, renderingMode: .alwaysOriginal)
  }

  private static func font(
    _ size: CGFloat,
    _ weight: UIFont.Weight,
    rounded: Bool = false
  ) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return UIFont(descriptor: descriptor, size: size)
  }

  private static func text(_ string: String, _ font: UIFont) -> NSAttributedString {
    NSAttributedString(
      string: string,
      attributes: [.font: font, .foregroundColor: Ink.black]
    )
  }

  private static func composed(_ parts: [(String, UIFont)]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for part in parts { result.append(text(part.0, part.1)) }
    return result
  }

  /// point 是这一行文字外框的左上角。一行里混排大小字号时它们仍按同一条基线排布，
  /// 所以数字和后面的小号单位不会各自漂移。
  private static func draw(_ string: NSAttributedString, at point: CGPoint) {
    string.draw(at: point)
  }

  private static let dayFormatter = makeFormatter("M月d日")
  private static let weekdayFormatter = makeFormatter("EEEE")
  private static let timeFormatter = makeFormatter("HH:mm")

  private static func makeFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = format
    return formatter
  }
}
