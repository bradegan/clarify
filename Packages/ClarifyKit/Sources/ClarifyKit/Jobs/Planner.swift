import Foundation

/// Natural planning for a project reminder. Writes the plan into the project's
/// notes and creates the first next action.
public struct Planner: Sendable {
    let services: Services
    public init(_ services: Services) { self.services = services }

    /// The model call, made before anything is saved so a failure leaves the
    /// inbox item untouched and retryable.
    public func generate(project title: String, body: String) async throws -> ProjectPlan {
        let input = """
        Project: \(title)
        Notes: \(body.isEmpty ? "(none)" : body)
        Contexts: \(services.settings.contexts.joined(separator: " "))
        Areas: \(try await Clarifier(services).areasText())
        """
        let plan = try await services.model.respond(instructions: Prompts.text("planner"), input: input, as: ProjectPlan.self)
        try plan.validate()
        return plan
    }

    /// Writes the plan into the project's notes and creates the first next action.
    public func apply(_ plan: ProjectPlan, to project: ReminderItem, energy: String) async throws {
        var header = project.header ?? Header(["kind": Kind.project.rawValue])
        header["project"] = project.title
        let planText = """
        Purpose
        \(plan.purpose)

        Principles
        \(plan.principles.map { "- \($0)" }.joined(separator: "\n"))

        Outcome
        \(plan.outcomeVision)

        Brainstorm
        \(plan.brainstorm.map { "- \($0)" }.joined(separator: "\n"))

        Next actions
        \(zip(plan.cleanedNextActions, zip(plan.contexts, plan.minutes)).map { "- \($0.1.0) \($0.0) (\($0.1.1) min)" }.joined(separator: "\n"))
        """
        var updated = project
        updated.notes = header.render(body: project.body.isEmpty ? planText : project.body + "\n\n" + planText)
        try await services.store.save(updated)
        try await services.ledger.record(updated.id, hash: updated.contentHash)

        var actionHeader = Header(["kind": Kind.action.rawValue])
        actionHeader["context"] = plan.contexts[0]
        actionHeader["minutes"] = String(plan.minutes[0])
        actionHeader["energy"] = energy
        actionHeader["project"] = project.title
        actionHeader["since"] = DateOnly.string(services.now())
        actionHeader["reason"] = "First step of '\(project.title)'."
        let title = Clarifier.prefixed(plan.cleanedNextActions[0], with: plan.contexts[0])
        try await services.store.create(NewReminder(title: title, notes: actionHeader.render(body: ""), list: Bucket.nextActions.rawValue))
        services.log("Planned project '\(project.title)'")
    }
}
