import Accelerate
import Foundation

/// Smallest length vDSP's real DFT accepts that is >= n: f * 2^k with f in {1, 3, 5, 15}.
func fftSize(atLeast n: Int) -> Int {
    var best = Int.max
    for f in [1, 3, 5, 15] {
        var size = f * 16
        while size < n { size *= 2 }
        best = min(best, size)
    }
    return best
}

final class FFTPlan {
    let n: Int
    let forward: vDSP_DFT_Setup
    let inverse: vDSP_DFT_Setup

    private static var plans = [Int: FFTPlan]()
    private static let lock = NSLock()

    static func get(_ n: Int) -> FFTPlan {
        lock.lock(); defer { lock.unlock() }
        if let p = plans[n] { return p }
        let p = FFTPlan(n: n)
        plans[n] = p
        return p
    }

    private init(n: Int) {
        self.n = n
        forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(n), .INVERSE)!
    }
}

/// Half spectrum in vDSP's packed layout: re[0] is DC, im[0] is Nyquist.
struct Spectrum {
    var re: [Float]
    var im: [Float]
}

func spectrum(of x: UnsafeBufferPointer<Float>, plan: FFTPlan) -> Spectrum {
    let half = plan.n / 2
    var re = [Float](repeating: 0, count: half)
    var im = [Float](repeating: 0, count: half)
    let count = min(x.count, plan.n)
    // Deinterleave x into even/odd samples, which is the real DFT's input format.
    re.withUnsafeMutableBufferPointer { r in
        im.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            x.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: count / 2) { c in
                vDSP_ctoz(c, 2, &split, 1, vDSP_Length(count / 2))
            }
            if count % 2 == 1 { r[count / 2] = x[count - 1] }
            vDSP_DFT_Execute(plan.forward, r.baseAddress!, i.baseAddress!, r.baseAddress!, i.baseAddress!)
        }
    }
    return Spectrum(re: re, im: im)
}

/// One candidate alignment: the clip starts `lag` samples after the reference starts.
public struct Match {
    public var lag: Double
    /// Peak height in noise standard deviations.
    public var z: Float
    /// Best competing peak, more than half a second away, in the same units.
    public var z2: Float
    /// Where that competing peak is.
    public var lag2: Double
    public var inverted: Bool

    public var ratio: Float { z2 > 0 ? z / z2 : .infinity }
}

/// Tunable parts of the matcher.
public struct MatchSettings {
    public var lowHz: Double = 100
    public var highHz: Double = 1900
    /// PHAT weighting exponent: 1 is full whitening, 0 is plain correlation.
    public var phatBeta: Float = 0.75

    public init() {}
}

/// Correlates clips against one fixed reference signal with generalized
/// cross-correlation (PHAT weighting), which keys on when sounds happen
/// rather than how each microphone colours them.
public final class Correlator {
    let plan: FFTPlan
    let reference: Spectrum
    public let referenceCount: Int
    let rate: Double
    let settings: MatchSettings

    public init(reference: [Float], maxClip: Int, rate: Double, settings: MatchSettings = MatchSettings()) {
        let plan = FFTPlan.get(fftSize(atLeast: reference.count + maxClip + 16))
        self.plan = plan
        referenceCount = reference.count
        self.rate = rate
        self.settings = settings
        self.reference = reference.withUnsafeBufferPointer { spectrum(of: $0, plan: plan) }
    }

    /// Best alignment of `clip` with its start lag limited to `lags`
    /// (negative: the clip starts before the reference).
    public func match(_ clip: [Float], lags: ClosedRange<Int>) -> Match? {
        let n = plan.n
        let half = n / 2
        guard clip.count < n else { return nil }
        var c = clip.withUnsafeBufferPointer { spectrum(of: $0, plan: plan) }

        // Cross spectrum R * conj(C), weighted by 1 / |R C|^beta inside the band.
        let lowBin = max(1, Int(settings.lowHz * Double(n) / rate))
        let highBin = min(half - 1, Int(settings.highHz * Double(n) / rate))
        var mag = [Float](repeating: 0, count: half)
        reference.re.withUnsafeBufferPointer { rr in
            reference.im.withUnsafeBufferPointer { ri in
                c.re.withUnsafeMutableBufferPointer { cr in
                    c.im.withUnsafeMutableBufferPointer { ci in
                        for k in 0..<half {
                            let a = rr[k], b = ri[k], x = cr[k], y = ci[k]
                            let re = a * x + b * y
                            let im = b * x - a * y
                            cr[k] = re
                            ci[k] = im
                            mag[k] = re * re + im * im
                        }
                        var exponent = settings.phatBeta / 2
                        var count = Int32(half)
                        mag.withUnsafeMutableBufferPointer { m in
                            vvpowsf(m.baseAddress!, &exponent, m.baseAddress!, &count)
                        }
                        var mean: Float = 0
                        vDSP_meanv(mag, 1, &mean, vDSP_Length(half))
                        let eps = mean * 1e-3 + 1e-30
                        for k in 0..<half {
                            let w: Float = (k >= lowBin && k <= highBin) ? 1 / (mag[k] + eps) : 0
                            cr[k] *= w
                            ci[k] *= w
                        }
                        cr[0] = 0
                        ci[0] = 0
                        vDSP_DFT_Execute(plan.inverse, cr.baseAddress!, ci.baseAddress!, cr.baseAddress!, ci.baseAddress!)
                    }
                }
            }
        }
        var corr = [Float](repeating: 0, count: n)
        corr.withUnsafeMutableBufferPointer { out in
            out.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { o in
                var split = DSPSplitComplex(realp: &c.re, imagp: &c.im)
                vDSP_ztoc(&split, 1, o, 2, vDSP_Length(half))
            }
        }
        mag = []
        c = Spectrum(re: [], im: [])

        let lo = max(lags.lowerBound, -(n - referenceCount) + 1)
        let hi = min(lags.upperBound, referenceCount - 1)
        guard lo < hi else { return nil }
        @inline(__always) func at(_ lag: Int) -> Float { corr[lag >= 0 ? lag : lag + n] }

        var best = lo
        var bestValue: Float = -1
        var sumSquares: Double = 0
        var samples = 0
        for lag in lo...hi {
            let v = abs(at(lag))
            if v > bestValue { bestValue = v; best = lag }
            if lag % 3 == 0 { sumSquares += Double(v * v); samples += 1 }
        }
        let sigma = Float((sumSquares / Double(max(samples, 1))).squareRoot())
        guard sigma > 0 else { return nil }

        let exclusion = Int(0.5 * rate)
        var second: Float = 0
        var secondLag = best
        for lag in lo...hi where abs(lag - best) > exclusion {
            let v = abs(at(lag))
            if v > second { second = v; secondLag = lag }
        }

        // Parabolic interpolation for a sub-sample peak position.
        var lag = Double(best)
        if best > lo && best < hi {
            let y0 = abs(at(best - 1)), y1 = abs(at(best)), y2 = abs(at(best + 1))
            let d = y0 - 2 * y1 + y2
            if d != 0 { lag += Double(0.5 * (y0 - y2) / d) }
        }
        return Match(lag: lag, z: bestValue / sigma, z2: second / sigma, lag2: Double(secondLag), inverted: at(best) < 0)
    }
}
