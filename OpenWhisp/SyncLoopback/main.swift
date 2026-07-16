import Foundation
import OpenWhispSyncLAN

// Thin executable entry. All the logic (file store, host, LANBridgeServer boot)
// lives in the OpenWhispSyncLAN module's Runtime.swift so the E2E test can
// @testable-import it and drive a real server without an executable dependency.
runSyncLoopback()
