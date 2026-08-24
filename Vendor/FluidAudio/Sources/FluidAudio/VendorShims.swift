// zeldaFlow vendoring shim — NOT upstream FluidAudio code.
//
// The vendored subset keeps only the Diarizer/Shared/VAD subtrees (see
// Vendor/FluidAudio/VENDORED.md). VBxClustering uses `makeBlasIndex` from
// the pruned ASR decoder; the original threw ASRError, which lives deep in
// the ASR type web. This shim reproduces the two pruned declarations
// (BlasIndex.swift, upstream Apache-2.0) against a local error type so the
// clustering code compiles unchanged.

import Accelerate
import CoreML

typealias BlasIndex = Int32

// From pruned TdtDecoderState.swift (upstream Apache-2.0) — MLArrayCache
// in Shared/ calls these.
extension MLMultiArray {
    func resetData(to value: NSNumber) {
        for i in 0..<count {
            self[i] = value
        }
    }

    func copyData(from source: MLMultiArray) {
        for i in 0..<count {
            self[i] = source[i]
        }
    }
}

enum VendorShimError: Error {
    case valueOutOfRange(String)
}

@inline(__always)
func makeBlasIndex(_ value: Int, label: String) throws -> BlasIndex {
    guard let cast = BlasIndex(exactly: value) else {
        throw VendorShimError.valueOutOfRange("\(label) exceeds supported range")
    }
    return cast
}
