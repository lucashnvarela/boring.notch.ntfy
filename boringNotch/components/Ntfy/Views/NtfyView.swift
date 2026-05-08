//
//  NtfyView.swift
//  boringNotch
//
//  Created by Lucas Varela on 26/04/2026.
//

import Defaults
import SwiftUI

struct NtfyView: View {
    @ObservedObject private var tvm = NtfyStateViewModel.shared

    @State private var selectedTopic: String?
    @State private var selectedMessageID: String?

    private var selectedMessage: NtfyMessage? {
        guard let id = selectedMessageID else { return nil }
        return tvm.messages(from: selectedTopic).first { $0.id == id }
    }

    var body: some View {
        Group {
            if tvm.topics.isEmpty {
                VStack {
                    Text("No topics yet")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text("You may not have access to any topic")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.65))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if tvm.connectedCount < 1 {
                VStack {
                    Text("No topic is currently connected")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text("Check your server connection")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.65))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    NtfyTopicsSidebar(
                        selectedTopic: $selectedTopic,
                        selectedMessageID: $selectedMessageID,
                        topics: tvm.topics.filter({ $0.isConnected }),
                        unreadCountAll: tvm.unreadCountAll,
                        onSelect: { topic in
                            withAnimation(.smooth) {
                                selectedTopic = topic?.name
                                selectedMessageID = nil
                            }
                        }
                    )
                    .frame(width: 95)
                    NtfyMessagesList(
                        selectedMessageID: $selectedMessageID,
                        messages: tvm.messages(from: selectedTopic),
                        onSelect: { message in
                            withAnimation(.smooth) {
                                selectedMessageID = selectedMessageID == message.id ? nil : message.id
                            }
                            tvm.markRead(message)
                        }
                    )
                    if let message = selectedMessage {
                        NtfyMessageDetail(message: message)
                            .frame(width: 215)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .onChange(of: tvm.topics.map(\.name)) { _, topics in
                    withAnimation(.smooth) {
                        if let topic = selectedTopic, !topics.contains(topic) {
                            selectedTopic = nil
                        }
                        selectedMessageID = nil
                    }
                }
                .onChange(of: tvm.messages(from: selectedTopic).map(\.id)) { _, ids in
                    guard let id = selectedMessageID, !ids.contains(id) else { return }
                    withAnimation(.smooth) {
                        selectedMessageID = nil
                    }
                }
            }
        }
    }
}

private struct NtfyTopicsSidebar: View {
    @Binding var selectedTopic: String?
    @Binding var selectedMessageID: String?
    let topics: [NtfyTopic]
    let unreadCountAll: Int
    let onSelect: (NtfyTopic?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                NtfyTopicItem(
                    label: "All",
                    isSelected: selectedTopic == nil,
                    unreadCount: unreadCountAll
                )
                .onTapGesture {
                    onSelect(nil)
                }
                ForEach(topics) { topic in
                    NtfyTopicItem(
                        label: topic.displayName ?? topic.name,
                        isSelected: selectedTopic == topic.name,
                        unreadCount: topic.unreadCount
                    )
                    .onTapGesture {
                        onSelect(topic)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }
}

private struct NtfyTopicItem: View {
    let label: String
    let isSelected: Bool
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(isSelected ? .white : .secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .secondary : .tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color(nsColor: .secondarySystemFill) : .clear)
        )
        .contentShape(Rectangle())
        .animation(.smooth, value: unreadCount)
    }
}

private struct NtfyMessagesList: View {
    @Binding var selectedMessageID: String?
    let messages: [NtfyMessage]
    let onSelect: (NtfyMessage) -> Void

    var body: some View {
        Group {
            if messages.isEmpty {
                VStack {
                    Text("No messages yet")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text("Waiting for incoming messages")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.65))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(messages) { message in
                            NtfyMessageItem(
                                message: message,
                                isSelected: selectedMessageID == message.id,
                            )
                            .onTapGesture {
                                onSelect(message)
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.smooth, value: messages.count)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct NtfyMessageItem: View {
    let message: NtfyMessage
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(message.isRead ? message.priority.color.opacity(0.65) : message.priority.color)
                .frame(width: 3)
                .cornerRadius(1.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(message.body.trimmingCharacters(in: .newlines))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(message.time, style: .time)
                .font(.caption)
                .foregroundColor(.white)
                .frame(width: 30, height: 30, alignment: .top)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color(nsColor: .secondarySystemFill) : .clear)
        )
        .contentShape(Rectangle())
    }
}

private struct NtfyMessageDetail: View {
    let message: NtfyMessage

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM HH:mm"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(message.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(message.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("topic")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(message.topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("time")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(Self.dateFormatter.string(from: message.time))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("priority")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(message.priority.label)
                        .font(.caption)
                        .foregroundStyle(message.priority.color)
                }
            }
        }
        .scrollIndicators(.never)
    }
}
