import Foundation
import Testing
@testable import ShottsCore

@Suite struct SoundCalibrationTests {
    /// A sine of amplitude `a`, faded in and out, as the tone is played.
    func tone(_ a: Double, count: Int = 48_000) -> [Float] {
        (0..<count).map { i in
            let fade = min(1, Double(min(i, count - i)) / 4800)
            return Float(a * fade * sin(2 * .pi * 200 * Double(i) / 48_000))
        }
    }

    @Test func levelIsTheSteadyPart() {
        let a = SoundCalibration.toneAmplitude
        // A sine's root mean square is its amplitude over √2; the fades do not pull it down.
        #expect(abs((SoundCalibration.level(of: tone(a)) ?? 0) - a / 2.squareRoot()) < a * 0.01)
        #expect(SoundCalibration.level(of: []) == nil)
    }

    /// Other sound, a thousand times louder at other pitches, hardly moves the tone's level.
    @Test func otherSoundIsLeftOut() {
        let a = SoundCalibration.toneAmplitude
        let noisy = zip(tone(a), (0..<48_000).map { i in Float(a * 1000 * sin(2 * .pi * 1_000 * Double(i) / 48_000)) }).map { $0 + $1 }
        let level = SoundCalibration.level(of: noisy) ?? 0
        #expect(abs(20 * log10(level / (a / 2.squareRoot()))) < 0.5)
    }

    /// Another sound starting abruptly while the tone plays splashes across its pitch: the
    /// windows disagree, and the measurement is not believed.
    @Test func aSoundStartingSpoilsIt() {
        let a = SoundCalibration.toneAmplitude
        var spoiled = tone(a)
        for i in 20_000..<30_000 { spoiled[i] += Float(a * 3000 * sin(2 * .pi * 660 * Double(i) / 48_000 + 0.7)) }
        #expect(SoundCalibration.level(of: spoiled) == nil)
    }

    /// 11 dB lost comes back as 11 dB; none lost, or too much, changes nothing.
    @Test func gainUndoesTheLoss() throws {
        let played = try #require(SoundCalibration.level(of: tone(SoundCalibration.toneAmplitude)))
        let heard = try #require(SoundCalibration.level(of: tone(SoundCalibration.toneAmplitude * pow(10, -11.0 / 20))))
        let gain = try #require(SoundCalibration.gain(played: played, heard: heard))
        #expect(abs(20 * log10(gain) - 11) < 0.05)
        #expect(SoundCalibration.gain(played: played, heard: played) == 1)
        #expect(SoundCalibration.gain(played: played, heard: played * 1.2) == 1)
        #expect(SoundCalibration.gain(played: played, heard: played / 100) == nil)
        #expect(SoundCalibration.gain(played: played, heard: 0) == nil)
    }
}
