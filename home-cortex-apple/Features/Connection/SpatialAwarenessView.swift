import SwiftUI
import simd

struct SpatialAwarenessView: View {
  @Bindable var embodiment: EmbodimentController
  let caller: ConnectionController
  @State private var wizard = false
  private var calibration: SpatialCalibrationSession { embodiment.localization.calibration }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Spatial Awareness").font(.headline)
      LabeledContent(
        "Motion tracking",
        value: embodiment.localization.camera.tracking.supported ? "Supported" : "Unavailable")
      LabeledContent(
        "Household localization",
        value: calibration.state == .anchored
          ? "Aligned · Accuracy unvalidated"
          : calibration.state == .relocalizationRequired ? "Needs relocalization" : "Not calibrated"
      )
      LabeledContent(
        "Space", value: embodiment.selectedLocalizationSpace?.displayName ?? "Not selected")
      if let reference = calibration.reference {
        LabeledContent("Reference", value: reference.displayName)
      }
      if let time = calibration.calibratedAt {
        LabeledContent("Last captured", value: time.formatted(date: .abbreviated, time: .shortened))
      }
      Text(calibration.message).font(.footnote).foregroundStyle(.secondary)
      if let pose = calibration.bodyPose {
        let a = IPhoneBodyFrame.euler(pose.rotation)
        LabeledContent(
          "Provisional X / Y / Z",
          value: String(
            format: "%.2f / %.2f / %.2f m", pose.translation.x, pose.translation.y,
            pose.translation.z))
        LabeledContent(
          "Yaw / Pitch / Roll",
          value: String(
            format: "%.1f / %.1f / %.1f°", a.x * 180 / .pi, a.y * 180 / .pi, a.z * 180 / .pi))
        Text("Accuracy unknown. This pose is diagnostic and is not canonical household telemetry.")
          .font(.footnote)
      }
      Button(
        embodiment.pendingReferenceSave != nil
          ? "Resume reference save"
          : calibration.reference == nil
            ? "Set Up Spatial Awareness" : "Relocalize / Manage Reference"
      ) { wizard = true }
      .accessibilityIdentifier("embodiment.spatial.setup")
      .disabled(caller.displayedState != .connected)
      if !embodiment.localizationSelected {
        Text(
          "Turn on Visual-inertial localization to capture a reference. Saved references are retained when tracking is off."
        ).font(.footnote)
      }
    }
    .sheet(isPresented: $wizard) {
      SpatialCalibrationWizard(embodiment: embodiment, caller: caller)
    }
  }
}

private enum CalibrationStep: Int, CaseIterable {
  case space, reference, prepare, capture, validate, save, done
}
private enum ReferenceOperation { case create, relocalize, redefine }

struct SpatialCalibrationWizard: View {
  @Bindable var embodiment: EmbodimentController
  let caller: ConnectionController
  @Environment(\.dismiss) private var dismiss
  @State private var step = CalibrationStep.space
  @State private var operation = ReferenceOperation.create
  @State private var selectedReferenceID = ""
  @State private var label = ""
  @State private var placement = ""
  @State private var direction = ""
  @State private var x = ""
  @State private var y = ""
  @State private var z = ""
  @State private var heading = ""
  @State private var placementConfirmed = false
  @State private var frameConfirmed = false
  @State private var prepared: PendingReferenceSave?
  @State private var candidate: CalibrationCandidate?
  @State private var failure: String?
  @State private var busy = false
  @State private var captureTask: Task<Void, Never>?
  @State private var saveTask: Task<Void, Never>?
  @State private var confirmRedefinition = false
  @State private var status = ""
  @State private var keptAwake = false
  private var space: LocalizationSpaceOption? { embodiment.selectedLocalizationSpace }
  private var selectedReference: LocalizationReferenceOption? {
    space?.references.first { $0.id == selectedReferenceID }
  }
  private var tracking: ARLocalTracking { embodiment.localization.camera.tracking }
  private var measuredExtrinsic: RigidTransform? {
    guard let t = IPhoneRearCameraGeometry.opticalCenterBodyMeters,
      let q = IPhoneRearCameraGeometry.calibratedBodyFromOptical
    else { return nil }
    return try? RigidTransform(rotation: q, translation: t)
  }
  private var ready: Bool {
    embodiment.localizationSelected && embodiment.isOnline && tracking.running
      && tracking.state == .unanchored
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Step \(min(step.rawValue+1,6)) of 6").font(.caption).foregroundStyle(.secondary)
          content
        }
        if let failure {
          Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("spatial.error") }
        }
        if busy { ProgressView(status) }
        if step != .done && !busy {
          Section {
            if step.rawValue > 0 {
              Button("Back") {
                candidate = nil
                failure = nil
                step = CalibrationStep(rawValue: step.rawValue - 1) ?? .space
              }
            }
            if step == .space {
              Button("Continue") {
                step = .reference
                label = (space?.displayName ?? "Room") + " Reference"
              }.disabled(space == nil)
            }
            if step == .reference { Button("Continue") { prepareDraft() } }
            if step == .prepare {
              Button("Continue") { step = .capture }.disabled(!placementConfirmed)
            }
            if step == .capture {
              Button("Start automatic flat capture") { startCapture() }.disabled(
                !embodiment.localizationSelected || !embodiment.isOnline)
              if operation != .relocalize {
                Button("Save physical reference provisionally") {
                  step = .validate
                  candidate = nil
                }
              }
            }
            if step == .validate {
              Button(operation == .relocalize ? "Activate session alignment" : "Continue to save") {
                if operation == .relocalize { activate() } else { step = .save }
              }.disabled(operation == .relocalize && candidate == nil)
            }
            if step == .save {
              Button("Save reference") {
                if operation == .redefine { confirmRedefinition = true } else { save() }
              }.disabled(caller.displayedState != .connected || space?.can_manage != true)
            }
            if !status.isEmpty { Text(status).font(.footnote) }
          }
        }
        if step == .done { Button("Done") { dismiss() } }
      }
      .navigationTitle("Spatial Calibration")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            captureTask?.cancel()
            saveTask?.cancel()
            dismiss()
          }
        }
      }
      .alert("Redefine shared reference?", isPresented: $confirmRedefinition) {
        Button("Save new reference version", role: .destructive) { save() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This changes a shared household reference. Existing room coordinates are preserved. Other embodiments must relocalize against the new version."
        )
      }
      .task {
        await embodiment.loadLocalizationReferences(caller: caller)
        if let pending = embodiment.pendingReferenceSave {
          embodiment.selectedLocalizationSpaceID = pending.spaceID
          prepared = pending
          selectedReferenceID = pending.reference.id
          operation = pending.expectedRevision == 0 ? .create : .redefine
          step = .save
          status =
            "A previous save was interrupted. Retry the same reference; it will not create a duplicate."
        }
      }
      .onDisappear {
        captureTask?.cancel()
        saveTask?.cancel()
        if keptAwake { UIApplication.shared.isIdleTimerDisabled = false }
      }
    }
  }
  @ViewBuilder private var content: some View {
    switch step {
    case .space:
      Text("Choose an existing household space.")
      Picker("Space", selection: $embodiment.selectedLocalizationSpaceID) {
        Text("Select a space").tag("")
        ForEach(embodiment.localizationSpaces) { Text($0.displayName).tag($0.space_id) }
      }.accessibilityIdentifier("spatial.space")
      Text("To add a room, use your household's authorized editing workflow.").font(.footnote)
      if let message = embodiment.localizationReferenceMessage { Text(message) }
      Button("Refresh") { Task { await embodiment.loadLocalizationReferences(caller: caller) } }
    case .reference:
      if let space {
        if !space.references.isEmpty {
          Picker("Reference", selection: $selectedReferenceID) {
            Text("Choose a reference").tag("")
            ForEach(space.references) { Text($0.displayName).tag($0.id) }
          }
          if let reference = selectedReference {
            Text(reference.reference.placement_instructions)
            Button("Use existing reference") {
              operation = .relocalize
              prepareDraft()
            }
            if space.can_manage {
              Button("Redefine this reference") {
                operation = .redefine
                label = reference.displayName
                placement = reference.reference.placement_instructions
                x = String(reference.position.x)
                y = String(reference.position.y)
                z = String(reference.position.z)
                heading = String(reference.orientation.yaw * 180 / .pi)
              }
            }
          }
        }
        if space.can_manage {
          if operation != .redefine {
            Text("Create a fixed, flat placement reference").font(.headline)
          }
          TextField("Reference name", text: $label)
          TextField(
            "Fixed surface and exact placement (e.g. bedside-table corner)", text: $placement,
            axis: .vertical)
          TextField(
            "Fixed edge/direction for the phone's top edge", text: $direction, axis: .vertical)
          if !space.coordinate_ready {
            Text(
              "This creates a user-established local frame: origin at the phone's body center in this fixed placement; +X along the top edge; +Y to the left when facing +X; +Z vertically up. Units are meters; rotations are radians. It is not a geographic or whole-house survey."
            ).font(.footnote)
            Toggle("This physical position and direction are repeatable", isOn: $frameConfirmed)
          } else {
            Text(
              "The room frame is already defined and will be preserved. Enter the measured phone body-center position in that frame and the top-edge direction measured from +X toward +Y."
            ).font(.footnote)
            HStack {
              TextField("X (m)", text: $x)
              TextField("Y (m)", text: $y)
              TextField("Z (m)", text: $z)
            }.keyboardType(.numbersAndPunctuation)
            TextField("Top-edge direction (degrees)", text: $heading).keyboardType(
              .numbersAndPunctuation)
          }
          if operation == .relocalize {
            Button("Create a new reference instead") {
              operation = .create
              selectedReferenceID = ""
            }
          }
        } else {
          Text(
            "You can use an existing reference. A household administrator must authorize you before you can create or redefine one."
          ).font(.footnote)
        }
      }
    case .prepare:
      Text("Prepare a flat reference").font(.headline)
      Text(prepared?.reference.reference.placement_instructions ?? "")
      Text(
        "Use the same fixed placement and direction every time. Lay the phone screen-down so the rear camera can see the room. Do not cover the camera. No upright hold is needed."
      )
      Toggle("I can reproduce this position and direction", isOn: $placementConfirmed)
      LabeledContent("Camera access", value: embodiment.localization.camera.permissionLabel)
      LabeledContent("Spatial tracking", value: embodiment.localizationSelected ? "On" : "Off")
      LabeledContent("DEVICE connection", value: embodiment.isOnline ? "Ready" : "Disconnected")
      if embodiment.localization.camera.availability != nil {
        Button("Open iPhone Settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        }
      }
      if !embodiment.localizationSelected {
        Text(
          "Enable Visual-inertial localization in Embodiment before capturing. This wizard does not enable sensors automatically."
        )
      }
    case .capture:
      Text("Lay flat to capture").font(.headline)
      LabeledContent("Tracking", value: tracking.state.rawValue)
      Text(tracking.reason)
      Text(
        "Start capture, then lay the phone screen-down at the fixed placement. It captures automatically when tracking is healthy, the camera faces up and the phone stays still. A vibration signals completion. Pick it up afterward."
      )
      if measuredExtrinsic == nil {
        Text(CalibrationError.geometry.localizedDescription).font(.footnote)
      }
    case .validate:
      Text(candidate == nil ? "Physical reference only" : "Reference observations captured").font(
        .headline)
      if let candidate {
        Text(
          "Steady observations were obtained in the current tracking session. This checks repeatability, not spatial accuracy."
        )
        if candidate.alignment == nil {
          Text(CalibrationError.geometry.localizedDescription)
        } else {
          Text(
            "The household alignment is geometrically valid. Accuracy remains unvalidated and canonical pose publication is disabled."
          )
        }
      } else {
        Text(
          "The placement definition will be saved provisionally. No household alignment or accuracy was established."
        )
      }
    case .save:
      Text("Save household reference").font(.headline)
      Text(prepared?.reference.displayName ?? "")
      Text(
        "This stores the fixed physical placement in Home Cortex. Session tracking coordinates are not stored as household truth."
      )
      if operation == .redefine {
        Text(
          "This is a new version of a shared reference. You will confirm the change before saving.")
      }
    case .done:
      Text("Reference available").font(.headline)
      Text(status)
      Text(embodiment.localization.calibration.message)
      Text("Spatial accuracy is unvalidated. Canonical household pose remains unavailable.").font(
        .footnote)
    }
  }
  private func prepareDraft() {
    failure = nil
    candidate = nil
    guard let space else { return }
    if operation == .relocalize, let reference = selectedReference {
      prepared = .init(
        spaceID: space.space_id, reference: reference,
        expectedRevision: reference.reference.revision, frameDefinition: nil)
      step = .prepare
      return
    }
    guard space.can_manage, let person = embodiment.localizationReferencePersonID,
      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !placement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      failure =
        "Provide a name, a fixed physical placement and its direction. Reference-management authority is required."
      return
    }
    let id =
      operation == .redefine
      ? selectedReference?.id
      : "reference_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    guard let id else { return }
    let position: ReferenceVector
    let yaw: Double
    if space.coordinate_ready {
      guard let px = Double(x), let py = Double(y), let pz = Double(z), let h = Double(heading),
        [px, py, pz, h].allSatisfy(\.isFinite), [px, py, pz].allSatisfy({ abs($0) < 10000 })
      else {
        failure =
          "Enter measured body-center coordinates and the top-edge direction in the existing room frame."
        return
      }
      position = .init(x: px, y: py, z: pz)
      yaw = h * .pi / 180
    } else {
      guard frameConfirmed else {
        failure =
          "Confirm a repeatable physical origin and direction. Selecting a room cannot establish coordinates."
        return
      }
      position = .init(x: 0, y: 0, z: 0)
      yaw = 0
    }
    let provenance = ReferenceProvenance(
      person_id: person, surveyed_at: V1Time.format(Date()),
      method: "User-established fixed flat placement; independent accuracy not validated")
    let instructions =
      "Lay this iPhone flat, screen-down at: \(placement). Point its top edge along: \(direction). Reuse the same physical position and direction."
    let reference = LocalizationReferenceOption(
      id: id, type: "survey_point", position: position,
      orientation: .init(yaw: yaw, pitch: .pi / 2, roll: 0),
      reference: .init(
        revision: operation == .redefine ? (selectedReference?.reference.revision ?? 0) + 1 : 1,
        reference_frame: "fixed_body_placement.v1",
        coordinate_convention: "right_handed_zyx_z_up_si_v1", body_frame: "iphone.body.v1",
        body_in_reference: .identity,
        placement_instructions: instructions,
        measurement_notes:
          "User-established relative reference. Placement error, camera/body geometry, drift and spatial accuracy are not validated.",
        provenance: provenance, status: "provisional", display_name: label))
    let frame: JSONValue?
    if space.coordinate_ready {
      frame = nil
    } else {
      frame = .object([
        "source": .string("user_established_local"),
        "origin_definition": .string("Body center of the phone at " + placement),
        "positive_x_definition": .string("Phone top edge along " + direction),
        "positive_y_definition": .string("Left when facing the marked positive X direction"),
        "positive_z_definition": .string("vertical_up"),
        "convention": .string("right_handed_zyx_z_up_si_v1"), "reference_id": .string(id),
        "provenance": .object([
          "person_id": .string(person), "surveyed_at": .string(provenance.surveyed_at),
          "method": .string(provenance.method),
        ]),
      ])
    }
    prepared = .init(
      spaceID: space.space_id, reference: reference,
      expectedRevision: operation == .redefine ? selectedReference?.reference.revision ?? 0 : 0,
      frameDefinition: frame)
    step = .prepare
  }
  private func startCapture() {
    guard let prepared else { return }
    failure = nil
    busy = true
    status = "Waiting for healthy tracking and a steady flat placement…"
    keptAwake = !UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    captureTask = Task { @MainActor in
      defer {
        busy = false
        if keptAwake {
          UIApplication.shared.isIdleTimerDisabled = false
          keptAwake = false
        }
      }
      let deadline = Date().addingTimeInterval(60)
      var samples: [CalibrationObservation] = []
      let world = tracking.worldID
      let session = embodiment.connection.session?.sessionID
      do {
        guard let world, let session else { throw CalibrationError.tracking }
        while Date() < deadline {
          try Task.checkCancellation()
          guard world == tracking.worldID, session == embodiment.connection.session?.sessionID
          else { throw CalibrationError.reset }
          if ready, let pose = tracking.cameraPose, let time = tracking.measuredAt,
            Date().timeIntervalSince(time) < 0.3
          {
            let observation = CalibrationObservation(
              worldID: world, deviceSession: session, measuredAt: time, cameraPose: pose,
              healthy: true)
            if observation.screenDownAndFlat {
              if samples.last?.measuredAt != time { samples.append(observation) }
              if samples.count >= 15 {
                do {
                  candidate = try CalibrationValidation.candidate(
                    reference: prepared.reference, spaceID: prepared.spaceID,
                    observations: samples, bodyFromCamera: measuredExtrinsic, now: Date())
                  step = .validate
                  UINotificationFeedbackGenerator().notificationOccurred(.success)
                  return
                } catch CalibrationError.moved {
                  samples.removeAll()
                  status = "Wait for a steady flat placement…"
                }
              }
            } else {
              samples.removeAll()
            }
          } else {
            samples.removeAll()
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        throw CalibrationError.tracking
      } catch is CancellationError { return } catch {
        failure = error.localizedDescription
        UINotificationFeedbackGenerator().notificationOccurred(.error)
      }
    }
  }
  private func activate() {
    guard let candidate else { return }
    do {
      guard ready else { throw CalibrationError.tracking }
      try embodiment.localization.calibration.activate(
        candidate, currentWorld: tracking.worldID,
        currentSession: embodiment.connection.session?.sessionID, bodyFromCamera: measuredExtrinsic)
      embodiment.rememberLocalizationReference(candidate.reference, spaceID: candidate.spaceID)
      status =
        candidate.alignment == nil
        ? "Reference captured provisionally. Household alignment requires measured device geometry."
        : "Session alignment activated provisionally."
      step = .done
    } catch { failure = error.localizedDescription }
  }
  private func save() {
    guard let prepared else { return }
    busy = true
    failure = nil
    status = "Saving reference…"
    saveTask = Task { @MainActor in
      defer { busy = false }
      do {
        _ = try await embodiment.saveLocalizationReference(
          prepared.reference, spaceID: prepared.spaceID,
          expectedRevision: prepared.expectedRevision, frameDefinition: prepared.frameDefinition,
          caller: caller)
        if candidate != nil && ready {
          activate()
        } else {
          status = "Physical reference saved. Return to its fixed placement to relocalize."
          step = .done
        }
        if step != .done {
          status =
            "Reference saved; tracking changed before activation. Relocalize using the saved reference."
          step = .done
        }
      } catch {
        failure = error.localizedDescription
        status = "Save was not confirmed. Retry this same reference to recover without duplicates."
      }
    }
  }
}
