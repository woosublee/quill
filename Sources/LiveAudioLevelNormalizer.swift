import Foundation

struct LiveAudioLevelNormalizer {
    private static let minimumRMS: Float = 0.00001
    private static let minSpanDB: Float = 18
    private static let peakHeadroomDB: Float = 8
    private static let speechGateMarginDB: Float = 3
    private static let minimumVisibleActiveLevel: Float = 0.12
    private static let noiseGateNormalizedThreshold: Float = 0.06
    private static let floorRiseWindowDB: Float = 4
    private static let floorFallBlend: Float = 0.12
    private static let floorRiseBlend: Float = 0.02
    private static let peakAttackBlend: Float = 0.55
    private static let peakReleaseBlend: Float = 0.04
    private static let displayAttackBlend: Float = 0.45
    private static let displayReleaseBlend: Float = 0.12

    private var noiseFloorDB: Float = -55
    private var peakCeilingDB: Float = -37
    private var displayLevel: Float = 0

    mutating func reset() {
        noiseFloorDB = -55
        peakCeilingDB = -37
        displayLevel = 0
    }

    mutating func normalizedLevel(forRMS rms: Float) -> Float {
        let levelDB = 20 * log10f(max(rms, Self.minimumRMS))

        updateNoiseFloor(with: levelDB)
        updatePeakCeiling(with: levelDB)

        let displayCeilingDB = peakCeilingDB + Self.peakHeadroomDB
        let dynamicSpan = max(displayCeilingDB - noiseFloorDB, Self.minSpanDB + Self.peakHeadroomDB)
        var normalized = clamp((levelDB - noiseFloorDB) / dynamicSpan)
        let isActiveSpeech = levelDB >= noiseFloorDB + Self.speechGateMarginDB

        if normalized < Self.noiseGateNormalizedThreshold && levelDB <= noiseFloorDB + Self.speechGateMarginDB {
            normalized = 0
        } else if isActiveSpeech {
            normalized = max(normalized, Self.minimumVisibleActiveLevel)
        }

        let blend = normalized > displayLevel ? Self.displayAttackBlend : Self.displayReleaseBlend
        displayLevel = mix(displayLevel, normalized, blend)
        return displayLevel
    }

    private mutating func updateNoiseFloor(with levelDB: Float) {
        let ceilingLimitedLevel = min(levelDB, peakCeilingDB - Self.minSpanDB)

        if ceilingLimitedLevel <= noiseFloorDB {
            noiseFloorDB = mix(noiseFloorDB, ceilingLimitedLevel, Self.floorFallBlend)
        } else if ceilingLimitedLevel <= noiseFloorDB + Self.floorRiseWindowDB {
            noiseFloorDB = mix(noiseFloorDB, ceilingLimitedLevel, Self.floorRiseBlend)
        }
    }

    private mutating func updatePeakCeiling(with levelDB: Float) {
        let minimumCeiling = noiseFloorDB + Self.minSpanDB

        if levelDB >= peakCeilingDB {
            peakCeilingDB = mix(peakCeilingDB, levelDB, Self.peakAttackBlend)
        } else {
            peakCeilingDB = mix(peakCeilingDB, max(levelDB, minimumCeiling), Self.peakReleaseBlend)
        }

        peakCeilingDB = max(peakCeilingDB, minimumCeiling)
    }

    private func mix(_ current: Float, _ target: Float, _ blend: Float) -> Float {
        current + (target - current) * blend
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

struct SystemAudioDisplayLevelNormalizer {
    private static let minimumRMS: Float = 0.00001
    private static let silenceThresholdDB: Float = -72
    private static let floorDB: Float = -64
    private static let ceilingDB: Float = -18
    private static let curve: Float = 0.65
    private static let displayAttackBlend: Float = 0.65
    private static let displayReleaseBlend: Float = 0.24

    private var displayLevel: Float = 0

    mutating func reset() {
        displayLevel = 0
    }

    mutating func normalizedLevel(forRMS rms: Float) -> Float {
        let levelDB = 20 * log10f(max(rms, Self.minimumRMS))
        let target: Float
        if levelDB <= Self.silenceThresholdDB {
            target = 0
        } else {
            let normalized = clamp((levelDB - Self.floorDB) / (Self.ceilingDB - Self.floorDB))
            target = powf(normalized, Self.curve)
        }

        let blend = target > displayLevel ? Self.displayAttackBlend : Self.displayReleaseBlend
        displayLevel = mix(displayLevel, target, blend)
        return displayLevel < 0.01 ? 0 : displayLevel
    }

    private func mix(_ current: Float, _ target: Float, _ blend: Float) -> Float {
        current + (target - current) * blend
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
