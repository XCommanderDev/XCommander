// Intentionally empty: this target exists only to carry the header above.
//
// Unlike `CIndexStore`'s, this file is not optional. SwiftPM's default build system from the
// Xcode 27 toolchain on is Swift Build, which links every C target and fails a header-only
// one with "Build input file cannot be found: CSourceKit.o". The old `native` build system
// tolerated it, and is deprecated.
