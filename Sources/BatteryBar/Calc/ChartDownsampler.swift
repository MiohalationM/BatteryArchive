import Foundation

/// 趋势图数据点：来自 v5 分钟聚合。
/// `breakBefore` 标记与上一点之间存在缺口（分钟缺失或覆盖率未达标），
/// 渲染时在此断开连线，绝不跨缺口插值。
/// 定义在 Calc 层：ChartDownsampler 抽稀与视图绘制共用，纯数据无视图依赖。
struct TrendPoint: Equatable, Sendable {
    let time: Date
    let value: Double
    /// tooltip 附加量（如该窗口的温度最大值）
    let maximum: Double?
    /// 该点所属窗口的覆盖率（tooltip 展示）
    let coverage: Double?
    let breakBefore: Bool

    init(time: Date, value: Double, maximum: Double? = nil, coverage: Double? = nil, breakBefore: Bool = false) {
        self.time = time
        self.value = value
        self.maximum = maximum
        self.coverage = coverage
        self.breakBefore = breakBefore
    }
}

/// 为 Swift Charts 压缩长时间序列。按时间桶保留总功耗的局部最小值与最大值，
/// 相比简单 stride 不会把短时峰值直接跳过，同时把 Chart marks 控制在固定上限。
enum ChartDownsampler {
    static func powerSnapshots(
        _ snapshots: [BatterySnapshot],
        maxPoints: Int = 240
    ) -> [BatterySnapshot] {
        guard maxPoints > 0 else { return [] }
        guard snapshots.count > maxPoints else { return snapshots }
        if maxPoints == 1 { return snapshots.first.map { [$0] } ?? [] }
        if maxPoints == 2 {
            guard let first = snapshots.first, let last = snapshots.last else { return snapshots }
            return [first, last]
        }
        if maxPoints == 3 {
            guard let first = snapshots.first, let last = snapshots.last else { return snapshots }
            let interior = 1..<(snapshots.count - 1)
            let peak = interior.max { snapshots[$0].wattage < snapshots[$1].wattage }
            return peak.map { [first, snapshots[$0], last] } ?? [first, last]
        }

        let interiorCount = snapshots.count - 2
        let bucketCount = max(1, (maxPoints - 2) / 2)
        var selectedIndices: [Int] = [0]
        selectedIndices.reserveCapacity(maxPoints)

        for bucket in 0..<bucketCount {
            let lower = 1 + bucket * interiorCount / bucketCount
            let upper = 1 + (bucket + 1) * interiorCount / bucketCount
            guard lower < upper else { continue }

            let indices = lower..<upper
            let minimum = indices.min { snapshots[$0].wattage < snapshots[$1].wattage }
            let maximum = indices.max { snapshots[$0].wattage < snapshots[$1].wattage }
            for index in [minimum, maximum].compactMap({ $0 }).sorted() {
                if selectedIndices.last != index {
                    selectedIndices.append(index)
                }
            }
        }

        if let lastIndex = snapshots.indices.last, selectedIndices.last != lastIndex {
            selectedIndices.append(lastIndex)
        }
        return selectedIndices.map { snapshots[$0] }
    }

    /// TrendPoint 的分段保峰抽稀：按 `breakBefore` 拆分为连续段并按段分配预算，
    /// 段内保留首尾与每桶最小/最大值（保峰不丢尖刺），同时严格遵守 `maxPoints` 上限，
    /// 并将被抽稀跳过区间内的 `breakBefore` 传播到下一个保留点，绝不跨缺口连线。
    static func downsampleTrendPoints(_ points: [TrendPoint], maxPoints: Int = 240) -> [TrendPoint] {
        guard maxPoints > 0 else { return [] }
        guard points.count > maxPoints else { return points }
        if maxPoints == 1 { return points.first.map { [$0] } ?? [] }

        var segments: [Range<Int>] = []
        var segmentStart = 0
        for index in 1..<points.count where points[index].breakBefore {
            segments.append(segmentStart..<index)
            segmentStart = index
        }
        segments.append(segmentStart..<points.count)

        let selectedIndices: [Int]
        if segments.count <= maxPoints {
            let budgets = allocateSegmentBudgets(segments: segments, totalBudget: maxPoints)
            var indices: [Int] = []
            indices.reserveCapacity(maxPoints)
            for (segOffset, range) in segments.enumerated() {
                let budget = budgets[segOffset]
                let preferEnd = (segOffset == segments.count - 1 && segOffset > 0)
                let chosen = selectSegmentIndices(
                    in: points, range: range, budget: budget, preferEndWhenSingle: preferEnd
                )
                for idx in chosen where indices.last != idx {
                    indices.append(idx)
                }
            }
            selectedIndices = indices
        } else {
            selectedIndices = selectSegmentIndices(
                in: points, range: 0..<points.count, budget: maxPoints, preferEndWhenSingle: false
            )
        }

        var result: [TrendPoint] = []
        result.reserveCapacity(selectedIndices.count)
        var previousKeptIndex: Int?
        for index in selectedIndices {
            var point = points[index]
            let crossedBreak: Bool
            if let prev = previousKeptIndex, prev < index {
                crossedBreak = ((prev + 1)...index).contains(where: { points[$0].breakBefore })
            } else if previousKeptIndex == nil, index > 0 {
                crossedBreak = (0...index).contains(where: { points[$0].breakBefore })
            } else {
                crossedBreak = false
            }
            if crossedBreak && !point.breakBefore {
                point = TrendPoint(
                    time: point.time, value: point.value,
                    maximum: point.maximum, coverage: point.coverage,
                    breakBefore: true
                )
            }
            result.append(point)
            previousKeptIndex = index
        }
        return result
    }

    private static func allocateSegmentBudgets(segments: [Range<Int>], totalBudget: Int) -> [Int] {
        guard !segments.isEmpty else { return [] }
        if segments.count == 1 { return [min(segments[0].count, totalBudget)] }

        var budgets = Array(repeating: 1, count: segments.count)
        var remaining = totalBudget - segments.count

        // 优先保证多点连续段能保留首尾两端（首尾段优先，确保全局起止点不丢）
        let endpointOrder = ([0, segments.count - 1] + Array(1..<(segments.count - 1)))
        for idx in endpointOrder where remaining > 0 && segments[idx].count >= 2 && budgets[idx] < 2 {
            budgets[idx] += 1
            remaining -= 1
        }

        while remaining > 0 {
            let capacities = segments.indices.map { max(0, segments[$0].count - budgets[$0]) }
            let totalCapacity = capacities.reduce(0, +)
            guard totalCapacity > 0 else { break }

            var distributed = 0
            var remainders: [(index: Int, fraction: Double)] = []
            for idx in segments.indices where capacities[idx] > 0 {
                let exact = Double(remaining) * Double(capacities[idx]) / Double(totalCapacity)
                let whole = min(capacities[idx], Int(exact.rounded(.down)))
                if whole > 0 {
                    budgets[idx] += whole
                    distributed += whole
                }
                if budgets[idx] < segments[idx].count {
                    remainders.append((idx, exact - Double(whole)))
                }
            }
            remaining -= distributed
            if remaining > 0 {
                remainders.sort {
                    if $0.fraction != $1.fraction { return $0.fraction > $1.fraction }
                    return segments[$0.index].count > segments[$1.index].count
                }
                var addedAny = false
                for item in remainders where remaining > 0 && budgets[item.index] < segments[item.index].count {
                    budgets[item.index] += 1
                    remaining -= 1
                    addedAny = true
                }
                if !addedAny { break }
            }
        }
        return budgets
    }

    private static func selectSegmentIndices(
        in points: [TrendPoint],
        range: Range<Int>,
        budget: Int,
        preferEndWhenSingle: Bool
    ) -> [Int] {
        guard budget > 0, !range.isEmpty else { return [] }
        if range.count <= budget { return Array(range) }
        let first = range.lowerBound
        let last = range.upperBound - 1
        if budget == 1 { return [preferEndWhenSingle ? last : first] }
        if budget == 2 { return [first, last] }
        if budget == 3 {
            let interior = (first + 1)..<last
            let peak = interior.filter { points[$0].value.isFinite }
                .max { points[$0].value < points[$1].value } ?? interior.lowerBound
            return [first, peak, last]
        }

        let interiorStart = first + 1
        let interiorCount = range.count - 2
        let bucketCount = max(1, (budget - 2) / 2)
        var selected: [Int] = [first]
        selected.reserveCapacity(budget)

        for bucket in 0..<bucketCount {
            let lower = interiorStart + bucket * interiorCount / bucketCount
            let upper = interiorStart + (bucket + 1) * interiorCount / bucketCount
            guard lower < upper else { continue }

            let indices = lower..<upper
            let finiteIndices = indices.filter { points[$0].value.isFinite }
            let minimum = finiteIndices.min { points[$0].value < points[$1].value } ?? lower
            let maximum = finiteIndices.max { points[$0].value < points[$1].value } ?? lower
            for idx in [minimum, maximum].sorted() {
                if selected.last != idx {
                    selected.append(idx)
                }
            }
        }

        if selected.last != last {
            selected.append(last)
        }
        return selected
    }
}
