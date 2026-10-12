import Foundation

/// 一个字节增量窗口只有全程属于同一配置时才能归属；首个/跨配置窗口仍可画波形。
public struct TrafficConfigurationWindow: Sendable {
    private var previous: UUID?
    public init() {}
    public mutating func configurationForSample(current: UUID?) -> UUID? {
        defer { previous = current }
        return current == previous ? current : nil
    }
}
