import "dart:convert";
import "dart:developer";

import "package:computer/computer.dart";
import "package:flutter/foundation.dart";
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/extensions/stop_watch.dart";
import "package:photos/models/api/entity/type.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/local_entity_data.dart";
import 'package:photos/models/ml/face/face.dart';
import "package:photos/models/ml/face/person.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/entity_service.dart";
import "package:photos/utils/face/face_thumbnail_cache.dart";
import "package:shared_preferences/shared_preferences.dart";

class PersonService {
  final EntityService entityService;
  final MLDataDB faceMLDataDB;
  final SharedPreferences prefs;
  final _emailToPartialPersonDataMapCache = <String, Map<String, String>>{};

  PersonService(this.entityService, this.faceMLDataDB, this.prefs);

  // instance
  static PersonService? _instance;
  static const kPersonIDKey = "person_id";
  static const kNameKey = "name";

  Future<List<PersonEntity>>? _cachedPersonsFuture;
  int _lastCacheRefreshTime = 0;

  static PersonService get instance {
    if (_instance == null) {
      throw Exception("PersonService not initialized");
    }
    return _instance!;
  }

  static bool get isInitialized => _instance != null;

  late Logger logger = Logger("PersonService");

  static Future<void> init(
    EntityService entityService,
    MLDataDB faceMLDataDB,
    SharedPreferences prefs,
  ) async {
    _instance = PersonService(entityService, faceMLDataDB, prefs);
    await _instance!.refreshPersonCache();
  }

  Map<String, Map<String, String>> get emailToPartialPersonDataMapCache =>
      _emailToPartialPersonDataMapCache;

  void clearCache() {
    _emailToPartialPersonDataMapCache.clear();
    _cachedPersonsFuture = null;
    _lastCacheRefreshTime = 0;
  }

  Future<void> refreshPersonCache() async {
    _lastCacheRefreshTime = 0;
    // wait to ensure cache is refreshed
    final _ = await getPersons();
  }

  Future<List<PersonEntity>> getCertainPersons(List<String> ids) async {
    final entities =
        await entityService.getCertainEntities(EntityType.cgroup, ids);
    return entities
        .map(
          (e) => PersonEntity(
            e.id,
            PersonData.fromJson(json.decode(e.data)),
          ),
        )
        .toList();
  }

  int lastRemoteSyncTime() {
    return entityService.lastSyncTime(EntityType.cgroup);
  }

  Future<List<PersonEntity>> getPersons() async {
    if (_lastCacheRefreshTime != lastRemoteSyncTime()) {
      _lastCacheRefreshTime = lastRemoteSyncTime();
      _cachedPersonsFuture = null; // Invalidate cache
    }
    _cachedPersonsFuture ??= _fetchAndCachePersons();
    return _cachedPersonsFuture!;
  }

  Future<List<PersonEntity>> _fetchAndCachePersons() async {
    logger.finest("reading all persons from local db");
    final entities = await entityService.getEntities(EntityType.cgroup);
    final persons = await Computer.shared().compute(
      _decodePersonEntities,
      param: {"entity": entities},
      taskName: "decode_person_entities",
    );
    _emailToPartialPersonDataMapCache.clear();
    for (PersonEntity person in persons) {
      if (person.data.email != null && person.data.email!.isNotEmpty) {
        _emailToPartialPersonDataMapCache[person.data.email!] = {
          kPersonIDKey: person.remoteID,
          kNameKey: person.data.name,
        };
      }
    }

    return persons;
  }

  static List<PersonEntity> _decodePersonEntities(
    Map<String, dynamic> param,
  ) {
    final entities = param["entity"] as List<LocalEntityData>;
    return entities
        .map(
          (e) => PersonEntity(
            e.id,
            PersonData.fromJson(json.decode(e.data)),
          ),
        )
        .toList();
  }

  Future<PersonEntity?> getPerson(String id) {
    return entityService.getEntity(EntityType.cgroup, id).then((e) {
      if (e == null) {
        return null;
      }
      return PersonEntity(
        e.id,
        PersonData.fromJson(json.decode(e.data)),
      );
    });
  }

  Future<Map<String, PersonEntity>> getPersonsMap() async {
    final persons = await getPersons();
    final Map<String, PersonEntity> map = {};
    for (var person in persons) {
      map[person.remoteID] = person;
    }
    return map;
  }

  Future<void> reconcileClusters() async {
    final EnteWatch? w = kDebugMode ? EnteWatch("reconcileClusters") : null;
    w?.start();
    await fetchRemoteClusterFeedback(skipClusterUpdateIfNoChange: false);
    w?.log("Stored remote feedback");
    final dbPersonClusterInfo =
        await faceMLDataDB.getPersonToClusterIdToFaceIds();
    w?.log("Got DB person cluster info");
    final persons = await getPersonsMap();
    w?.log("Got persons");
    for (var personID in dbPersonClusterInfo.keys) {
      final person = persons[personID];
      if (person == null) {
        logger.severe("Person $personID not found");
        continue;
      }
      final personData = person.data;
      final Map<String, Set<String>> dbPersonCluster =
          dbPersonClusterInfo[personID]!;
      if (_shouldUpdateRemotePerson(personData, dbPersonCluster)) {
        final personData = person.data;
        personData.assigned = dbPersonCluster.entries
            .map(
              (e) => ClusterInfo(
                id: e.key,
                faces: e.value,
              ),
            )
            .toList();
        _addOrUpdateEntity(EntityType.cgroup, personData.toJson(), id: personID)
            .ignore();
        personData.logStats();
      }
    }
    w?.log("Reconciled clusters for ${persons.length} persons");
  }

  bool _shouldUpdateRemotePerson(
    PersonData personData,
    Map<String, Set<String>> dbPersonCluster,
  ) {
    if (personData.assigned.length != dbPersonCluster.length) {
      log(
        "Person ${personData.name} has ${personData.assigned.length} clusters, but ${dbPersonCluster.length} clusters found in DB",
        name: "PersonService",
      );
      return true;
    } else {
      for (ClusterInfo info in personData.assigned) {
        final dbCluster = dbPersonCluster[info.id];
        if (dbCluster == null) {
          log(
            "Cluster ${info.id} not found in DB for person ${personData.name}",
            name: "PersonService",
          );
          return true;
        }
        if (info.faces.length != dbCluster.length) {
          log(
            "Cluster ${info.id} has ${info.faces.length} faces, but ${dbCluster.length} faces found in DB",
            name: "PersonService",
          );
          return true;
        }
        for (var faceId in info.faces) {
          if (!dbCluster.contains(faceId)) {
            log(
              "Face $faceId not found in cluster ${info.id} for person ${personData.name}",
              name: "PersonService",
            );
            return true;
          }
        }
      }
    }
    return false;
  }

  Future<PersonEntity> addPerson({
    required String name,
    required String clusterID,
    bool isHidden = false,
    String? birthdate,
    String? email,
  }) async {
    final faceIds = await faceMLDataDB.getFaceIDsForCluster(clusterID);
    final data = PersonData(
      name: name,
      assigned: <ClusterInfo>[
        ClusterInfo(
          id: clusterID,
          faces: faceIds.toSet(),
        ),
      ],
      isHidden: isHidden,
      birthDate: birthdate,
      email: email,
    );
    final result = await _addOrUpdateEntity(
      EntityType.cgroup,
      data.toJson(),
    );
    await faceMLDataDB.assignClusterToPerson(
      personID: result.id,
      clusterID: clusterID,
    );
    if (data.email != null) {
      await refreshPersonCache();
    }
    memoriesCacheService.queueUpdateCache();
    return PersonEntity(result.id, data);
  }

  Future<void> removeClusterToPerson({
    required String personID,
    required String clusterID,
  }) async {
    final person = (await getPerson(personID))!;
    final personData = person.data;
    final clusterInfo = personData.assigned.firstWhere(
      (element) => element.id == clusterID,
      orElse: () => ClusterInfo(id: "noSuchClusterInRemotePerson", faces: {}),
    );
    if (clusterInfo.id == "noSuchClusterInRemotePerson") {
      await faceMLDataDB.removeClusterToPerson(
        personID: personID,
        clusterID: clusterID,
      );
      return;
    }
    personData.rejectedFaceIDs.addAll(clusterInfo.faces);
    personData.assigned.removeWhere((element) => element.id == clusterID);
    await _addOrUpdateEntity(
      EntityType.cgroup,
      personData.toJson(),
      id: personID,
    );
    await faceMLDataDB.removeClusterToPerson(
      personID: personID,
      clusterID: clusterID,
    );
    personData.logStats();
  }

  Future<void> removeFacesFromPerson({
    required PersonEntity person,
    required Set<String> faceIDs,
  }) async {
    final personData = person.data;

    // Remove faces from clusters
    final List<String> emptiedClusters = [];
    for (final cluster in personData.assigned) {
      cluster.faces.removeWhere((faceID) => faceIDs.contains(faceID));
      if (cluster.faces.isEmpty) {
        emptiedClusters.add(cluster.id);
      }
    }

    // Safety check to make sure we haven't created an empty cluster now, if so delete it
    for (final emptyClusterID in emptiedClusters) {
      personData.assigned
          .removeWhere((element) => element.id != emptyClusterID);
      await faceMLDataDB.removeClusterToPerson(
        personID: person.remoteID,
        clusterID: emptyClusterID,
      );
    }

    // Add removed faces to rejected faces
    personData.rejectedFaceIDs.addAll(faceIDs);

    await _addOrUpdateEntity(
      EntityType.cgroup,
      personData.toJson(),
      id: person.remoteID,
    );
    personData.logStats();
  }

  Future<void> deletePerson(String personID, {bool onlyMapping = false}) async {
    final entity = await getPerson(personID);
    if (onlyMapping) {
      if (entity == null) {
        return;
      }
      final PersonEntity justName =
          PersonEntity(personID, PersonData(name: entity.data.name));
      await _addOrUpdateEntity(
        EntityType.cgroup,
        justName.data.toJson(),
        id: personID,
      );
      await faceMLDataDB.removePerson(personID);
      justName.data.logStats();

      if (entity.data.email != null) {
        await refreshPersonCache();
      }
    } else {
      await entityService.deleteEntry(personID);
      await faceMLDataDB.removePerson(personID);

      if (entity != null) {
        if (entity.data.email != null) {
          await refreshPersonCache();
        }
      }
    }

    // fire PeopleChangeEvent
    Bus.instance.fire(PeopleChangedEvent());
  }

  // fetchRemoteClusterFeedback returns true if remote data has changed
  Future<bool> fetchRemoteClusterFeedback({
    bool skipClusterUpdateIfNoChange = true,
  }) async {
    final int changedEntities =
        await entityService.syncEntity(EntityType.cgroup);
    final bool changed = changedEntities > 0;
    if (changed == false && skipClusterUpdateIfNoChange) {
      return false;
    }

    final entities = await entityService.getEntities(EntityType.cgroup);
    // todo: (neerajg) perf change, this can be expensive to do on every sync
    // especially when we have a lot of people. We should only do this when the
    // last sync time is updated for cgroup entity type. To avoid partial update,
    // we need to maintain a lastSyncTime value whenever this data is processed
    // and stored in the db.
    entities.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final Map<String, String> faceIdToClusterID = {};
    final Map<String, String> clusterToPersonID = {};
    bool shouldCheckRejectedFaces = false;
    for (var e in entities) {
      final personData = PersonData.fromJson(json.decode(e.data));
      if (personData.rejectedFaceIDs.isNotEmpty) {
        shouldCheckRejectedFaces = true;
      }
      int faceCount = 0;

      // Locally store the assignment of faces to clusters and people
      for (var cluster in personData.assigned) {
        faceCount += cluster.faces.length;
        for (var faceId in cluster.faces) {
          if (faceIdToClusterID.containsKey(faceId)) {
            if (flagService.internalUser) {
              final otherPersonID =
                  clusterToPersonID[faceIdToClusterID[faceId]!];
              if (otherPersonID != e.id) {
                final otherPerson = await getPerson(otherPersonID!);
                logger.warning(
                  "Face $faceId is already assigned to person $otherPersonID (${otherPerson!.data.name}) and person ${e.id} (${personData.name})",
                );
              }
            }
          } else {
            faceIdToClusterID[faceId] = cluster.id;
          }
        }
        clusterToPersonID[cluster.id] = e.id;
      }
      if (kDebugMode) {
        logger.info(
          "Person ${e.id} ${personData.name} has ${personData.assigned.length} clusters with $faceCount faces",
        );
      }
    }
    logger.info("Storing feedback for ${faceIdToClusterID.length} faces");
    await faceMLDataDB.updateFaceIdToClusterId(faceIdToClusterID);
    await faceMLDataDB.bulkAssignClusterToPersonID(clusterToPersonID);

    if (shouldCheckRejectedFaces) {
      final dbPeopleClusterInfo =
          await faceMLDataDB.getPersonToClusterIdToFaceIds();
      for (var e in entities) {
        final personData = PersonData.fromJson(json.decode(e.data));
        if (personData.rejectedFaceIDs.isNotEmpty) {
          final personClustersToFaceIDs = dbPeopleClusterInfo[e.id];
          if (personClustersToFaceIDs == null) {
            logger.warning(
              "Person ${e.id} ${personData.name} has rejected faces but no clusters found in local DB",
            );
            continue;
          }
          final personFaceIDs =
              personClustersToFaceIDs.values.expand((e) => e).toSet();
          final rejectedFaceIDsSet = personData.rejectedFaceIDs.toSet();
          final assignedAndRejectedFaceIDs =
              rejectedFaceIDsSet.intersection(personFaceIDs);

          if (assignedAndRejectedFaceIDs.isNotEmpty) {
            // Check that we don't have any empty clusters now
            final dbPersonClusterInfo = dbPeopleClusterInfo[e.id]!;
            final faceToClusterToRemove = <String, String>{};
            for (final clusterIdToFaceIDs in dbPersonClusterInfo.entries) {
              final clusterID = clusterIdToFaceIDs.key;
              final faceIDs = clusterIdToFaceIDs.value;
              final foundRejectedFacesToCluster = <String, String>{};
              final removeFaceIDs = <String>{};
              for (final faceID in faceIDs) {
                if (assignedAndRejectedFaceIDs.contains(faceID)) {
                  removeFaceIDs.add(faceID);
                  foundRejectedFacesToCluster[faceID] = clusterID;
                }
              }
              if (faceIDs.length == removeFaceIDs.length) {
                logger.info(
                  "Cluster $clusterID for person ${e.id} ${personData.name} is empty due to rejected faces from remote, removing the cluster from person",
                );
                await faceMLDataDB.removeClusterToPerson(
                  personID: e.id,
                  clusterID: clusterID,
                );
                await faceMLDataDB.captureNotPersonFeedback(
                  personID: e.id,
                  clusterID: clusterID,
                );
              } else {
                faceToClusterToRemove.addAll(foundRejectedFacesToCluster);
              }
            }
            // Remove the clusterID for the remaining conflicting faces
            await faceMLDataDB.removeFaceIdToClusterId(faceToClusterToRemove);
          }
        }
      }
    }

    return changed;
  }

  Future<PersonEntity> updateAvatar(PersonEntity p, EnteFile file) async {
    final Face? face = await faceMLDataDB.getCoverFaceForPerson(
      recentFileID: file.uploadedFileID!,
      personID: p.remoteID,
    );
    if (face == null) {
      throw Exception(
        "No face found for person ${p.remoteID} in file ${file.uploadedFileID}",
      );
    }

    final person = (await getPerson(p.remoteID))!;
    final updatedPerson = person.copyWith(
      data: person.data.copyWith(avatarFaceId: face.faceID),
    );
    await updatePerson(updatedPerson);
    await putFaceIdCachedForPersonOrCluster(p.remoteID, face.faceID);
    return updatedPerson;
  }

  Future<PersonEntity> updateAttributes(
    String id, {
    String? name,
    String? avatarFaceId,
    bool? isHidden,
    int? version,
    String? birthDate,
    String? email,
  }) async {
    final person = (await getPerson(id))!;
    final updatedPerson = person.copyWith(
      data: person.data.copyWith(
        name: name,
        avatarFaceId: avatarFaceId,
        isHidden: isHidden,
        version: version,
        birthDate: birthDate,
        email: email,
      ),
    );
    await updatePerson(updatedPerson);
    await refreshPersonCache();
    return updatedPerson;
  }

  Future<void> updatePerson(PersonEntity updatePerson) async {
    try {
      await _addOrUpdateEntity(
        EntityType.cgroup,
        updatePerson.data.toJson(),
        id: updatePerson.remoteID,
      );
      updatePerson.data.logStats();
    } catch (e, s) {
      logger.severe("Failed to update person", e, s);
      rethrow;
    }
  }

  /// Wrapper method for entityService.addOrUpdate that handles cache refresh
  Future<LocalEntityData> _addOrUpdateEntity(
    EntityType type,
    Map<String, dynamic> jsonMap, {
    String? id,
  }) async {
    final result = await entityService.addOrUpdate(type, jsonMap, id: id);
    _lastCacheRefreshTime = 0; // Invalidate cache
    return result;
  }
}
