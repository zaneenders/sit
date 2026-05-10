// SPDX-License-Identifier: Apache-2.0
// Deflate inflate errors follow Mark Adler’s `puff` return conventions where noted.

public enum InflateError: Error, Equatable, Sendable {
  /// Puff `2`: truncated deflate stream while reading bits.
  case insufficientInput
  /// Puff `1`: output cap hit (zip-bomb guard).
  case outputSpaceExhausted
  /// Puff `-1`: reserved block type `11`.
  case invalidBlockType
  /// Puff `-2`: stored block length / NLEN mismatch.
  case storedLengthMismatch
  /// Puff `-3` … `-9`: dynamic block header problems.
  case invalidDynamicBlock(String)
  /// Puff `-10`: bad Huffman symbol in compressed data.
  case invalidCode
  /// Puff `-11`: distance references bytes before start of output.
  case distanceTooFarBack
  /// RFC 1950: Adler-32 of uncompressed bytes does not match trailer.
  case adler32Mismatch
  /// Not enough bytes for CMF + FLG + Adler32 trailer.
  case truncatedZlib
}
