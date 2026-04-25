import Foundation

struct NtfyNotificationModel: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var topic: String
    var title: String?
    var message: String?
    var time: Date
    var priority: Int?
    var tags: [String]?
    var click: String?

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return topic
    }

    var displayBody: String {
        message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct NtfyWireMessage: Codable {
    var id: String?
    var topic: String?
    var title: String?
    var message: String?
    var time: TimeInterval?
    var priority: Int?
    var tags: [String]?
    var click: String?
    var event: String?

    func toNotification(fallbackTopic: String) -> NtfyNotificationModel? {
        if let event, event != "message" {
            return nil
        }

        let resolvedTopic = topic ?? fallbackTopic
        let resolvedId = id ?? UUID().uuidString
        let resolvedTime = Date(timeIntervalSince1970: time ?? Date().timeIntervalSince1970)

        return NtfyNotificationModel(
            id: resolvedId,
            topic: resolvedTopic,
            title: title,
            message: message,
            time: resolvedTime,
            priority: priority,
            tags: tags,
            click: click
        )
    }
}
