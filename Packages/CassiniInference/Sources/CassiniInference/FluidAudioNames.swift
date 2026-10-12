import FluidAudio

// FluidAudio's module has a type named `FluidAudio`, so its names cannot be qualified with the module; files that also
// import CassiniNotebook (which has its own `DownloadError`) use these.

/// FluidAudio's download error.
typealias FluidDownloadError = DownloadError
