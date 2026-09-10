/// 系统消息模型（来自加密网关 `/api/app/v1/messages`）。

class SystemMessage {
  final String id;
  final String title;
  final String content;
  final String kind; // system | mute | ban
  final bool read;
  final int createdAt;

  const SystemMessage({
    required this.id,
    required this.title,
    required this.content,
    this.kind = 'system',
    this.read = false,
    this.createdAt = 0,
  });

  factory SystemMessage.fromJson(Map<String, dynamic> json) {
    return SystemMessage(
      id: (json['message_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      kind: (json['kind'] ?? 'system').toString(),
      read: (json['read'] as num?)?.toInt() == 1,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 系统消息分页结果。
class MessagePage {
  final int unread;
  final List<SystemMessage> items;

  const MessagePage({this.unread = 0, this.items = const []});
}
