import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';
import 'match_service.dart';

class ChatService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final MatchService _matchService = MatchService();

  String? get currentUserId => _supabase.auth.currentUser?.id;

  /// Upload chat image / payment receipt to Supabase Storage and return public URL
  Future<String?> uploadChatImage(XFile file) async {
    if (currentUserId == null) throw Exception("User not logged in.");
    
    final bytes = await file.readAsBytes();
    String ext = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : 'jpg';
    if (ext.isEmpty || ext == 'jpeg') ext = 'jpg';
    final mimeType = ext == 'png' ? 'image/png' : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
    final fileName = 'chat_${currentUserId}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    Object lastError = "Could not upload image to Supabase Storage.";

    // 1. Try avatars bucket under attachments/ subpath
    try {
      await _supabase.storage.from('avatars').uploadBinary(
        'attachments/$fileName',
        bytes,
        fileOptions: FileOptions(contentType: mimeType, upsert: true),
      );
      return _supabase.storage.from('avatars').getPublicUrl('attachments/$fileName');
    } catch (e1) {
      lastError = e1;
      debugPrint("Notice: upload to avatars/attachments failed ($e1), trying bucket root");
    }

    // 2. Try avatars bucket at root
    try {
      await _supabase.storage.from('avatars').uploadBinary(
        fileName,
        bytes,
        fileOptions: FileOptions(contentType: mimeType, upsert: true),
      );
      return _supabase.storage.from('avatars').getPublicUrl(fileName);
    } catch (e2) {
      lastError = e2;
      debugPrint("Notice: upload to avatars root failed ($e2), trying chat_attachments bucket");
    }

    // 3. Try chat_attachments bucket
    try {
      await _supabase.storage.from('chat_attachments').uploadBinary(
        fileName,
        bytes,
        fileOptions: FileOptions(contentType: mimeType, upsert: true),
      );
      return _supabase.storage.from('chat_attachments').getPublicUrl(fileName);
    } catch (e3) {
      lastError = e3;
      debugPrint("Notice: upload to chat_attachments failed ($e3)");
    }

    // 4. Try native IO file upload on mobile
    if (!kIsWeb && file.path.isNotEmpty) {
      try {
        final ioFile = File(file.path);
        await _supabase.storage.from('avatars').upload(
          fileName,
          ioFile,
          fileOptions: FileOptions(contentType: mimeType, upsert: true),
        );
        return _supabase.storage.from('avatars').getPublicUrl(fileName);
      } catch (e4) {
        lastError = e4;
        debugPrint("Notice: native File upload failed ($e4)");
      }
    }

    throw Exception(lastError.toString());
  }

  String? _lastSentSignature;
  DateTime? _lastSentTime;

  bool _isDuplicateSend(String signature) {
    final now = DateTime.now();
    if (_lastSentSignature == signature &&
        _lastSentTime != null &&
        now.difference(_lastSentTime!).inMilliseconds < 2500) {
      return true;
    }
    _lastSentSignature = signature;
    _lastSentTime = now;
    return false;
  }

  /// Send a chat message to a specific user (Requires mutual match OR shared match lobby)
  Future<void> sendMessage({
    required String receiverId,
    required String content,
    String? imageUrl,
    bool isReceipt = false,
  }) async {
    if (currentUserId == null || (content.trim().isEmpty && imageUrl == null)) return;

    final signature = "dm-$currentUserId-$receiverId-${content.trim()}-$imageUrl-$isReceipt";
    if (_isDuplicateSend(signature)) {
      debugPrint("Duplicate direct message prevented: $signature");
      return;
    }

    try {
      // 1. Verify mutual match exists between current user and target user
      bool isAllowed = false;
      try {
        final matchCheck = await _supabase
            .from('swipes')
            .select('id')
            .eq('user_id', currentUserId!)
            .eq('target_user_id', receiverId)
            .eq('is_match', true);

        if (matchCheck.isNotEmpty) {
          isAllowed = true;
        }
      } catch (_) {}

      // 2. If no swipe match yet, check if users share a match lobby (as host or approved participant)
      if (!isAllowed) {
        try {
          final hostMatch = await _supabase
              .from('lobby_participants')
              .select('id, lobbies!inner(host_id)')
              .eq('user_id', receiverId)
              .eq('status', 'approved')
              .eq('lobbies.host_id', currentUserId!);

          if (hostMatch.isNotEmpty) {
            isAllowed = true;
          }
        } catch (_) {}
      }

      if (!isAllowed) {
        try {
          final participantMatch = await _supabase
              .from('lobby_participants')
              .select('id, lobbies!inner(host_id)')
              .eq('user_id', currentUserId!)
              .eq('status', 'approved')
              .eq('lobbies.host_id', receiverId);

          if (participantMatch.isNotEmpty) {
            isAllowed = true;
          }
        } catch (_) {}
      }

      if (!isAllowed) {
        try {
          final myLobbies = await _supabase
              .from('lobby_participants')
              .select('lobby_id')
              .eq('user_id', currentUserId!)
              .eq('status', 'approved');

          if (myLobbies.isNotEmpty) {
            final lobbyIds = myLobbies.map((e) => e['lobby_id'].toString()).toList();
            final peerLobbies = await _supabase
                .from('lobby_participants')
                .select('id')
                .eq('user_id', receiverId)
                .eq('status', 'approved')
                .inFilter('lobby_id', lobbyIds);

            if (peerLobbies.isNotEmpty) {
              isAllowed = true;
            }
          }
        } catch (_) {}
      }

      // Auto-link mutual connection in swipes so messaging flows smoothly
      try {
        await _supabase.from('swipes').upsert({
          'user_id': currentUserId!,
          'target_user_id': receiverId,
          'action': 'like',
          'is_match': true,
          'created_at': DateTime.now().toIso8601String(),
        }, onConflict: 'user_id, target_user_id');

        await _supabase.from('swipes').upsert({
          'user_id': receiverId,
          'target_user_id': currentUserId!,
          'action': 'like',
          'is_match': true,
          'created_at': DateTime.now().toIso8601String(),
        }, onConflict: 'user_id, target_user_id');
      } catch (_) {}

      // 3. Insert message
      final msgText = content.trim().isEmpty
          ? (isReceipt ? '🧾 Payment Receipt' : '📷 Image Attachment')
          : content.trim();

      final payload = <String, dynamic>{
        'sender_id': currentUserId,
        'receiver_id': receiverId,
        'content': msgText,
        'created_at': DateTime.now().toIso8601String(),
        if (imageUrl != null) 'image_url': imageUrl,
        if (isReceipt) 'is_receipt': true,
      };

      try {
        await _supabase.from('messages').insert(payload);
      } catch (insertErr) {
        payload.remove('is_receipt');
        await _supabase.from('messages').insert(payload);
      }
    } catch (e) {
      debugPrint("Error sending chat message: $e");
      rethrow;
    }
  }

  /// Real-time stream of messages between current user and specified athlete
  Stream<List<MessageModel>> getMessagesStream(String otherUserId) {
    if (currentUserId == null) return const Stream.empty();

    try {
      return _supabase
          .from('messages')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: true)
          .map((list) {
            final seenIds = <String>{};
            final result = <MessageModel>[];
            for (final json in list) {
              final m = MessageModel.fromJson(json);
              final isRelevant = (m.senderId == currentUserId && m.receiverId == otherUserId) ||
                  (m.senderId == otherUserId && m.receiverId == currentUserId);
              if (isRelevant) {
                if (m.id.isNotEmpty && !seenIds.add(m.id)) continue;
                result.add(m);
              }
            }
            return result;
          });
    } catch (e) {
      debugPrint("Error streaming messages: $e");
      return const Stream.empty();
    }
  }

  /// Send a message inside a match lobby group chat (for Host and approved players)
  Future<void> sendLobbyMessage({
    required String lobbyId,
    required String content,
    String? imageUrl,
    bool isReceipt = false,
  }) async {
    if (currentUserId == null || (content.trim().isEmpty && imageUrl == null)) return;

    final signature = "lobby-$currentUserId-$lobbyId-${content.trim()}-$imageUrl-$isReceipt";
    if (_isDuplicateSend(signature)) {
      debugPrint("Duplicate lobby message prevented: $signature");
      return;
    }

    final msgText = content.trim().isEmpty
        ? (isReceipt ? '🧾 Payment Receipt' : '📷 Image Attachment')
        : content.trim();

    final payload = <String, dynamic>{
      'lobby_id': lobbyId.toString(),
      'sender_id': currentUserId,
      'content': msgText,
      'created_at': DateTime.now().toIso8601String(),
      if (imageUrl != null) 'image_url': imageUrl,
      if (isReceipt) 'is_receipt': true,
    };

    bool inserted = false;
    try {
      await _supabase.from('lobby_messages').insert(payload);
      inserted = true;
    } catch (e) {
      if (payload.containsKey('is_receipt')) {
        try {
          payload.remove('is_receipt');
          await _supabase.from('lobby_messages').insert(payload);
          inserted = true;
        } catch (_) {}
      }
    }

    if (!inserted) {
      final fallbackPayload = <String, dynamic>{
        'sender_id': currentUserId,
        'receiver_id': 'lobby_$lobbyId',
        'content': msgText,
        'created_at': DateTime.now().toIso8601String(),
        if (imageUrl != null) 'image_url': imageUrl,
        if (isReceipt) 'is_receipt': true,
      };

      try {
        await _supabase.from('messages').insert(fallbackPayload);
      } catch (_) {
        fallbackPayload.remove('is_receipt');
        await _supabase.from('messages').insert(fallbackPayload);
      }
    }
  }

  /// Real-time stream of messages inside a match lobby group chat
  Stream<List<MessageModel>> getLobbyMessagesStream(String lobbyId) {
    try {
      return _supabase
          .from('lobby_messages')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: true)
          .map((list) {
            final seenIds = <String>{};
            final result = <MessageModel>[];
            for (final json in list) {
              if (json['lobby_id']?.toString() != lobbyId.toString()) continue;
              final msg = MessageModel.fromJson({
                'id': json['id']?.toString() ?? '',
                'sender_id': json['sender_id']?.toString() ?? '',
                'receiver_id': json['lobby_id']?.toString() ?? lobbyId,
                'content': json['content']?.toString() ?? '',
                'image_url': json['image_url']?.toString() ?? json['imageUrl']?.toString(),
                'is_receipt': json['is_receipt'] == true,
                'created_at': json['created_at'],
              });
              if (msg.id.isNotEmpty && !seenIds.add(msg.id)) continue;
              result.add(msg);
            }
            return result;
          });
    } catch (e) {
      debugPrint("Error streaming lobby_messages, trying messages stream: $e");
      final targetKey = 'lobby_$lobbyId';
      return _supabase
          .from('messages')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: true)
          .map((list) {
            final seenIds = <String>{};
            final result = <MessageModel>[];
            for (final m in list) {
              final recId = m['receiver_id']?.toString();
              if (recId == targetKey || recId == lobbyId.toString()) {
                final msg = MessageModel.fromJson(m);
                if (msg.id.isNotEmpty && !seenIds.add(msg.id)) continue;
                result.add(msg);
              }
            }
            return result;
          });
    }
  }

  /// Fetch conversations inbox list (Matched Athletes + Last Message)
  Future<List<ConversationModel>> fetchConversations() async {
    if (currentUserId == null) return [];

    try {
      // 1. Fetch matched profiles
      List<ProfileModel> matches = await _matchService.fetchMatchedProfiles();

      final List<ConversationModel> conversations = [];

      for (final athlete in matches) {
        MessageModel? lastMsg;
        try {
          final List<dynamic> msgData = await _supabase
              .from('messages')
              .select()
              .or('and(sender_id.eq.$currentUserId,receiver_id.eq.${athlete.id}),and(sender_id.eq.${athlete.id},receiver_id.eq.$currentUserId)')
              .order('created_at', ascending: false)
              .limit(1);

          if (msgData.isNotEmpty) {
            lastMsg = MessageModel.fromJson(msgData.first as Map<String, dynamic>);
          }
        } catch (_) {}

        conversations.add(ConversationModel(
          athlete: athlete,
          lastMessage: lastMsg,
        ));
      }

      return conversations;
    } catch (e) {
      debugPrint("Error fetching conversations: $e");
      return [];
    }
  }

  /// Delete a direct message
  Future<void> deleteMessage(String messageId) async {
    final dynamic targetId = int.tryParse(messageId) ?? messageId;
    await _supabase.from('messages').delete().eq('id', targetId);
  }

  /// Delete a squad lobby message (by sender or match host)
  Future<void> deleteLobbyMessage(String messageId) async {
    final dynamic targetId = int.tryParse(messageId) ?? messageId;
    try {
      await _supabase.from('lobby_messages').delete().eq('id', targetId);
    } catch (e) {
      debugPrint("Notice: could not delete from lobby_messages: $e");
    }
    try {
      await _supabase.from('messages').delete().eq('id', targetId);
    } catch (e) {
      debugPrint("Notice: could not delete from messages: $e");
    }
  }
}

