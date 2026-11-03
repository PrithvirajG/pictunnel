// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_db.dart';

// ignore_for_file: type=lint
class $ServerAssetsTable extends ServerAssets
    with TableInfo<$ServerAssetsTable, ServerAsset> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerAssetsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mimeMeta = const VerificationMeta('mime');
  @override
  late final GeneratedColumn<String> mime = GeneratedColumn<String>(
    'mime',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _filenameMeta = const VerificationMeta(
    'filename',
  );
  @override
  late final GeneratedColumn<String> filename = GeneratedColumn<String>(
    'filename',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortAtMeta = const VerificationMeta('sortAt');
  @override
  late final GeneratedColumn<DateTime> sortAt = GeneratedColumn<DateTime>(
    'sort_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _monthMeta = const VerificationMeta('month');
  @override
  late final GeneratedColumn<int> month = GeneratedColumn<int>(
    'month',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
    'width',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
    'height',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thumbnailsReadyMeta = const VerificationMeta(
    'thumbnailsReady',
  );
  @override
  late final GeneratedColumn<bool> thumbnailsReady = GeneratedColumn<bool>(
    'thumbnails_ready',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("thumbnails_ready" IN (0, 1))',
    ),
  );
  static const VerificationMeta _updatedSeqMeta = const VerificationMeta(
    'updatedSeq',
  );
  @override
  late final GeneratedColumn<int> updatedSeq = GeneratedColumn<int>(
    'updated_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _snapshotGenMeta = const VerificationMeta(
    'snapshotGen',
  );
  @override
  late final GeneratedColumn<int> snapshotGen = GeneratedColumn<int>(
    'snapshot_gen',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    sha256,
    sizeBytes,
    mime,
    kind,
    filename,
    sortAt,
    year,
    month,
    width,
    height,
    durationMs,
    state,
    thumbnailsReady,
    updatedSeq,
    snapshotGen,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'server_assets';
  @override
  VerificationContext validateIntegrity(
    Insertable<ServerAsset> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeBytesMeta);
    }
    if (data.containsKey('mime')) {
      context.handle(
        _mimeMeta,
        mime.isAcceptableOrUnknown(data['mime']!, _mimeMeta),
      );
    } else if (isInserting) {
      context.missing(_mimeMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('filename')) {
      context.handle(
        _filenameMeta,
        filename.isAcceptableOrUnknown(data['filename']!, _filenameMeta),
      );
    } else if (isInserting) {
      context.missing(_filenameMeta);
    }
    if (data.containsKey('sort_at')) {
      context.handle(
        _sortAtMeta,
        sortAt.isAcceptableOrUnknown(data['sort_at']!, _sortAtMeta),
      );
    } else if (isInserting) {
      context.missing(_sortAtMeta);
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    } else if (isInserting) {
      context.missing(_yearMeta);
    }
    if (data.containsKey('month')) {
      context.handle(
        _monthMeta,
        month.isAcceptableOrUnknown(data['month']!, _monthMeta),
      );
    } else if (isInserting) {
      context.missing(_monthMeta);
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    }
    if (data.containsKey('height')) {
      context.handle(
        _heightMeta,
        height.isAcceptableOrUnknown(data['height']!, _heightMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('thumbnails_ready')) {
      context.handle(
        _thumbnailsReadyMeta,
        thumbnailsReady.isAcceptableOrUnknown(
          data['thumbnails_ready']!,
          _thumbnailsReadyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_thumbnailsReadyMeta);
    }
    if (data.containsKey('updated_seq')) {
      context.handle(
        _updatedSeqMeta,
        updatedSeq.isAcceptableOrUnknown(data['updated_seq']!, _updatedSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedSeqMeta);
    }
    if (data.containsKey('snapshot_gen')) {
      context.handle(
        _snapshotGenMeta,
        snapshotGen.isAcceptableOrUnknown(
          data['snapshot_gen']!,
          _snapshotGenMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ServerAsset map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ServerAsset(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
      mime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mime'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      filename: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}filename'],
      )!,
      sortAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}sort_at'],
      )!,
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      )!,
      month: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}month'],
      )!,
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}width'],
      ),
      height: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}height'],
      ),
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      thumbnailsReady: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}thumbnails_ready'],
      )!,
      updatedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_seq'],
      )!,
      snapshotGen: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}snapshot_gen'],
      ),
    );
  }

  @override
  $ServerAssetsTable createAlias(String alias) {
    return $ServerAssetsTable(attachedDatabase, alias);
  }
}

class ServerAsset extends DataClass implements Insertable<ServerAsset> {
  final String id;
  final String sha256;
  final int sizeBytes;
  final String mime;
  final String kind;
  final String filename;
  final DateTime sortAt;
  final int year;
  final int month;
  final int? width;
  final int? height;
  final int? durationMs;
  final String state;
  final bool thumbnailsReady;
  final int updatedSeq;

  /// The snapshot generation that last listed this row; rows a completed
  /// snapshot did not list are removed (sync-protocol §7.6 resync).
  final int? snapshotGen;
  const ServerAsset({
    required this.id,
    required this.sha256,
    required this.sizeBytes,
    required this.mime,
    required this.kind,
    required this.filename,
    required this.sortAt,
    required this.year,
    required this.month,
    this.width,
    this.height,
    this.durationMs,
    required this.state,
    required this.thumbnailsReady,
    required this.updatedSeq,
    this.snapshotGen,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['sha256'] = Variable<String>(sha256);
    map['size_bytes'] = Variable<int>(sizeBytes);
    map['mime'] = Variable<String>(mime);
    map['kind'] = Variable<String>(kind);
    map['filename'] = Variable<String>(filename);
    map['sort_at'] = Variable<DateTime>(sortAt);
    map['year'] = Variable<int>(year);
    map['month'] = Variable<int>(month);
    if (!nullToAbsent || width != null) {
      map['width'] = Variable<int>(width);
    }
    if (!nullToAbsent || height != null) {
      map['height'] = Variable<int>(height);
    }
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    map['state'] = Variable<String>(state);
    map['thumbnails_ready'] = Variable<bool>(thumbnailsReady);
    map['updated_seq'] = Variable<int>(updatedSeq);
    if (!nullToAbsent || snapshotGen != null) {
      map['snapshot_gen'] = Variable<int>(snapshotGen);
    }
    return map;
  }

  ServerAssetsCompanion toCompanion(bool nullToAbsent) {
    return ServerAssetsCompanion(
      id: Value(id),
      sha256: Value(sha256),
      sizeBytes: Value(sizeBytes),
      mime: Value(mime),
      kind: Value(kind),
      filename: Value(filename),
      sortAt: Value(sortAt),
      year: Value(year),
      month: Value(month),
      width: width == null && nullToAbsent
          ? const Value.absent()
          : Value(width),
      height: height == null && nullToAbsent
          ? const Value.absent()
          : Value(height),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      state: Value(state),
      thumbnailsReady: Value(thumbnailsReady),
      updatedSeq: Value(updatedSeq),
      snapshotGen: snapshotGen == null && nullToAbsent
          ? const Value.absent()
          : Value(snapshotGen),
    );
  }

  factory ServerAsset.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ServerAsset(
      id: serializer.fromJson<String>(json['id']),
      sha256: serializer.fromJson<String>(json['sha256']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      mime: serializer.fromJson<String>(json['mime']),
      kind: serializer.fromJson<String>(json['kind']),
      filename: serializer.fromJson<String>(json['filename']),
      sortAt: serializer.fromJson<DateTime>(json['sortAt']),
      year: serializer.fromJson<int>(json['year']),
      month: serializer.fromJson<int>(json['month']),
      width: serializer.fromJson<int?>(json['width']),
      height: serializer.fromJson<int?>(json['height']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      state: serializer.fromJson<String>(json['state']),
      thumbnailsReady: serializer.fromJson<bool>(json['thumbnailsReady']),
      updatedSeq: serializer.fromJson<int>(json['updatedSeq']),
      snapshotGen: serializer.fromJson<int?>(json['snapshotGen']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'sha256': serializer.toJson<String>(sha256),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'mime': serializer.toJson<String>(mime),
      'kind': serializer.toJson<String>(kind),
      'filename': serializer.toJson<String>(filename),
      'sortAt': serializer.toJson<DateTime>(sortAt),
      'year': serializer.toJson<int>(year),
      'month': serializer.toJson<int>(month),
      'width': serializer.toJson<int?>(width),
      'height': serializer.toJson<int?>(height),
      'durationMs': serializer.toJson<int?>(durationMs),
      'state': serializer.toJson<String>(state),
      'thumbnailsReady': serializer.toJson<bool>(thumbnailsReady),
      'updatedSeq': serializer.toJson<int>(updatedSeq),
      'snapshotGen': serializer.toJson<int?>(snapshotGen),
    };
  }

  ServerAsset copyWith({
    String? id,
    String? sha256,
    int? sizeBytes,
    String? mime,
    String? kind,
    String? filename,
    DateTime? sortAt,
    int? year,
    int? month,
    Value<int?> width = const Value.absent(),
    Value<int?> height = const Value.absent(),
    Value<int?> durationMs = const Value.absent(),
    String? state,
    bool? thumbnailsReady,
    int? updatedSeq,
    Value<int?> snapshotGen = const Value.absent(),
  }) => ServerAsset(
    id: id ?? this.id,
    sha256: sha256 ?? this.sha256,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    mime: mime ?? this.mime,
    kind: kind ?? this.kind,
    filename: filename ?? this.filename,
    sortAt: sortAt ?? this.sortAt,
    year: year ?? this.year,
    month: month ?? this.month,
    width: width.present ? width.value : this.width,
    height: height.present ? height.value : this.height,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    state: state ?? this.state,
    thumbnailsReady: thumbnailsReady ?? this.thumbnailsReady,
    updatedSeq: updatedSeq ?? this.updatedSeq,
    snapshotGen: snapshotGen.present ? snapshotGen.value : this.snapshotGen,
  );
  ServerAsset copyWithCompanion(ServerAssetsCompanion data) {
    return ServerAsset(
      id: data.id.present ? data.id.value : this.id,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      mime: data.mime.present ? data.mime.value : this.mime,
      kind: data.kind.present ? data.kind.value : this.kind,
      filename: data.filename.present ? data.filename.value : this.filename,
      sortAt: data.sortAt.present ? data.sortAt.value : this.sortAt,
      year: data.year.present ? data.year.value : this.year,
      month: data.month.present ? data.month.value : this.month,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      state: data.state.present ? data.state.value : this.state,
      thumbnailsReady: data.thumbnailsReady.present
          ? data.thumbnailsReady.value
          : this.thumbnailsReady,
      updatedSeq: data.updatedSeq.present
          ? data.updatedSeq.value
          : this.updatedSeq,
      snapshotGen: data.snapshotGen.present
          ? data.snapshotGen.value
          : this.snapshotGen,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ServerAsset(')
          ..write('id: $id, ')
          ..write('sha256: $sha256, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('mime: $mime, ')
          ..write('kind: $kind, ')
          ..write('filename: $filename, ')
          ..write('sortAt: $sortAt, ')
          ..write('year: $year, ')
          ..write('month: $month, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('durationMs: $durationMs, ')
          ..write('state: $state, ')
          ..write('thumbnailsReady: $thumbnailsReady, ')
          ..write('updatedSeq: $updatedSeq, ')
          ..write('snapshotGen: $snapshotGen')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    sha256,
    sizeBytes,
    mime,
    kind,
    filename,
    sortAt,
    year,
    month,
    width,
    height,
    durationMs,
    state,
    thumbnailsReady,
    updatedSeq,
    snapshotGen,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ServerAsset &&
          other.id == this.id &&
          other.sha256 == this.sha256 &&
          other.sizeBytes == this.sizeBytes &&
          other.mime == this.mime &&
          other.kind == this.kind &&
          other.filename == this.filename &&
          other.sortAt == this.sortAt &&
          other.year == this.year &&
          other.month == this.month &&
          other.width == this.width &&
          other.height == this.height &&
          other.durationMs == this.durationMs &&
          other.state == this.state &&
          other.thumbnailsReady == this.thumbnailsReady &&
          other.updatedSeq == this.updatedSeq &&
          other.snapshotGen == this.snapshotGen);
}

class ServerAssetsCompanion extends UpdateCompanion<ServerAsset> {
  final Value<String> id;
  final Value<String> sha256;
  final Value<int> sizeBytes;
  final Value<String> mime;
  final Value<String> kind;
  final Value<String> filename;
  final Value<DateTime> sortAt;
  final Value<int> year;
  final Value<int> month;
  final Value<int?> width;
  final Value<int?> height;
  final Value<int?> durationMs;
  final Value<String> state;
  final Value<bool> thumbnailsReady;
  final Value<int> updatedSeq;
  final Value<int?> snapshotGen;
  final Value<int> rowid;
  const ServerAssetsCompanion({
    this.id = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.mime = const Value.absent(),
    this.kind = const Value.absent(),
    this.filename = const Value.absent(),
    this.sortAt = const Value.absent(),
    this.year = const Value.absent(),
    this.month = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.state = const Value.absent(),
    this.thumbnailsReady = const Value.absent(),
    this.updatedSeq = const Value.absent(),
    this.snapshotGen = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ServerAssetsCompanion.insert({
    required String id,
    required String sha256,
    required int sizeBytes,
    required String mime,
    required String kind,
    required String filename,
    required DateTime sortAt,
    required int year,
    required int month,
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.durationMs = const Value.absent(),
    required String state,
    required bool thumbnailsReady,
    required int updatedSeq,
    this.snapshotGen = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       sha256 = Value(sha256),
       sizeBytes = Value(sizeBytes),
       mime = Value(mime),
       kind = Value(kind),
       filename = Value(filename),
       sortAt = Value(sortAt),
       year = Value(year),
       month = Value(month),
       state = Value(state),
       thumbnailsReady = Value(thumbnailsReady),
       updatedSeq = Value(updatedSeq);
  static Insertable<ServerAsset> custom({
    Expression<String>? id,
    Expression<String>? sha256,
    Expression<int>? sizeBytes,
    Expression<String>? mime,
    Expression<String>? kind,
    Expression<String>? filename,
    Expression<DateTime>? sortAt,
    Expression<int>? year,
    Expression<int>? month,
    Expression<int>? width,
    Expression<int>? height,
    Expression<int>? durationMs,
    Expression<String>? state,
    Expression<bool>? thumbnailsReady,
    Expression<int>? updatedSeq,
    Expression<int>? snapshotGen,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sha256 != null) 'sha256': sha256,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (mime != null) 'mime': mime,
      if (kind != null) 'kind': kind,
      if (filename != null) 'filename': filename,
      if (sortAt != null) 'sort_at': sortAt,
      if (year != null) 'year': year,
      if (month != null) 'month': month,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (durationMs != null) 'duration_ms': durationMs,
      if (state != null) 'state': state,
      if (thumbnailsReady != null) 'thumbnails_ready': thumbnailsReady,
      if (updatedSeq != null) 'updated_seq': updatedSeq,
      if (snapshotGen != null) 'snapshot_gen': snapshotGen,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ServerAssetsCompanion copyWith({
    Value<String>? id,
    Value<String>? sha256,
    Value<int>? sizeBytes,
    Value<String>? mime,
    Value<String>? kind,
    Value<String>? filename,
    Value<DateTime>? sortAt,
    Value<int>? year,
    Value<int>? month,
    Value<int?>? width,
    Value<int?>? height,
    Value<int?>? durationMs,
    Value<String>? state,
    Value<bool>? thumbnailsReady,
    Value<int>? updatedSeq,
    Value<int?>? snapshotGen,
    Value<int>? rowid,
  }) {
    return ServerAssetsCompanion(
      id: id ?? this.id,
      sha256: sha256 ?? this.sha256,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      mime: mime ?? this.mime,
      kind: kind ?? this.kind,
      filename: filename ?? this.filename,
      sortAt: sortAt ?? this.sortAt,
      year: year ?? this.year,
      month: month ?? this.month,
      width: width ?? this.width,
      height: height ?? this.height,
      durationMs: durationMs ?? this.durationMs,
      state: state ?? this.state,
      thumbnailsReady: thumbnailsReady ?? this.thumbnailsReady,
      updatedSeq: updatedSeq ?? this.updatedSeq,
      snapshotGen: snapshotGen ?? this.snapshotGen,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (mime.present) {
      map['mime'] = Variable<String>(mime.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (filename.present) {
      map['filename'] = Variable<String>(filename.value);
    }
    if (sortAt.present) {
      map['sort_at'] = Variable<DateTime>(sortAt.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (month.present) {
      map['month'] = Variable<int>(month.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (thumbnailsReady.present) {
      map['thumbnails_ready'] = Variable<bool>(thumbnailsReady.value);
    }
    if (updatedSeq.present) {
      map['updated_seq'] = Variable<int>(updatedSeq.value);
    }
    if (snapshotGen.present) {
      map['snapshot_gen'] = Variable<int>(snapshotGen.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ServerAssetsCompanion(')
          ..write('id: $id, ')
          ..write('sha256: $sha256, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('mime: $mime, ')
          ..write('kind: $kind, ')
          ..write('filename: $filename, ')
          ..write('sortAt: $sortAt, ')
          ..write('year: $year, ')
          ..write('month: $month, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('durationMs: $durationMs, ')
          ..write('state: $state, ')
          ..write('thumbnailsReady: $thumbnailsReady, ')
          ..write('updatedSeq: $updatedSeq, ')
          ..write('snapshotGen: $snapshotGen, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncMetaTable extends SyncMeta
    with TableInfo<$SyncMetaTable, SyncMetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncMetaData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SyncMetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncMetaData(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $SyncMetaTable createAlias(String alias) {
    return $SyncMetaTable(attachedDatabase, alias);
  }
}

class SyncMetaData extends DataClass implements Insertable<SyncMetaData> {
  final String key;
  final String value;
  const SyncMetaData({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SyncMetaCompanion toCompanion(bool nullToAbsent) {
    return SyncMetaCompanion(key: Value(key), value: Value(value));
  }

  factory SyncMetaData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncMetaData(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  SyncMetaData copyWith({String? key, String? value}) =>
      SyncMetaData(key: key ?? this.key, value: value ?? this.value);
  SyncMetaData copyWithCompanion(SyncMetaCompanion data) {
    return SyncMetaData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetaData(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncMetaData &&
          other.key == this.key &&
          other.value == this.value);
}

class SyncMetaCompanion extends UpdateCompanion<SyncMetaData> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SyncMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncMetaCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<SyncMetaData> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncMetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return SyncMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ThumbEntriesTable extends ThumbEntries
    with TableInfo<$ThumbEntriesTable, ThumbEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ThumbEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _assetIdMeta = const VerificationMeta(
    'assetId',
  );
  @override
  late final GeneratedColumn<String> assetId = GeneratedColumn<String>(
    'asset_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<String> size = GeneratedColumn<String>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<int> bytes = GeneratedColumn<int>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastUsedAtMeta = const VerificationMeta(
    'lastUsedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastUsedAt = GeneratedColumn<DateTime>(
    'last_used_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    assetId,
    size,
    path,
    bytes,
    lastUsedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'thumb_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<ThumbEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('asset_id')) {
      context.handle(
        _assetIdMeta,
        assetId.isAcceptableOrUnknown(data['asset_id']!, _assetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_assetIdMeta);
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('last_used_at')) {
      context.handle(
        _lastUsedAtMeta,
        lastUsedAt.isAcceptableOrUnknown(
          data['last_used_at']!,
          _lastUsedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastUsedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {assetId, size};
  @override
  ThumbEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ThumbEntry(
      assetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}asset_id'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}size'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes'],
      )!,
      lastUsedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_used_at'],
      )!,
    );
  }

  @override
  $ThumbEntriesTable createAlias(String alias) {
    return $ThumbEntriesTable(attachedDatabase, alias);
  }
}

class ThumbEntry extends DataClass implements Insertable<ThumbEntry> {
  final String assetId;
  final String size;
  final String path;
  final int bytes;
  final DateTime lastUsedAt;
  const ThumbEntry({
    required this.assetId,
    required this.size,
    required this.path,
    required this.bytes,
    required this.lastUsedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['asset_id'] = Variable<String>(assetId);
    map['size'] = Variable<String>(size);
    map['path'] = Variable<String>(path);
    map['bytes'] = Variable<int>(bytes);
    map['last_used_at'] = Variable<DateTime>(lastUsedAt);
    return map;
  }

  ThumbEntriesCompanion toCompanion(bool nullToAbsent) {
    return ThumbEntriesCompanion(
      assetId: Value(assetId),
      size: Value(size),
      path: Value(path),
      bytes: Value(bytes),
      lastUsedAt: Value(lastUsedAt),
    );
  }

  factory ThumbEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ThumbEntry(
      assetId: serializer.fromJson<String>(json['assetId']),
      size: serializer.fromJson<String>(json['size']),
      path: serializer.fromJson<String>(json['path']),
      bytes: serializer.fromJson<int>(json['bytes']),
      lastUsedAt: serializer.fromJson<DateTime>(json['lastUsedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'assetId': serializer.toJson<String>(assetId),
      'size': serializer.toJson<String>(size),
      'path': serializer.toJson<String>(path),
      'bytes': serializer.toJson<int>(bytes),
      'lastUsedAt': serializer.toJson<DateTime>(lastUsedAt),
    };
  }

  ThumbEntry copyWith({
    String? assetId,
    String? size,
    String? path,
    int? bytes,
    DateTime? lastUsedAt,
  }) => ThumbEntry(
    assetId: assetId ?? this.assetId,
    size: size ?? this.size,
    path: path ?? this.path,
    bytes: bytes ?? this.bytes,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );
  ThumbEntry copyWithCompanion(ThumbEntriesCompanion data) {
    return ThumbEntry(
      assetId: data.assetId.present ? data.assetId.value : this.assetId,
      size: data.size.present ? data.size.value : this.size,
      path: data.path.present ? data.path.value : this.path,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      lastUsedAt: data.lastUsedAt.present
          ? data.lastUsedAt.value
          : this.lastUsedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ThumbEntry(')
          ..write('assetId: $assetId, ')
          ..write('size: $size, ')
          ..write('path: $path, ')
          ..write('bytes: $bytes, ')
          ..write('lastUsedAt: $lastUsedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(assetId, size, path, bytes, lastUsedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ThumbEntry &&
          other.assetId == this.assetId &&
          other.size == this.size &&
          other.path == this.path &&
          other.bytes == this.bytes &&
          other.lastUsedAt == this.lastUsedAt);
}

class ThumbEntriesCompanion extends UpdateCompanion<ThumbEntry> {
  final Value<String> assetId;
  final Value<String> size;
  final Value<String> path;
  final Value<int> bytes;
  final Value<DateTime> lastUsedAt;
  final Value<int> rowid;
  const ThumbEntriesCompanion({
    this.assetId = const Value.absent(),
    this.size = const Value.absent(),
    this.path = const Value.absent(),
    this.bytes = const Value.absent(),
    this.lastUsedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ThumbEntriesCompanion.insert({
    required String assetId,
    required String size,
    required String path,
    required int bytes,
    required DateTime lastUsedAt,
    this.rowid = const Value.absent(),
  }) : assetId = Value(assetId),
       size = Value(size),
       path = Value(path),
       bytes = Value(bytes),
       lastUsedAt = Value(lastUsedAt);
  static Insertable<ThumbEntry> custom({
    Expression<String>? assetId,
    Expression<String>? size,
    Expression<String>? path,
    Expression<int>? bytes,
    Expression<DateTime>? lastUsedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (assetId != null) 'asset_id': assetId,
      if (size != null) 'size': size,
      if (path != null) 'path': path,
      if (bytes != null) 'bytes': bytes,
      if (lastUsedAt != null) 'last_used_at': lastUsedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ThumbEntriesCompanion copyWith({
    Value<String>? assetId,
    Value<String>? size,
    Value<String>? path,
    Value<int>? bytes,
    Value<DateTime>? lastUsedAt,
    Value<int>? rowid,
  }) {
    return ThumbEntriesCompanion(
      assetId: assetId ?? this.assetId,
      size: size ?? this.size,
      path: path ?? this.path,
      bytes: bytes ?? this.bytes,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (assetId.present) {
      map['asset_id'] = Variable<String>(assetId.value);
    }
    if (size.present) {
      map['size'] = Variable<String>(size.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<int>(bytes.value);
    }
    if (lastUsedAt.present) {
      map['last_used_at'] = Variable<DateTime>(lastUsedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ThumbEntriesCompanion(')
          ..write('assetId: $assetId, ')
          ..write('size: $size, ')
          ..write('path: $path, ')
          ..write('bytes: $bytes, ')
          ..write('lastUsedAt: $lastUsedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDb extends GeneratedDatabase {
  _$AppDb(QueryExecutor e) : super(e);
  $AppDbManager get managers => $AppDbManager(this);
  late final $ServerAssetsTable serverAssets = $ServerAssetsTable(this);
  late final $SyncMetaTable syncMeta = $SyncMetaTable(this);
  late final $ThumbEntriesTable thumbEntries = $ThumbEntriesTable(this);
  late final Index serverAssetsSortAt = Index(
    'server_assets_sort_at',
    'CREATE INDEX server_assets_sort_at ON server_assets (sort_at)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    serverAssets,
    syncMeta,
    thumbEntries,
    serverAssetsSortAt,
  ];
}

typedef $$ServerAssetsTableCreateCompanionBuilder =
    ServerAssetsCompanion Function({
      required String id,
      required String sha256,
      required int sizeBytes,
      required String mime,
      required String kind,
      required String filename,
      required DateTime sortAt,
      required int year,
      required int month,
      Value<int?> width,
      Value<int?> height,
      Value<int?> durationMs,
      required String state,
      required bool thumbnailsReady,
      required int updatedSeq,
      Value<int?> snapshotGen,
      Value<int> rowid,
    });
typedef $$ServerAssetsTableUpdateCompanionBuilder =
    ServerAssetsCompanion Function({
      Value<String> id,
      Value<String> sha256,
      Value<int> sizeBytes,
      Value<String> mime,
      Value<String> kind,
      Value<String> filename,
      Value<DateTime> sortAt,
      Value<int> year,
      Value<int> month,
      Value<int?> width,
      Value<int?> height,
      Value<int?> durationMs,
      Value<String> state,
      Value<bool> thumbnailsReady,
      Value<int> updatedSeq,
      Value<int?> snapshotGen,
      Value<int> rowid,
    });

class $$ServerAssetsTableFilterComposer
    extends Composer<_$AppDb, $ServerAssetsTable> {
  $$ServerAssetsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mime => $composableBuilder(
    column: $table.mime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get filename => $composableBuilder(
    column: $table.filename,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get sortAt => $composableBuilder(
    column: $table.sortAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get month => $composableBuilder(
    column: $table.month,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get thumbnailsReady => $composableBuilder(
    column: $table.thumbnailsReady,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedSeq => $composableBuilder(
    column: $table.updatedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get snapshotGen => $composableBuilder(
    column: $table.snapshotGen,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ServerAssetsTableOrderingComposer
    extends Composer<_$AppDb, $ServerAssetsTable> {
  $$ServerAssetsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mime => $composableBuilder(
    column: $table.mime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get filename => $composableBuilder(
    column: $table.filename,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get sortAt => $composableBuilder(
    column: $table.sortAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get month => $composableBuilder(
    column: $table.month,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get thumbnailsReady => $composableBuilder(
    column: $table.thumbnailsReady,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedSeq => $composableBuilder(
    column: $table.updatedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get snapshotGen => $composableBuilder(
    column: $table.snapshotGen,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ServerAssetsTableAnnotationComposer
    extends Composer<_$AppDb, $ServerAssetsTable> {
  $$ServerAssetsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<String> get mime =>
      $composableBuilder(column: $table.mime, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get filename =>
      $composableBuilder(column: $table.filename, builder: (column) => column);

  GeneratedColumn<DateTime> get sortAt =>
      $composableBuilder(column: $table.sortAt, builder: (column) => column);

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<int> get month =>
      $composableBuilder(column: $table.month, builder: (column) => column);

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<bool> get thumbnailsReady => $composableBuilder(
    column: $table.thumbnailsReady,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedSeq => $composableBuilder(
    column: $table.updatedSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get snapshotGen => $composableBuilder(
    column: $table.snapshotGen,
    builder: (column) => column,
  );
}

class $$ServerAssetsTableTableManager
    extends
        RootTableManager<
          _$AppDb,
          $ServerAssetsTable,
          ServerAsset,
          $$ServerAssetsTableFilterComposer,
          $$ServerAssetsTableOrderingComposer,
          $$ServerAssetsTableAnnotationComposer,
          $$ServerAssetsTableCreateCompanionBuilder,
          $$ServerAssetsTableUpdateCompanionBuilder,
          (
            ServerAsset,
            BaseReferences<_$AppDb, $ServerAssetsTable, ServerAsset>,
          ),
          ServerAsset,
          PrefetchHooks Function()
        > {
  $$ServerAssetsTableTableManager(_$AppDb db, $ServerAssetsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerAssetsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerAssetsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerAssetsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<String> mime = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> filename = const Value.absent(),
                Value<DateTime> sortAt = const Value.absent(),
                Value<int> year = const Value.absent(),
                Value<int> month = const Value.absent(),
                Value<int?> width = const Value.absent(),
                Value<int?> height = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<bool> thumbnailsReady = const Value.absent(),
                Value<int> updatedSeq = const Value.absent(),
                Value<int?> snapshotGen = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ServerAssetsCompanion(
                id: id,
                sha256: sha256,
                sizeBytes: sizeBytes,
                mime: mime,
                kind: kind,
                filename: filename,
                sortAt: sortAt,
                year: year,
                month: month,
                width: width,
                height: height,
                durationMs: durationMs,
                state: state,
                thumbnailsReady: thumbnailsReady,
                updatedSeq: updatedSeq,
                snapshotGen: snapshotGen,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String sha256,
                required int sizeBytes,
                required String mime,
                required String kind,
                required String filename,
                required DateTime sortAt,
                required int year,
                required int month,
                Value<int?> width = const Value.absent(),
                Value<int?> height = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                required String state,
                required bool thumbnailsReady,
                required int updatedSeq,
                Value<int?> snapshotGen = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ServerAssetsCompanion.insert(
                id: id,
                sha256: sha256,
                sizeBytes: sizeBytes,
                mime: mime,
                kind: kind,
                filename: filename,
                sortAt: sortAt,
                year: year,
                month: month,
                width: width,
                height: height,
                durationMs: durationMs,
                state: state,
                thumbnailsReady: thumbnailsReady,
                updatedSeq: updatedSeq,
                snapshotGen: snapshotGen,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ServerAssetsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDb,
      $ServerAssetsTable,
      ServerAsset,
      $$ServerAssetsTableFilterComposer,
      $$ServerAssetsTableOrderingComposer,
      $$ServerAssetsTableAnnotationComposer,
      $$ServerAssetsTableCreateCompanionBuilder,
      $$ServerAssetsTableUpdateCompanionBuilder,
      (ServerAsset, BaseReferences<_$AppDb, $ServerAssetsTable, ServerAsset>),
      ServerAsset,
      PrefetchHooks Function()
    >;
typedef $$SyncMetaTableCreateCompanionBuilder =
    SyncMetaCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$SyncMetaTableUpdateCompanionBuilder =
    SyncMetaCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$SyncMetaTableFilterComposer extends Composer<_$AppDb, $SyncMetaTable> {
  $$SyncMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncMetaTableOrderingComposer
    extends Composer<_$AppDb, $SyncMetaTable> {
  $$SyncMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncMetaTableAnnotationComposer
    extends Composer<_$AppDb, $SyncMetaTable> {
  $$SyncMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SyncMetaTableTableManager
    extends
        RootTableManager<
          _$AppDb,
          $SyncMetaTable,
          SyncMetaData,
          $$SyncMetaTableFilterComposer,
          $$SyncMetaTableOrderingComposer,
          $$SyncMetaTableAnnotationComposer,
          $$SyncMetaTableCreateCompanionBuilder,
          $$SyncMetaTableUpdateCompanionBuilder,
          (SyncMetaData, BaseReferences<_$AppDb, $SyncMetaTable, SyncMetaData>),
          SyncMetaData,
          PrefetchHooks Function()
        > {
  $$SyncMetaTableTableManager(_$AppDb db, $SyncMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncMetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => SyncMetaCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDb,
      $SyncMetaTable,
      SyncMetaData,
      $$SyncMetaTableFilterComposer,
      $$SyncMetaTableOrderingComposer,
      $$SyncMetaTableAnnotationComposer,
      $$SyncMetaTableCreateCompanionBuilder,
      $$SyncMetaTableUpdateCompanionBuilder,
      (SyncMetaData, BaseReferences<_$AppDb, $SyncMetaTable, SyncMetaData>),
      SyncMetaData,
      PrefetchHooks Function()
    >;
typedef $$ThumbEntriesTableCreateCompanionBuilder =
    ThumbEntriesCompanion Function({
      required String assetId,
      required String size,
      required String path,
      required int bytes,
      required DateTime lastUsedAt,
      Value<int> rowid,
    });
typedef $$ThumbEntriesTableUpdateCompanionBuilder =
    ThumbEntriesCompanion Function({
      Value<String> assetId,
      Value<String> size,
      Value<String> path,
      Value<int> bytes,
      Value<DateTime> lastUsedAt,
      Value<int> rowid,
    });

class $$ThumbEntriesTableFilterComposer
    extends Composer<_$AppDb, $ThumbEntriesTable> {
  $$ThumbEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ThumbEntriesTableOrderingComposer
    extends Composer<_$AppDb, $ThumbEntriesTable> {
  $$ThumbEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ThumbEntriesTableAnnotationComposer
    extends Composer<_$AppDb, $ThumbEntriesTable> {
  $$ThumbEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get assetId =>
      $composableBuilder(column: $table.assetId, builder: (column) => column);

  GeneratedColumn<String> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<DateTime> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => column,
  );
}

class $$ThumbEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDb,
          $ThumbEntriesTable,
          ThumbEntry,
          $$ThumbEntriesTableFilterComposer,
          $$ThumbEntriesTableOrderingComposer,
          $$ThumbEntriesTableAnnotationComposer,
          $$ThumbEntriesTableCreateCompanionBuilder,
          $$ThumbEntriesTableUpdateCompanionBuilder,
          (ThumbEntry, BaseReferences<_$AppDb, $ThumbEntriesTable, ThumbEntry>),
          ThumbEntry,
          PrefetchHooks Function()
        > {
  $$ThumbEntriesTableTableManager(_$AppDb db, $ThumbEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ThumbEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ThumbEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ThumbEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> assetId = const Value.absent(),
                Value<String> size = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<int> bytes = const Value.absent(),
                Value<DateTime> lastUsedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ThumbEntriesCompanion(
                assetId: assetId,
                size: size,
                path: path,
                bytes: bytes,
                lastUsedAt: lastUsedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String assetId,
                required String size,
                required String path,
                required int bytes,
                required DateTime lastUsedAt,
                Value<int> rowid = const Value.absent(),
              }) => ThumbEntriesCompanion.insert(
                assetId: assetId,
                size: size,
                path: path,
                bytes: bytes,
                lastUsedAt: lastUsedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ThumbEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDb,
      $ThumbEntriesTable,
      ThumbEntry,
      $$ThumbEntriesTableFilterComposer,
      $$ThumbEntriesTableOrderingComposer,
      $$ThumbEntriesTableAnnotationComposer,
      $$ThumbEntriesTableCreateCompanionBuilder,
      $$ThumbEntriesTableUpdateCompanionBuilder,
      (ThumbEntry, BaseReferences<_$AppDb, $ThumbEntriesTable, ThumbEntry>),
      ThumbEntry,
      PrefetchHooks Function()
    >;

class $AppDbManager {
  final _$AppDb _db;
  $AppDbManager(this._db);
  $$ServerAssetsTableTableManager get serverAssets =>
      $$ServerAssetsTableTableManager(_db, _db.serverAssets);
  $$SyncMetaTableTableManager get syncMeta =>
      $$SyncMetaTableTableManager(_db, _db.syncMeta);
  $$ThumbEntriesTableTableManager get thumbEntries =>
      $$ThumbEntriesTableTableManager(_db, _db.thumbEntries);
}
