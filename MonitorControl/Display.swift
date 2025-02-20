import AVFoundation
import Cocoa
import DDC
import os.log

class Display {
  let identifier: CGDirectDisplayID
  let name: String
  let isBuiltin: Bool
  var isEnabled: Bool
  var brightnessSliderHandler: SliderHandler?
  var volumeSliderHandler: SliderHandler?
  var contrastSliderHandler: SliderHandler?
  var ddc: DDC?

  var hideOsd: Bool {
    get {
      return self.prefs.bool(forKey: "hideOsd-\(self.identifier)")
    }
    set {
      self.prefs.set(newValue, forKey: "hideOsd-\(self.identifier)")
      os_log("Set `hideOsd` to: %{public}@", type: .info, String(newValue))
    }
  }

  var needsLongerDelay: Bool {
    get {
      return self.prefs.object(forKey: "longerDelay-\(self.identifier)") as? Bool ?? false
    }
    set {
      self.prefs.set(newValue, forKey: "longerDelay-\(self.identifier)")
      os_log("Set `needsLongerDisplay` to: %{public}@", type: .info, String(newValue))
    }
  }

  private let prefs = UserDefaults.standard
  private var audioPlayer: AVAudioPlayer?

  private let osdChicletBoxes: Float = 16

  init(_ identifier: CGDirectDisplayID, name: String, isBuiltin: Bool, isEnabled: Bool = true) {
    self.identifier = identifier
    self.name = name
    self.isEnabled = isBuiltin ? false : isEnabled
    self.ddc = DDC(for: identifier)
    self.isBuiltin = isBuiltin
  }

  // On some displays, the display's OSD overlaps the macOS OSD,
  // calling the OSD command with 1 seems to hide it.
  func hideDisplayOsd() {
    guard self.hideOsd else {
      return
    }

    for _ in 0..<20 {
      _ = self.ddc?.write(command: .osd, value: UInt16(1), errorRecoveryWaitTime: 2000)
    }
  }

  func isMuted() -> Bool {
    return self.getValue(for: .audioMuteScreenBlank) == 1
  }

  func toggleMute(fromVolumeSlider: Bool = false) {
    var muteValue: Int
    var volumeOSDValue: Int

    if !self.isMuted() {
      muteValue = 1
      volumeOSDValue = 0
    } else {
      muteValue = 2
      volumeOSDValue = self.getValue(for: .audioSpeakerVolume)

      // The volume that will be set immediately after setting unmute while the old set volume was 0 is unpredictable
      // Hence, just set it to a single filled chiclet
      if volumeOSDValue == 0 {
        volumeOSDValue = self.stepSize(for: .audioSpeakerVolume, isSmallIncrement: false)
        self.saveValue(volumeOSDValue, for: .audioSpeakerVolume)
      }
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let volumeDDCValue = UInt16(volumeOSDValue)

      guard self.ddc?.write(command: .audioSpeakerVolume, value: volumeDDCValue) == true else {
        return
      }

      if self.supportsMuteCommand() {
        guard self.ddc?.write(command: .audioMuteScreenBlank, value: UInt16(muteValue)) == true else {
          return
        }
      }

      self.saveValue(muteValue, for: .audioMuteScreenBlank)

      if !fromVolumeSlider {
        self.hideDisplayOsd()
        self.showOsd(command: .audioSpeakerVolume, value: volumeOSDValue)

        if volumeOSDValue > 0 {
          self.playVolumeChangedSound()
        }

        if let slider = self.volumeSliderHandler?.slider {
          DispatchQueue.main.async {
            slider.intValue = Int32(volumeDDCValue)
          }
        }
      }
    }
  }

  func setVolume(to volumeOSDValue: Int) {
    var muteValue: Int?
    let volumeDDCValue = UInt16(volumeOSDValue)

    if self.isMuted(), volumeOSDValue > 0 {
      muteValue = 2
    } else if !self.isMuted(), volumeOSDValue == 0 {
      muteValue = 1
    }

    DispatchQueue.global(qos: .userInitiated).async {
      guard self.ddc?.write(command: .audioSpeakerVolume, value: volumeDDCValue) == true else {
        return
      }

      if muteValue != nil {
        // If the mute command is supported, set its value accordingly
        if self.supportsMuteCommand() {
          guard self.ddc?.write(command: .audioMuteScreenBlank, value: UInt16(muteValue!)) == true else {
            return
          }
        }

        self.saveValue(muteValue!, for: .audioMuteScreenBlank)
      }

      self.saveValue(volumeOSDValue, for: .audioSpeakerVolume)

      self.hideDisplayOsd()
      self.showOsd(command: .audioSpeakerVolume, value: volumeOSDValue)

      if volumeOSDValue > 0 {
        self.playVolumeChangedSound()
      }

      if let slider = self.volumeSliderHandler?.slider {
        DispatchQueue.main.async {
          slider.intValue = Int32(volumeDDCValue)
        }
      }
    }
  }

  func setBrightness(to osdValue: Int) {
    let ddcValue = UInt16(osdValue)

    if self.prefs.bool(forKey: Utils.PrefKeys.lowerContrast.rawValue) {
      if ddcValue == 0 {
        DispatchQueue.global(qos: .userInitiated).async {
          _ = self.ddc?.write(command: .contrast, value: ddcValue)
        }

        if let slider = contrastSliderHandler?.slider {
          slider.intValue = Int32(ddcValue)
        }
      } else if self.getValue(for: DDC.Command.brightness) == 0 {
        let contrastValue = self.getValue(for: DDC.Command.contrast)

        DispatchQueue.global(qos: .userInitiated).async {
          _ = self.ddc?.write(command: .contrast, value: UInt16(contrastValue))
        }
      }
    }

    DispatchQueue.global(qos: .userInitiated).async {
      guard self.ddc?.write(command: .brightness, value: ddcValue) == true else {
        return
      }

      self.showOsd(command: .brightness, value: osdValue)
    }

    if let slider = brightnessSliderHandler?.slider {
      slider.intValue = Int32(ddcValue)
    }

    self.saveValue(osdValue, for: .brightness)
  }

  func readDDCValues(for command: DDC.Command, tries: UInt, minReplyDelay delay: UInt64?) -> (current: UInt16, max: UInt16)? {
    var values: (UInt16, UInt16)?

    if self.ddc?.supported(minReplyDelay: delay) == true {
      os_log("Display supports DDC.", type: .debug)
    } else {
      os_log("Display does not support DDC.", type: .debug)
    }

    if self.ddc?.enableAppReport() == true {
      os_log("Display supports enabling DDC application report.", type: .debug)
    } else {
      os_log("Display does not support enabling DDC application report.", type: .debug)
    }

    values = self.ddc?.read(command: command, tries: tries, minReplyDelay: delay)

    if values != nil {
      return values!
    }

    return nil
  }

  func calcNewValue(for command: DDC.Command, isUp: Bool, isSmallIncrement: Bool) -> Int {
    let currentValue = self.getValue(for: command)
    let nextValue: Int

    if isSmallIncrement {
      nextValue = currentValue + (isUp ? 1 : -1)
    } else {
      let filledChicletBoxes = self.osdChicletBoxes * (Float(currentValue) / Float(self.getMaxValue(for: command)))

      var nextFilledChicletBoxes: Float
      var fillecChicletBoxesRel: Float = isUp ? 1 : -1

      // This is a workaround to ensure that if the user has set the value using a small step (that is, the current chiclet box isn't completely filled,
      // the next regular up or down step will only fill or empty that chiclet, and not the next one as well - it only really works because the max value is 100
      if (isUp && ceil(filledChicletBoxes) - filledChicletBoxes > 0.15) || (!isUp && filledChicletBoxes - floor(filledChicletBoxes) > 0.15) {
        fillecChicletBoxesRel = 0
      }

      nextFilledChicletBoxes = isUp ? ceil(filledChicletBoxes + fillecChicletBoxesRel) : floor(filledChicletBoxes + fillecChicletBoxesRel)
      nextValue = Int(Float(self.getMaxValue(for: command)) * (nextFilledChicletBoxes / self.osdChicletBoxes))
    }

    return max(0, min(self.getMaxValue(for: command), Int(nextValue)))
  }

  func getValue(for command: DDC.Command) -> Int {
    return self.prefs.integer(forKey: "\(command.rawValue)-\(self.identifier)")
  }

  func saveValue(_ value: Int, for command: DDC.Command) {
    self.prefs.set(value, forKey: "\(command.rawValue)-\(self.identifier)")
  }

  func saveMaxValue(_ maxValue: Int, for command: DDC.Command) {
    self.prefs.set(maxValue, forKey: "max-\(command.rawValue)-\(self.identifier)")
  }

  func getMaxValue(for command: DDC.Command) -> Int {
    let max = self.prefs.integer(forKey: "max-\(command.rawValue)-\(self.identifier)")

    return max == 0 ? 100 : max
  }

  func setFriendlyName(_ value: String) {
    self.prefs.set(value, forKey: "friendlyName-\(self.identifier)")
  }

  func getFriendlyName() -> String {
    return self.prefs.string(forKey: "friendlyName-\(self.identifier)") ?? self.name
  }

  func setPollingMode(_ value: Int) {
    self.prefs.set(String(value), forKey: "pollingMode-\(self.identifier)")
  }

  /*
   Polling Modes:
   0 -> .none     -> 0 tries
   1 -> .minimal  -> 5 tries
   2 -> .normal   -> 10 tries
   3 -> .heavy    -> 100 tries
   4 -> .custom   -> $pollingCount tries
   */
  func getPollingMode() -> Int {
    // Reading as string so we don't get "0" as the default value
    return Int(self.prefs.string(forKey: "pollingMode-\(self.identifier)") ?? "2") ?? 2
  }

  func getPollingCount() -> Int {
    let selectedMode = self.getPollingMode()
    switch selectedMode {
    case 0:
      return PollingMode.none.value
    case 1:
      return PollingMode.minimal.value
    case 2:
      return PollingMode.normal.value
    case 3:
      return PollingMode.heavy.value
    case 4:
      let val = self.prefs.integer(forKey: "pollingCount-\(self.identifier)")
      return PollingMode.custom(value: val).value
    default:
      return 0
    }
  }

  func setPollingCount(_ value: Int) {
    self.prefs.set(value, forKey: "pollingCount-\(self.identifier)")
  }

  private func stepSize(for command: DDC.Command, isSmallIncrement: Bool) -> Int {
    return isSmallIncrement ? 1 : Int(floor(Float(self.getMaxValue(for: command)) / self.osdChicletBoxes))
  }

  private func showOsd(command: DDC.Command, value: Int) {
    guard let manager = OSDManager.sharedManager() as? OSDManager else {
      return
    }

    var osdImage: Int64 = 1 // Brightness Image
    if command == .audioSpeakerVolume {
      osdImage = 3 // Speaker image
      if self.isMuted() {
        osdImage = 4 // Mute speaker
      }
    }

    manager.showImage(osdImage,
                      onDisplayID: self.identifier,
                      priority: 0x1F4,
                      msecUntilFade: 1000,
                      filledChiclets: UInt32(value),
                      totalChiclets: UInt32(self.getMaxValue(for: command)),
                      locked: false)
  }

  private func supportsMuteCommand() -> Bool {
    // Monitors which don't support the mute command - e.g. Dell U3419W - will have a maximum value of 100 for the DDC mute command
    return self.getMaxValue(for: .audioMuteScreenBlank) == 2
  }

  private func playVolumeChangedSound() {
    let soundPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    let soundUrl = URL(fileURLWithPath: soundPath)

    // Check if user has enabled "Play feedback when volume is changed" in Sound Preferences
    guard let preferences = Utils.getSystemPreferences(),
      let hasSoundEnabled = preferences["com.apple.sound.beep.feedback"] as? Int,
      hasSoundEnabled == 1 else {
      os_log("sound not enabled", type: .info)
      return
    }

    do {
      self.audioPlayer = try AVAudioPlayer(contentsOf: soundUrl)
      self.audioPlayer?.volume = 1
      self.audioPlayer?.prepareToPlay()
      self.audioPlayer?.play()
    } catch {
      os_log("%{public}@", type: .error, error.localizedDescription)
    }
  }
}
