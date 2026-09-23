import AppKit

/// The cursor lab's chimes, synthesized once into short WAV sounds: two rising notes when Dotto needs a decision,
/// two falling notes when it's stuck, one soft note when it finished.
@MainActor
enum AttentionChime {
    private static var cachedSoundsByKind: [UserAttentionKind: NSSound] = [:]

    static func play(for attentionKind: UserAttentionKind) {
        let chimeSound = cachedSoundsByKind[attentionKind] ?? makeSound(for: attentionKind)
        cachedSoundsByKind[attentionKind] = chimeSound
        chimeSound?.stop()
        chimeSound?.play()
    }

    private static func makeSound(for attentionKind: UserAttentionKind) -> NSSound? {
        let noteFrequenciesInHertz: [Double]
        let peakAmplitude: Double
        switch attentionKind {
        case .needsDecision, .needsBringForward:
            noteFrequenciesInHertz = [660, 880]
            peakAmplitude = 0.22
        case .stuck:
            noteFrequenciesInHertz = [392, 330]
            peakAmplitude = 0.22
        case .finished:
            noteFrequenciesInHertz = [784]
            peakAmplitude = 0.12
        }
        return NSSound(data: waveFileData(noteFrequenciesInHertz: noteFrequenciesInHertz, peakAmplitude: peakAmplitude))
    }

    /// Sine notes 0.13 s apart, each rising exponentially to its peak in 20 ms and decaying to silence by
    /// 350 ms, as the lab's WebAudio chime does. 16-bit mono PCM at 44.1 kHz in a RIFF/WAVE container.
    private static func waveFileData(noteFrequenciesInHertz: [Double], peakAmplitude: Double) -> Data {
        let sampleRate = 44_100.0
        let noteSpacingSeconds = 0.13
        let noteLengthSeconds = 0.4
        let attackSeconds = 0.02
        let decayEndSeconds = 0.35
        let silentAmplitude = 0.0001
        let totalSampleCount = Int((noteSpacingSeconds * Double(noteFrequenciesInHertz.count - 1) + noteLengthSeconds) * sampleRate)
        var mixedSamples = [Double](repeating: 0, count: totalSampleCount)

        for (noteIndex, noteFrequencyInHertz) in noteFrequenciesInHertz.enumerated() {
            let noteStartSampleIndex = Int(Double(noteIndex) * noteSpacingSeconds * sampleRate)
            for noteSampleIndex in 0..<Int(noteLengthSeconds * sampleRate) {
                let secondsIntoNote = Double(noteSampleIndex) / sampleRate
                let envelopeAmplitude: Double
                if secondsIntoNote < attackSeconds {
                    envelopeAmplitude = silentAmplitude * pow(peakAmplitude / silentAmplitude, secondsIntoNote / attackSeconds)
                } else if secondsIntoNote < decayEndSeconds {
                    let decayProgress = (secondsIntoNote - attackSeconds) / (decayEndSeconds - attackSeconds)
                    envelopeAmplitude = peakAmplitude * pow(silentAmplitude / peakAmplitude, decayProgress)
                } else {
                    envelopeAmplitude = 0
                }
                let mixedSampleIndex = noteStartSampleIndex + noteSampleIndex
                guard mixedSampleIndex < totalSampleCount else { break }
                mixedSamples[mixedSampleIndex] += envelopeAmplitude * sin(2 * .pi * noteFrequencyInHertz * secondsIntoNote)
            }
        }

        var waveFileData = Data()
        func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
            withUnsafeBytes(of: value.littleEndian) { waveFileData.append(contentsOf: $0) }
        }
        let bytesPerSample = 2
        let sampleDataByteCount = totalSampleCount * bytesPerSample
        waveFileData.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + sampleDataByteCount))
        waveFileData.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16))                                   // fmt chunk size
        appendLittleEndian(UInt16(1))                                    // PCM
        appendLittleEndian(UInt16(1))                                    // mono
        appendLittleEndian(UInt32(sampleRate))
        appendLittleEndian(UInt32(Int(sampleRate) * bytesPerSample))     // byte rate
        appendLittleEndian(UInt16(bytesPerSample))                       // block align
        appendLittleEndian(UInt16(16))                                   // bits per sample
        waveFileData.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(sampleDataByteCount))
        for mixedSample in mixedSamples {
            appendLittleEndian(Int16(max(-1, min(1, mixedSample)) * Double(Int16.max)))
        }
        return waveFileData
    }
}
