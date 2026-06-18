import Foundation

/// One step in a first-aid protocol.
struct FirstAidStep: Equatable, Identifiable {
    let id: String
    /// Spoken / displayed instruction for this step.
    let instruction: String
    /// `true` for the call-emergency-services gate that opens every protocol.
    var isEmergencyGate: Bool = false
    /// `true` if this step paces CPR compressions (the metronome runs while it's active).
    var startsCPR: Bool = false
}

/// A structured, hands-free first-aid protocol (First-Aid / Emergency Assist). **Advisory only — not a
/// medical device.** Every protocol opens with the same gate: confirm emergency services were called.
struct FirstAidProtocol: Equatable, Identifiable {
    let id: String
    let title: String
    let steps: [FirstAidStep]

    var firstStep: FirstAidStep { steps[0] }

    /// The shared step-0 gate prepended to every protocol.
    static let emergencyGate = FirstAidStep(
        id: "call_emergency",
        instruction: "First — has someone called emergency services (911 / 112)? If not, call now or have someone nearby call, then say \"next\".",
        isEmergencyGate: true
    )

    private static func make(_ id: String, _ title: String, _ steps: [FirstAidStep]) -> FirstAidProtocol {
        FirstAidProtocol(id: id, title: title, steps: [emergencyGate] + steps)
    }

    /// The highest-value bystander protocols. (MARCH trauma + others can extend this.)
    static let catalog: [FirstAidProtocol] = [
        make("cpr", "CPR / AED", [
            FirstAidStep(id: "responsive", instruction: "Check for response and breathing. If they're not breathing normally, start compressions."),
            FirstAidStep(id: "position", instruction: "Place the heel of one hand in the centre of the chest, the other on top, arms straight."),
            FirstAidStep(id: "compress", instruction: "Push hard and fast, at least 5 cm deep. Follow the beat. After 30 compressions, give 2 breaths.", startsCPR: true),
            FirstAidStep(id: "aed", instruction: "If an AED is available, turn it on and follow its voice. Say \"AED\" and I'll find the nearest one."),
            FirstAidStep(id: "continue", instruction: "Keep going — 30 compressions to 2 breaths — until help arrives or they start breathing."),
        ]),
        make("choking", "Choking", [
            FirstAidStep(id: "assess", instruction: "Ask \"are you choking?\" If they can't speak, cough, or breathe, act now."),
            FirstAidStep(id: "back_blows", instruction: "Lean them forward and give 5 firm back blows between the shoulder blades with the heel of your hand."),
            FirstAidStep(id: "thrusts", instruction: "If still blocked, give 5 abdominal thrusts — fist above the navel, pull sharply inward and up."),
            FirstAidStep(id: "repeat", instruction: "Alternate 5 back blows and 5 thrusts until the object clears or they become unresponsive — then start CPR."),
        ]),
        make("bleeding", "Severe Bleeding", [
            FirstAidStep(id: "pressure", instruction: "Press firmly on the wound with a clean cloth or your hand and don't let go."),
            FirstAidStep(id: "elevate", instruction: "If you can, raise the injured area above the heart while keeping pressure on."),
            FirstAidStep(id: "tourniquet", instruction: "If bleeding from a limb won't stop, apply a tourniquet 5 cm above the wound, tighten until it stops, and note the time."),
            FirstAidStep(id: "monitor", instruction: "Keep them warm and still, keep pressure on, and watch their breathing until help arrives."),
        ]),
        make("recovery", "Recovery Position", [
            FirstAidStep(id: "check", instruction: "They're breathing but unresponsive. Kneel beside them."),
            FirstAidStep(id: "roll", instruction: "Place the near arm out, the far hand against their cheek, bend the far knee, and roll them toward you onto their side."),
            FirstAidStep(id: "airway", instruction: "Tilt the head back gently to keep the airway open, and check breathing continuously until help arrives."),
        ]),
        make("march", "Trauma (MARCH)", [
            FirstAidStep(id: "m", instruction: "Massive bleeding — control it first: direct pressure or a tourniquet on a limb."),
            FirstAidStep(id: "a", instruction: "Airway — make sure it's open; recovery position if they're unconscious and breathing."),
            FirstAidStep(id: "r", instruction: "Respiration — check breathing; seal any sucking chest wound with a hand or plastic."),
            FirstAidStep(id: "c", instruction: "Circulation — recheck bleeding control and look for shock; keep them still."),
            FirstAidStep(id: "h", instruction: "Hypothermia — keep them warm; cover them and insulate from the ground."),
        ]),
    ]

    static func named(_ id: String) -> FirstAidProtocol? {
        catalog.first { $0.id == id.lowercased() }
    }

    /// All protocol ids, for the tool schema / prompt.
    static var ids: [String] { catalog.map(\.id) }
}

/// Walks a `FirstAidProtocol` step by step (voice/band-driven). Pure — no UI, no audio.
struct FirstAidProtocolRunner: Equatable {
    let proto: FirstAidProtocol
    private(set) var index: Int = 0

    var current: FirstAidStep { proto.steps[index] }
    var isOnLastStep: Bool { index >= proto.steps.count - 1 }

    /// Advance to the next step; returns it, or nil if already on the last step.
    @discardableResult
    mutating func advance() -> FirstAidStep? {
        guard index < proto.steps.count - 1 else { return nil }
        index += 1
        return current
    }

    /// Go back one step (clamped at the gate).
    @discardableResult
    mutating func back() -> FirstAidStep {
        index = max(0, index - 1)
        return current
    }
}
