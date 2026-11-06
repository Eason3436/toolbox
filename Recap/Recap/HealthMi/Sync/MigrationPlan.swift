import Foundation
import SwiftData

/// 當前 Schema 版本（v1）。
/// 未來 schema 變更時新建 SchemaV2 並在 MigrationPlan 中新增遷移階段。
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [SyncState.self, StressRecord.self, SyncLogEntry.self]
    }
}

/// 遷移計劃。目前只有 v1，無遷移階段。
/// 當 schema 變更時：新建 SchemaV2 → 在 stages 中新增 `.lightweight` 或 `.custom` 遷移。
enum MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }
    static var stages: [MigrationStage] { [] }
}
