import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_simple_cache_manager/database.dart';
import 'package:synchronized/synchronized.dart';

Future<String> get localCachePath async {
  var directory = await getTemporaryDirectory();
  return directory.path;
}

/// Stores objects using an id system.
/// The id can be a path and in appropriate file systems will actually
/// create sub-folders
/// cows
/// cows.js
/// cow/fred.js
/// NOTE: DO NOT INSTANTIATE MORE THAN 1 OBJECT OF EACH UNIQUE KEY.
/// THIS COULD CAUSE UNEXPECTED BEHAVIOR
class SimpleCache {
  String database_id;

  ///Evicts expired objects automatically
  bool evictExpired;

  Map<String, CacheObjectData> _databaseCache = <String, CacheObjectData>{};

  //FOR WEB IMPLEMENATION
  Map<String, VirtualFile> _virtualFileSystem = Map<String, VirtualFile>();

  final _evictLock = Lock();

  Timer? _flush;

  SimpleCache({required this.database_id, this.evictExpired = false}) {
    //Preload the database when creating object
    _getDatabase();
  }

  Future<Map<String, CacheObjectData>> _getDatabase() async {
    if (kIsWeb) {
      //toList is used to create a new object so it is not linked
      return _databaseCache;
    }
    if (_databaseCache.isEmpty) {
      File f = File('${await localCachePath}/$database_id.json');
      if (await f.exists()) {
        try {
          _databaseCache = cacheObjectDataFromJson(
              await File('${await localCachePath}/$database_id.json')
                  .readAsString());
          return _databaseCache;
        } catch (e, s) {
          print('$e $s');
        }
      }
    } else {
      return _databaseCache;
    }
    return <String, CacheObjectData>{};
  }

  //Writes the database to disk
  Future _scheduleFlushDatabase() async {
    if (kIsWeb) {
      return;
    }
    //Schedule the database to be flushed in 100ms
    _flush?.cancel();
    _flush = Timer(Duration(milliseconds: 100), () async {
      await File('${await localCachePath}/$database_id.json')
          .writeAsString(cacheObjectDataToJson(_databaseCache));
    });
  }

  Future _deleteDatabaseItem(String id) async {
    var database = await _getDatabase();
    database.remove(id);
    await _scheduleFlushDatabase();
  }

  Future _setDatabaseItem(CacheObjectData data) async {
    var database = await _getDatabase();
    database[data.id] = data;
    await _scheduleFlushDatabase();
  }

  Future<CacheObjectData?> _getDatabaseItem(String id) async {
    var database = await _getDatabase();
    return database[id];
  }

  //Removes all of the objects in this cache.
  Future clear() async {
    //Web implementation
    if (kIsWeb) {
      _virtualFileSystem.clear();
      return;
    }
    var cache = await getTemporaryDirectory();
    if (await cache.exists()) {
      for (var file in await cache.list(recursive: true).toList()) {
        if (!file.uri.toString().endsWith("/")) {
          try {
            await file.delete();
          } catch (e) {}
        }
      }
    }
  }

  ///Removes all objects that are expired
  Future evictExpiredObjects() async {
    //Web implementation
    var database = await _getDatabase();

    for (var item in database.values.toList()) {
      var expires = item.expires;
      if (expires != null && DateTime.now().isAfter(expires)) {
        await removeObject(item.id);
      }
    }
  }

  ///file like 'image_cache/logo.png'
  Future<File> _getFileURL(String id) async {
    return File('${await localCachePath}/$database_id/$id');
  }

  Future writeObjectString(
      {required String id, required String data, int? ttl}) async {
    await writeObjectBytes(id: id, data: utf8.encode(data), ttl: ttl);
  }

  Future writeObjectBytes(
      {required String id, required List<int> data, int? ttl}) async {
    await _setDatabaseItem(CacheObjectData(
        id: id,
        created: DateTime.now(),
        expires:
            ttl == null ? null : DateTime.now().add(Duration(seconds: ttl))));
    if (kIsWeb) {
      //Web only implementation. Web implementation ignores the filemode parameter
      var newFile = VirtualFile(path: id, modified: DateTime.now(), data: data);
      _virtualFileSystem[id] = newFile;
      return;
    }

    //Write data file
    File f = await _getFileURL(id);
    try {
      //Creates folders as needed
      await f.create(recursive: true);
      await f.writeAsBytes(data);
    } catch (e, s) {
      print('$e, $s');
    }
  }

  Future<CacheObject?> getObject({required String id}) async {
    if (evictExpired) {
      _evictLock.synchronized(() async {
        await evictExpiredObjects();
      });
    }
    var item = await _getDatabaseItem(id);
    if (item == null) {
      return null;
    }

    if (kIsWeb) {
      //Web only implementation.
      var f = _virtualFileSystem[id];
      if (f != null) {
        return CacheObject(
            age: DateTime.now().difference(item.created),
            expires: item.expires,
            bytes: f.bytes);
      }
      return null;
    }
    File f = await _getFileURL(id);
    //Check if the item exists in the file system.
    //If it does not exist then remove it from the index database.
    if (await f.exists() == false) {
      print("cache item ${id} does not exist on disk");
      await _deleteDatabaseItem(id);
      return null;
    }
    try {
      final bytes = await f.readAsBytes();
      return CacheObject(
          age: DateTime.now().difference(item.created),
          expires: item.expires,
          bytes: bytes);
    } catch (e, s) {
      print('$e, $s');
    }
    return null;
  }

  Future removeObject(String id) async {
    if (kIsWeb) {
      _virtualFileSystem.removeWhere((key, value) => value.path == id);
      //Remove item from database
      await _deleteDatabaseItem(id);
      return;
    }
    try {
      File f = await _getFileURL(id);
      //Remote item from file system
      if (await f.exists()) {
        await f.delete();
      }
      //Remove item from database
      await _deleteDatabaseItem(id);
    } catch (e, s) {
      print('$e, $s');
    }
  }
}

//Representation of a cache object.
class CacheObject {
  CacheObject({required this.age, required this.bytes, this.expires});

  Duration age;
  DateTime? expires;
  Uint8List bytes;

  String get string {
    return utf8.decode(bytes);
  }

  //Returns if the current time is after the expires time of this object
  bool get isExpired {
    if (expires == null) {
      return false;
    }
    return DateTime.now().isAfter(expires!);
  }
}

//Virtual file is a cache that has a path, and some metadata like age.
class VirtualFile {
  String path;
  DateTime modified;
  List<int> data; //I know this is not efficient but I also do not care.

  Uint8List get bytes {
    return Uint8List.fromList(data);
  }

  String get string {
    return utf8.decode(data);
  }

  VirtualFile({required this.path, required this.modified, required this.data});
}
