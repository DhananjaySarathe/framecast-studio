// Sends a test command to a Framecast launched with FRAMECAST_UI=...,test-control
// usage: swift scripts/fcctl.swift admit-all
import Foundation
let cmd = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.framecast.test"), object: cmd, userInfo: nil, deliverImmediately: true)
