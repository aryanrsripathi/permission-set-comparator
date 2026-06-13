/**
 * PermissionSetComparatorController
 * Compares object permissions, field permissions, apex class access,
 * and system permissions across 2+ permission sets.
 *
 * Key design decisions:
 * - EntityDefinition / FieldDefinition: uses Database.queryWithBinds + OFFSET pagination
 *   to avoid queryMore() restriction (max 200 rows per batch on metadata objects)
 * - No Schema.getGlobalDescribe() loops (CPU limit risk on large orgs)
 * - Schema.describeSObjects() used only in small targeted batches for label resolution
 * - All @AuraEnabled methods are cacheable=true where safe, non-cacheable where DML/state needed
 */
public with sharing class PermissionSetComparatorController {

    // =========================================================================
    // INNER CLASSES — Comparators first so all methods can reference them
    // =========================================================================

    private class LabelComparator implements Comparator<ObjectInfo> {
        public Integer compare(ObjectInfo a, ObjectInfo b) {
            return a.label.compareTo(b.label);
        }
    }
    private class ObjRowComparator implements Comparator<ObjPermRow> {
        public Integer compare(ObjPermRow a, ObjPermRow b) {
            return a.objectLabel.compareTo(b.objectLabel);
        }
    }
    private class FieldRowComparator implements Comparator<FieldPermRow> {
        public Integer compare(FieldPermRow a, FieldPermRow b) {
            return a.fieldLabel.compareTo(b.fieldLabel);
        }
    }

    // =========================================================================
    // RESULT WRAPPERS
    // =========================================================================

    public class PermSetInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String label;
    }

    public class ObjectInfo {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
    }

    public class ObjPermRow {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public List<ObjPermCell> cells;
    }

    public class ObjPermCell {
        @AuraEnabled public String permSetId;
        @AuraEnabled public Boolean canRead;
        @AuraEnabled public Boolean canCreate;
        @AuraEnabled public Boolean canEdit;
        @AuraEnabled public Boolean canDelete;
        @AuraEnabled public Boolean canViewAll;
        @AuraEnabled public Boolean canModifyAll;
    }

    public class FieldPermRow {
        @AuraEnabled public String fieldApiName;
        @AuraEnabled public String fieldLabel;
        @AuraEnabled public List<FieldPermCell> cells;
    }

    public class FieldPermCell {
        @AuraEnabled public String permSetId;
        @AuraEnabled public Boolean canRead;
        @AuraEnabled public Boolean canEdit;
    }

    public class BoolCell {
        @AuraEnabled public String psId;
        @AuraEnabled public Boolean enabled;
    }

    public class ApexRow {
        @AuraEnabled public String className;
        @AuraEnabled public List<BoolCell> access;
    }

    public class SysPermRow {
        @AuraEnabled public String permApiName;
        @AuraEnabled public String permLabel;
        @AuraEnabled public List<BoolCell> values;
    }

    public class CompareResult {
        @AuraEnabled public List<String>    permSetIds;
        @AuraEnabled public List<String>    permSetLabels;
        @AuraEnabled public List<ObjPermRow> objectPerms;
        @AuraEnabled public List<ApexRow>   apexAccess;
        @AuraEnabled public List<SysPermRow> sysPerms;
    }

    // =========================================================================
    // PUBLIC API — called from LWC
    // =========================================================================

    /**
     * Returns all permission sets that are NOT owned by a profile.
     * Cacheable — pure query, no side effects.
     */
    @AuraEnabled(cacheable=true)
    public static List<PermSetInfo> getPermissionSets() {
        List<PermSetInfo> result = new List<PermSetInfo>();
        for (PermissionSet ps : [
            SELECT Id, Name, Label
            FROM PermissionSet
            WHERE IsOwnedByProfile = false
            ORDER BY Label ASC
            LIMIT 500
        ]) {
            PermSetInfo p = new PermSetInfo();
            p.id    = ps.Id;
            p.name  = ps.Name;
            p.label = ps.Label;
            result.add(p);
        }
        return result;
    }

    /**
     * Returns all queryable, non-deprecated objects in the org.
     * Uses two EntityDefinition queries (IsCustomizable true/false) each
     * capped at 200 to avoid the queryMore() restriction on metadata objects.
     * Cacheable — pure query.
     */
    @AuraEnabled(cacheable=true)
    public static List<ObjectInfo> getOrgObjects() {
        Map<String, ObjectInfo> seen = new Map<String, ObjectInfo>();

        // EntityDefinition does NOT support queryMore() so we cannot use LIMIT > 200.
        // We page through using OFFSET in batches of 200 for BOTH standard and custom
        // objects separately. This handles orgs with 1000+ objects including all
        // managed package objects like SIM_Ticket__c, SBQQ__Quote__c etc.

        // ── Standard objects ──────────────────────────────────────────────
        Map<String, Object> stdBinds = new Map<String, Object>{ 'customizable' => false };
        String stdQuery =
            'SELECT QualifiedApiName, Label FROM EntityDefinition ' +
            'WHERE IsQueryable = true AND IsDeprecatedAndHidden = false ' +
            'AND IsCustomizable = :customizable ' +
            'ORDER BY Label ASC LIMIT 200 OFFSET ';

        for (Integer offset = 0; offset <= 1800; offset += 200) {
            List<EntityDefinition> page = Database.queryWithBinds(
                stdQuery + offset, stdBinds, AccessLevel.USER_MODE
            );
            if (page.isEmpty()) break;
            for (EntityDefinition ed : page) {
                if (!seen.containsKey(ed.QualifiedApiName)) {
                    seen.put(ed.QualifiedApiName, makeObjectInfo(ed.QualifiedApiName, ed.Label));
                }
            }
        }

        // ── Custom objects (includes __c, managed packages, platform events, etc.) ──
        Map<String, Object> custBinds = new Map<String, Object>{ 'customizable' => true };
        String custQuery =
            'SELECT QualifiedApiName, Label FROM EntityDefinition ' +
            'WHERE IsQueryable = true AND IsDeprecatedAndHidden = false ' +
            'AND IsCustomizable = :customizable ' +
            'ORDER BY Label ASC LIMIT 200 OFFSET ';

        for (Integer offset = 0; offset <= 1800; offset += 200) {
            List<EntityDefinition> page = Database.queryWithBinds(
                custQuery + offset, custBinds, AccessLevel.USER_MODE
            );
            if (page.isEmpty()) break;
            for (EntityDefinition ed : page) {
                if (!seen.containsKey(ed.QualifiedApiName)) {
                    seen.put(ed.QualifiedApiName, makeObjectInfo(ed.QualifiedApiName, ed.Label));
                }
            }
        }

        List<ObjectInfo> result = seen.values();
        result.sort(new LabelComparator());
        return result;
    }

    /**
     * Main comparison entry point.
     * Returns object perms, apex access, and system perms for the selected perm sets.
     * Field perms are loaded separately on-demand via getFieldPerms().
     * NOT cacheable — depends on runtime parameters.
     */
    @AuraEnabled
    public static CompareResult comparePermSets(
        List<String> permSetIds,
        List<String> filterObjects
    ) {
        if (permSetIds == null || permSetIds.size() < 2) {
            throw new AuraHandledException('Select at least 2 permission sets.');
        }

        CompareResult result = new CompareResult();
        result.permSetIds    = permSetIds;
        result.permSetLabels = resolvePermSetLabels(permSetIds);
        result.objectPerms   = buildObjectPerms(permSetIds, filterObjects);
        result.apexAccess    = buildApexAccess(permSetIds);
        result.sysPerms      = buildSysPerms(permSetIds);
        return result;
    }

    /**
     * Loads field-level permissions for ONE object on demand.
     * Loads all fields first (via FieldDefinition OFFSET pagination),
     * then overlays actual FieldPermissions records.
     * NOT cacheable — depends on runtime permSetIds.
     */
    @AuraEnabled
    public static List<FieldPermRow> getFieldPerms(
        List<String> permSetIds,
        String objectApiName
    ) {
        // Step 1 — build a row for every field on this object
        Map<String, FieldPermRow> rowMap = new Map<String, FieldPermRow>();
        Map<String, Object> binds = new Map<String, Object>{ 'obj' => objectApiName };
        String baseQuery =
            'SELECT QualifiedApiName, Label FROM FieldDefinition ' +
            'WHERE EntityDefinition.QualifiedApiName = :obj ' +
            'ORDER BY Label ASC LIMIT 200 OFFSET ';

        for (Integer offset = 0; offset <= 600; offset += 200) {
            List<FieldDefinition> page = Database.queryWithBinds(
                baseQuery + offset, binds, AccessLevel.USER_MODE
            );
            if (page.isEmpty()) break;
            for (FieldDefinition fd : page) {
                String key = (objectApiName + '.' + fd.QualifiedApiName).toLowerCase();
                if (!rowMap.containsKey(key)) {
                    FieldPermRow row = new FieldPermRow();
                    row.fieldApiName = objectApiName + '.' + fd.QualifiedApiName;
                    row.fieldLabel   = fd.Label;
                    row.cells        = initFieldCells(permSetIds);
                    rowMap.put(key, row);
                }
            }
        }

        // Step 2 — overlay actual permission values
        for (FieldPermissions fp : [
            SELECT ParentId, Field, PermissionsRead, PermissionsEdit
            FROM FieldPermissions
            WHERE ParentId   IN :permSetIds
              AND SObjectType = :objectApiName
        ]) {
            String key = fp.Field.toLowerCase();
            if (rowMap.containsKey(key)) {
                Integer idx = permSetIds.indexOf(fp.ParentId);
                if (idx >= 0) {
                    rowMap.get(key).cells[idx].canRead = fp.PermissionsRead;
                    rowMap.get(key).cells[idx].canEdit = fp.PermissionsEdit;
                }
            }
        }

        List<FieldPermRow> rows = rowMap.values();
        rows.sort(new FieldRowComparator());
        return rows;
    }

    // =========================================================================
    // PRIVATE HELPERS
    // =========================================================================

    private static ObjectInfo makeObjectInfo(String apiName, String lbl) {
        ObjectInfo i = new ObjectInfo();
        i.apiName = apiName;
        i.label   = lbl;
        return i;
    }

    private static List<String> resolvePermSetLabels(List<String> permSetIds) {
        Map<Id, PermissionSet> psMap = new Map<Id, PermissionSet>(
            [SELECT Id, Label FROM PermissionSet WHERE Id IN :permSetIds]
        );
        List<String> labels = new List<String>();
        for (String psId : permSetIds) {
            labels.add(psMap.containsKey(psId) ? psMap.get(psId).Label : psId);
        }
        return labels;
    }

    private static List<FieldPermCell> initFieldCells(List<String> permSetIds) {
        List<FieldPermCell> cells = new List<FieldPermCell>();
        for (String psId : permSetIds) {
            FieldPermCell c = new FieldPermCell();
            c.permSetId = psId;
            c.canRead   = false;
            c.canEdit   = false;
            cells.add(c);
        }
        return cells;
    }

    private static List<BoolCell> initBoolCells(List<String> permSetIds) {
        List<BoolCell> cells = new List<BoolCell>();
        for (String psId : permSetIds) {
            BoolCell c = new BoolCell();
            c.psId    = psId;
            c.enabled = false;
            cells.add(c);
        }
        return cells;
    }

    // ── Object Permissions ────────────────────────────────────────────────────

    private static List<ObjPermRow> buildObjectPerms(
        List<String> permSetIds,
        List<String> filterObjects
    ) {
        Map<String, ObjPermRow> rowMap = new Map<String, ObjPermRow>();

        String q =
            'SELECT ParentId, SObjectType, ' +
            'PermissionsRead, PermissionsCreate, PermissionsEdit, ' +
            'PermissionsDelete, PermissionsViewAllRecords, PermissionsModifyAllRecords ' +
            'FROM ObjectPermissions WHERE ParentId IN :permSetIds';
        if (filterObjects != null && !filterObjects.isEmpty()) {
            q += ' AND SObjectType IN :filterObjects';
        }

        for (ObjectPermissions op : Database.query(q)) {
            String obj = op.SObjectType;
            if (!rowMap.containsKey(obj)) {
                ObjPermRow row  = new ObjPermRow();
                row.objectApiName = obj;
                row.objectLabel   = obj;
                row.cells         = new List<ObjPermCell>();
                for (String psId : permSetIds) {
                    ObjPermCell c  = new ObjPermCell();
                    c.permSetId    = psId;
                    c.canRead      = false;
                    c.canCreate    = false;
                    c.canEdit      = false;
                    c.canDelete    = false;
                    c.canViewAll   = false;
                    c.canModifyAll = false;
                    row.cells.add(c);
                }
                rowMap.put(obj, row);
            }
            Integer idx = permSetIds.indexOf(op.ParentId);
            if (idx >= 0) {
                ObjPermCell c  = rowMap.get(obj).cells[idx];
                c.canRead      = op.PermissionsRead;
                c.canCreate    = op.PermissionsCreate;
                c.canEdit      = op.PermissionsEdit;
                c.canDelete    = op.PermissionsDelete;
                c.canViewAll   = op.PermissionsViewAllRecords;
                c.canModifyAll = op.PermissionsModifyAllRecords;
            }
        }

        // Resolve labels — page through EntityDefinition in batches of 200
        // using OFFSET so we handle any number of objects without hitting queryMore()
        if (!rowMap.isEmpty()) {
            List<String> objNames = new List<String>(rowMap.keySet());
            Map<String, Object> binds = new Map<String, Object>{ 'names' => objNames };
            try {
                for (Integer offset = 0; offset <= 1800; offset += 200) {
                    List<EntityDefinition> page = Database.queryWithBinds(
                        'SELECT QualifiedApiName, Label FROM EntityDefinition ' +
                        'WHERE QualifiedApiName IN :names ' +
                        'ORDER BY Label ASC LIMIT 200 OFFSET ' + offset,
                        binds, AccessLevel.USER_MODE
                    );
                    if (page.isEmpty()) break;
                    for (EntityDefinition ed : page) {
                        if (rowMap.containsKey(ed.QualifiedApiName)) {
                            rowMap.get(ed.QualifiedApiName).objectLabel = ed.Label;
                        }
                    }
                }
            } catch (Exception e) {
                System.debug('Label resolve error: ' + e.getMessage());
            }
        }

        List<ObjPermRow> rows = rowMap.values();
        rows.sort(new ObjRowComparator());
        return rows;
    }

    // ── Apex Class Access ─────────────────────────────────────────────────────

    private static List<ApexRow> buildApexAccess(List<String> permSetIds) {
        Map<Id, String> classById = new Map<Id, String>();
        for (ApexClass cls : [
            SELECT Id, Name FROM ApexClass ORDER BY Name ASC LIMIT 2000
        ]) {
            classById.put(cls.Id, cls.Name);
        }

        Map<String, ApexRow> rowMap = new Map<String, ApexRow>();
        for (String className : classById.values()) {
            ApexRow row    = new ApexRow();
            row.className  = className;
            row.access     = initBoolCells(permSetIds);
            rowMap.put(className, row);
        }

        for (SetupEntityAccess sea : [
            SELECT ParentId, SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId IN :permSetIds
              AND SetupEntityType = 'ApexClass'
        ]) {
            String cn = classById.get(sea.SetupEntityId);
            if (cn != null && rowMap.containsKey(cn)) {
                Integer idx = permSetIds.indexOf(sea.ParentId);
                if (idx >= 0) rowMap.get(cn).access[idx].enabled = true;
            }
        }

        // Only return rows where at least one perm set has access
        List<ApexRow> rows = new List<ApexRow>();
        for (ApexRow row : rowMap.values()) {
            for (BoolCell c : row.access) {
                if (c.enabled) { rows.add(row); break; }
            }
        }
        return rows;
    }

    // ── System Permissions ────────────────────────────────────────────────────

    private static List<SysPermRow> buildSysPerms(List<String> permSetIds) {
        List<SysPermRow> rows = new List<SysPermRow>();
        try {
            // Dynamically discover ALL system permission fields on PermissionSet
            // by describing the object and finding every Boolean field that
            // starts with "Permissions" — this future-proofs against new permissions
            // added in new Salesforce releases and captures ALL org permissions
            // including managed package permissions (e.g. SBQQ__, nCino__ etc.)
            Schema.DescribeSObjectResult psDescribe =
                Schema.SObjectType.PermissionSet;
            Map<String, Schema.SObjectField> allFields =
                psDescribe.fields.getMap();

            List<String> permFieldNames = new List<String>();
            Map<String, String> permFieldLabels = new Map<String, String>();

            for (String fieldName : allFields.keySet()) {
                Schema.DescribeFieldResult f = allFields.get(fieldName).getDescribe();
                // Every system permission field is Boolean and starts with "permissions"
                if (f.getType() == Schema.DisplayType.BOOLEAN
                    && fieldName.startsWith('permissions')
                    && fieldName != 'permissionsenabledforsite') {
                    permFieldNames.add(f.getName());
                    permFieldLabels.put(f.getName(), f.getLabel());
                }
            }
            permFieldNames.sort(); // alphabetical order

            if (permFieldNames.isEmpty()) return rows;

            // Query system permission fields in batches of 100 (SOQL field limit)
            // Store results in psId -> fieldName -> Boolean map across batches
            Integer batchSize = 100;
            Map<String, Map<String, Boolean>> psFieldValues =
                new Map<String, Map<String, Boolean>>();
            for (String psId : permSetIds) {
                psFieldValues.put(psId, new Map<String, Boolean>());
            }

            for (Integer i = 0; i < permFieldNames.size(); i += batchSize) {
                Integer endIdx = Math.min(i + batchSize, permFieldNames.size());
                List<String> batch = new List<String>();
                for (Integer j = i; j < endIdx; j++) {
                    batch.add(permFieldNames[j]);
                }
                String q = 'SELECT Id, ' + String.join(batch, ',')
                         + ' FROM PermissionSet WHERE Id IN :permSetIds';
                for (PermissionSet ps : Database.query(q)) {
                    String psId = ps.Id;
                    if (psFieldValues.containsKey(psId)) {
                        for (String fn : batch) {
                            try {
                                Boolean v = (Boolean) ps.get(fn);
                                psFieldValues.get(psId).put(fn, v == true);
                            } catch (Exception ex) {
                                psFieldValues.get(psId).put(fn, false);
                            }
                        }
                    }
                }
            }

            // Build result rows — one per permission field, always include all
            for (String f : permFieldNames) {
                SysPermRow row  = new SysPermRow();
                row.permApiName = f;
                row.permLabel   = permFieldLabels.containsKey(f)
                    ? permFieldLabels.get(f) : f;
                row.values      = new List<BoolCell>();
                for (String psId : permSetIds) {
                    BoolCell c = new BoolCell();
                    c.psId    = psId;
                    c.enabled = psFieldValues.containsKey(psId)
                        && psFieldValues.get(psId).containsKey(f)
                        && psFieldValues.get(psId).get(f) == true;
                    row.values.add(c);
                }
                rows.add(row);
            }
        } catch (Exception e) {
            System.debug('SysPerms error: ' + e.getMessage() + ' ' + e.getStackTraceString());
        }
        return rows;
    }
}
