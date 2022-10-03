import 'dart:convert';

Map<String, CacheObjectData> cacheObjectDataFromJson(String str) =>
    Map<String, dynamic>.from(json.decode(str))
        .map((k, v) => MapEntry(k, CacheObjectData.fromJson(v)));

String cacheObjectDataToJson(Map<String, CacheObjectData> data) =>
    json.encode(data);

class CacheObjectData {
  const CacheObjectData({
    required this.id,
    required this.created,
    required this.expires,
  });

  final String id;
  final DateTime created;
  final DateTime? expires;

  factory CacheObjectData.fromJson(Map<String, dynamic> json) =>
      CacheObjectData(
        id: json['id'],
        created: DateTime.fromMillisecondsSinceEpoch(json["created"]),
        expires: json["expires"] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json["expires"]),
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "created": created.millisecondsSinceEpoch,
        "expires": expires?.millisecondsSinceEpoch,
      };
}
