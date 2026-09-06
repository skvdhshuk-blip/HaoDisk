import Foundation

func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func ratio(_ value: Int64, total: Int64) -> Double { total > 0 ? min(1, max(0, Double(value) / Double(total))) : 0 }
func percentage(_ value: Int64, total: Int64) -> String {
    let share = ratio(value, total: total)
    return share > 0 && share < 0.001 ? "<0.1%" : share.formatted(.percent.precision(.fractionLength(1)))
}
func nodeSizeLabel(_ node: DiskNode, metric: SizeMetric) -> String {
    if node.state == .pending { return "未扫描" }
    if node.state != .complete || node.issueCount > 0 { return node.bytes(metric) > 0 ? "已读 \(formattedBytes(node.bytes(metric)))" : "未读取" }
    return formattedBytes(node.bytes(metric))
}
