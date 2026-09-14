import Foundation

@main
struct SpectrumAnalyzerTests {
    static func main() {
        let rms: Float = 0.2
        let powers: [Float] = [1e-7, 1e-5, 1e-3]
        let baseline = powers.map { SpectrumAnalyzer.relativeBandLevel(power: $0, rms: rms) }
        precondition(baseline[0] < baseline[1] && baseline[1] < baseline[2])

        for volume: Float in [1, 0.5, 0.1, 0.01, 0.001] {
            for (index, power) in powers.enumerated() {
                let level = SpectrumAnalyzer.relativeBandLevel(
                    power: power * volume * volume, rms: rms * volume
                )
                precondition(abs(level - baseline[index]) < 1e-5)
            }
        }
        precondition(SpectrumAnalyzer.relativeBandLevel(power: 0, rms: 0) == 0)
        precondition(SpectrumAnalyzer.relativeBandLevel(power: 0, rms: rms) == 0)
        precondition(SpectrumAnalyzer.relativeBandLevel(power: .nan, rms: rms) == 0)
        precondition(SpectrumAnalyzer.relativeBandLevel(power: 1, rms: .infinity) == 0)
        print("Spectrum analyzer tests passed")
    }
}
