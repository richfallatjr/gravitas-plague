public enum TuringQwenNativeCommandBufferProfile:
    String,
    Codable,
    Sendable,
    Equatable,
    CaseIterable
{
    case deviceDefault
    case operations32Megabytes40
    case operations40Megabytes32
    case operations32Megabytes32
    case operations24Megabytes24
    case operations16Megabytes16

    public var configuredOperations: Int? {
        switch self {
        case .deviceDefault:
            nil
        case .operations32Megabytes40, .operations32Megabytes32:
            32
        case .operations40Megabytes32:
            40
        case .operations24Megabytes24:
            24
        case .operations16Megabytes16:
            16
        }
    }

    public var configuredMegabytes: Int? {
        switch self {
        case .deviceDefault:
            nil
        case .operations32Megabytes40:
            40
        case .operations40Megabytes32, .operations32Megabytes32:
            32
        case .operations24Megabytes24:
            24
        case .operations16Megabytes16:
            16
        }
    }
}
